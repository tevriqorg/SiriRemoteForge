//
//  srm_captured_persistent.c — persistent Siri Remote microphone capture supervisor.
//
//  The old supervisor started PacketLogger only after a Voice demand edge. That put PacketLogger's
//  cold exec, dyld/framework page-ins and Bluetooth trace startup directly on the user's press path.
//  Under memory pressure those steps can take seconds even though the steady-state capture path is
//  fast. This supervisor removes that latency class entirely: PacketLogger and srm_router are kept
//  alive for the lifetime of the LaunchDaemon and PacketLogger streams nhdr text directly to the
//  router over a pipe. No growing .pklg file and no per-utterance process startup are involved.
//
//  The router historically publishes producerActive once, then leaves it set until it exits. That
//  was correct when the router itself was demand-scoped, but a persistent router needs session-level
//  activity. A small watchdog therefore derives producerActive from actual ring writeIndex progress:
//  three fresh 20 ms frames -> active=1; no new frames for a short interval -> active=0. This keeps
//  the router's original jitter prebuffer and the existing App/HAL contracts intact without making
//  either client aware that the capture processes are now long-lived.
//
//  Darwin notifications are deliberately retained only as recovery hints. They no longer launch or
//  stop the normal pipeline, so a user press never waits for PacketLogger. If the pipeline crashed,
//  a demand edge asks the supervisor to retry immediately while the normal crash backoff is pending.
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <notify.h>
#include <dispatch/dispatch.h>

#include "../driver/SiriRemoteMicShared.h"

extern char **environ;

#define NOTIF_NAME           "au.holodata.SiriRemoteMic.consumers"
#define DICTATION_NOTIF_NAME "au.holodata.SiriRemoteMic.dictation"
#define PACKETLOGGER         "/Applications/PacketLogger.app/Contents/Resources/packetlogger"
#define ROUTER_PATH          "/Library/Application Support/SiriRemoteMic/srm_router"
#define BT_DEBUG_DOMAIN      "/Library/Preferences/com.apple.MobileBluetooth.debug"

#define RESTART_BACKOFF_SECONDS 2
#define MISSING_RETRY_SECONDS   30
#define RING_WATCH_INTERVAL_MS  20
#define RING_IDLE_AFTER_MS      200
#define RING_PREBUFFER_FRAMES   2880u  // 3 * 20 ms @ 48 kHz, matching srm_router

static pid_t g_packetlogger = -1;
static pid_t g_router = -1;
static _Atomic int g_pipeline_up = 0;
static int g_hci_ready = 0;
static int g_terminating = 0;

static dispatch_source_t g_restart_timer = NULL;
static dispatch_source_t g_ring_timer = NULL;
static dispatch_source_t g_term_source = NULL;
static dispatch_source_t g_int_source = NULL;

static int g_ring_fd = -1;
static SRMSharedMemory *g_ring = NULL;
static uint64_t g_last_write_index = 0;
static uint64_t g_session_base_index = 0;
static uint64_t g_last_advance_ns = 0;

static void logmsg(const char *fmt, ...)
{
    char ts[32];
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(ts, sizeof ts, "%H:%M:%S", &tmv);

    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[srm_captured %s] ", ts);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    fflush(stderr);
}

static uint64_t monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static pid_t spawn_child(const char *path, char *const argv[])
{
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (rc != 0) {
        logmsg("spawn %s failed: %s", path, strerror(rc));
        return -1;
    }
    return pid;
}

static void spawn_and_wait(const char *path, char *const argv[])
{
    pid_t pid = spawn_child(path, argv);
    if (pid > 0) {
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
    }
}

static int packetlogger_available(void)
{
    return access(PACKETLOGGER, X_OK) == 0;
}

static void ensure_hci_traces(void)
{
    if (g_hci_ready) return;

    char *dargs[] = {
        "defaults", "write", BT_DEBUG_DOMAIN, "HCITraces", "-dict",
        "StackDebugEnabled", "-bool", "true",
        "HCILiveTraces",     "-bool", "true",
        "HCIFileTraces",     "-bool", "true",
        "RawAudioTrace",     "-bool", "true",
        "HIDTrace",          "-bool", "true",
        "HCISkipAuth",       "-bool", "true",
        NULL
    };
    spawn_and_wait("/usr/bin/defaults", dargs);

    char *kargs[] = { "killall", "-30", "bluetoothd", NULL };
    spawn_and_wait("/usr/bin/killall", kargs);
    g_hci_ready = 1;
    logmsg("HCI debug traces asserted");
}

static void unmap_remote_ring(void)
{
    if (g_ring != NULL) {
        munmap(g_ring, sizeof(*g_ring));
        g_ring = NULL;
    }
    if (g_ring_fd >= 0) {
        close(g_ring_fd);
        g_ring_fd = -1;
    }
    g_last_write_index = 0;
    g_session_base_index = 0;
    g_last_advance_ns = 0;
}

static int map_remote_ring(void)
{
    if (g_ring != NULL) return 1;

    int fd = shm_open(SRM_SHM_NAME, O_RDWR, 0);
    if (fd < 0) return 0;  // router has not created the ring yet

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(SRMSharedMemory)) {
        close(fd);
        return 0;
    }

    SRMSharedMemory *ring = mmap(NULL, sizeof(*ring), PROT_READ | PROT_WRITE,
                                 MAP_SHARED, fd, 0);
    if (ring == MAP_FAILED) {
        close(fd);
        return 0;
    }

    if (ring->magic != SRM_MAGIC || ring->version != SRM_VERSION) {
        munmap(ring, sizeof(*ring));
        close(fd);
        return 0;
    }

    g_ring_fd = fd;
    g_ring = ring;
    g_last_write_index = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    g_session_base_index = g_last_write_index;
    g_last_advance_ns = 0;
    atomic_store_explicit(&ring->producerActive, 0, memory_order_release);
    return 1;
}

static void set_remote_ring_active(int active)
{
    if (!map_remote_ring()) return;
    atomic_store_explicit(&g_ring->producerActive, active != 0, memory_order_release);
}

static void ring_watch_tick(void)
{
    if (!map_remote_ring()) return;

    const uint64_t now = monotonic_ns();
    const uint64_t current = atomic_load_explicit(&g_ring->writeIndex, memory_order_acquire);

    if (current != g_last_write_index) {
        // A fresh burst after an idle interval defines a new utterance epoch. Capture the index just
        // before its first observed write so producerActive is not published until the same 60 ms
        // prebuffer the router historically required has accumulated.
        if (g_last_advance_ns == 0 || current < g_last_write_index) {
            g_session_base_index = current < g_last_write_index ? current : g_last_write_index;
        }
        g_last_write_index = current;
        g_last_advance_ns = now;

        const uint64_t buffered = current >= g_session_base_index
            ? current - g_session_base_index
            : 0;
        atomic_store_explicit(&g_ring->producerActive,
                              buffered >= RING_PREBUFFER_FRAMES,
                              memory_order_release);
        return;
    }

    if (g_last_advance_ns != 0) {
        const uint64_t idle_ns = (uint64_t)RING_IDLE_AFTER_MS * 1000000ull;
        if (now - g_last_advance_ns >= idle_ns) {
            atomic_store_explicit(&g_ring->producerActive, 0, memory_order_release);
            g_last_advance_ns = 0;
            g_session_base_index = current;
        }
    }
}

static void terminate_child(pid_t *slot)
{
    pid_t pid = *slot;
    if (pid <= 0) return;

    (void)kill(pid, SIGTERM);
    for (int i = 0; i < 10; ++i) {
        int status = 0;
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid || (result < 0 && errno == ECHILD)) {
            *slot = -1;
            return;
        }
        if (result < 0 && errno != EINTR) break;
        usleep(10 * 1000);
    }

    (void)kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
    *slot = -1;
}

static void stop_pipeline(void)
{
    atomic_store_explicit(&g_pipeline_up, 0, memory_order_release);
    set_remote_ring_active(0);

    terminate_child(&g_router);
    terminate_child(&g_packetlogger);
    unmap_remote_ring();
}

static int spawn_stream_pipeline(void)
{
    int pipefd[2] = { -1, -1 };
    if (pipe(pipefd) != 0) {
        logmsg("pipe for PacketLogger stream failed: %s", strerror(errno));
        return 0;
    }
    (void)fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        logmsg("posix_spawnattr_init failed");
        return 0;
    }

    sigset_t defaults;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGPIPE);
    (void)posix_spawnattr_setsigdefault(&attr, &defaults);
    (void)posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF);

    posix_spawn_file_actions_t router_actions;
    int rc = posix_spawn_file_actions_init(&router_actions);
    if (rc != 0) {
        posix_spawnattr_destroy(&attr);
        close(pipefd[0]);
        close(pipefd[1]);
        logmsg("router file-actions init failed: %s", strerror(rc));
        return 0;
    }
    (void)posix_spawn_file_actions_adddup2(&router_actions, pipefd[0], STDIN_FILENO);
    (void)posix_spawn_file_actions_addclose(&router_actions, pipefd[0]);
    (void)posix_spawn_file_actions_addclose(&router_actions, pipefd[1]);

    char *rargs[] = { "srm_router", "--quiet", NULL };
    pid_t router = -1;
    rc = posix_spawn(&router, ROUTER_PATH, &router_actions, &attr, rargs, environ);
    posix_spawn_file_actions_destroy(&router_actions);
    if (rc != 0) {
        posix_spawnattr_destroy(&attr);
        close(pipefd[0]);
        close(pipefd[1]);
        logmsg("spawn %s failed: %s", ROUTER_PATH, strerror(rc));
        return 0;
    }

    posix_spawn_file_actions_t packet_actions;
    rc = posix_spawn_file_actions_init(&packet_actions);
    if (rc != 0) {
        (void)kill(router, SIGKILL);
        while (waitpid(router, NULL, 0) < 0 && errno == EINTR) {}
        posix_spawnattr_destroy(&attr);
        close(pipefd[0]);
        close(pipefd[1]);
        logmsg("PacketLogger file-actions init failed: %s", strerror(rc));
        return 0;
    }
    (void)posix_spawn_file_actions_adddup2(&packet_actions, pipefd[1], STDOUT_FILENO);
    (void)posix_spawn_file_actions_addclose(&packet_actions, pipefd[0]);
    (void)posix_spawn_file_actions_addclose(&packet_actions, pipefd[1]);

    char *pargs[] = { "packetlogger", "convert", "-s", "-f", "nhdr", NULL };
    pid_t packetlogger = -1;
    rc = posix_spawn(&packetlogger, PACKETLOGGER, &packet_actions, &attr, pargs, environ);
    posix_spawn_file_actions_destroy(&packet_actions);
    posix_spawnattr_destroy(&attr);

    close(pipefd[0]);
    close(pipefd[1]);

    if (rc != 0) {
        (void)kill(router, SIGKILL);
        while (waitpid(router, NULL, 0) < 0 && errno == EINTR) {}
        logmsg("spawn %s failed: %s", PACKETLOGGER, strerror(rc));
        return 0;
    }

    g_router = router;
    g_packetlogger = packetlogger;
    atomic_store_explicit(&g_pipeline_up, 1, memory_order_release);
    return 1;
}

static int start_pipeline(void)
{
    if (atomic_load_explicit(&g_pipeline_up, memory_order_acquire)) return 1;
    if (g_terminating) return 0;

    if (!packetlogger_available()) {
        logmsg("PacketLogger not installed — persistent remote capture unavailable");
        return 0;
    }

    ensure_hci_traces();
    set_remote_ring_active(0);

    const uint64_t started = monotonic_ns();
    logmsg("starting persistent PacketLogger → router stream");
    if (!spawn_stream_pipeline()) return 0;

    const uint64_t elapsed_ms = (monotonic_ns() - started) / 1000000ull;
    logmsg("persistent capture pipeline up (packetlogger=%d router=%d startup_ms=%llu)",
           g_packetlogger, g_router, (unsigned long long)elapsed_ms);
    return 1;
}

static void cancel_restart_timer(void)
{
    if (g_restart_timer != NULL) {
        dispatch_source_cancel(g_restart_timer);
        g_restart_timer = NULL;
    }
}

static void schedule_restart(unsigned seconds)
{
    if (g_terminating || g_restart_timer != NULL ||
        atomic_load_explicit(&g_pipeline_up, memory_order_acquire)) {
        return;
    }

    g_restart_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              dispatch_get_main_queue());
    if (g_restart_timer == NULL) return;

    dispatch_source_set_timer(g_restart_timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER, (uint64_t)(250 * 1000000ull));
    dispatch_source_set_event_handler(g_restart_timer, ^{
        cancel_restart_timer();
        if (!start_pipeline()) {
            schedule_restart(packetlogger_available()
                ? RESTART_BACKOFF_SECONDS
                : MISSING_RETRY_SECONDS);
        }
    });
    dispatch_resume(g_restart_timer);
}

static void request_immediate_recovery(void)
{
    if (g_terminating || atomic_load_explicit(&g_pipeline_up, memory_order_acquire)) return;
    cancel_restart_timer();
    schedule_restart(0);
}

static void install_ring_watchdog(void)
{
    g_ring_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                           dispatch_get_main_queue());
    if (g_ring_timer == NULL) return;

    dispatch_source_set_timer(g_ring_timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)RING_WATCH_INTERVAL_MS * 1000000ll),
        (uint64_t)RING_WATCH_INTERVAL_MS * 1000000ull,
        (uint64_t)5 * 1000000ull);
    dispatch_source_set_event_handler(g_ring_timer, ^{
        ring_watch_tick();
    });
    dispatch_resume(g_ring_timer);
}

static void handle_pipeline_exit(void)
{
    if (g_terminating) return;

    logmsg("persistent capture process exited unexpectedly — restarting both sides");
    atomic_store_explicit(&g_pipeline_up, 0, memory_order_release);
    set_remote_ring_active(0);

    // The SIGCHLD handler already reaped whichever child caused this path. Terminate the survivor so
    // a new pipe always starts as a matched PacketLogger/router pair.
    terminate_child(&g_router);
    terminate_child(&g_packetlogger);
    unmap_remote_ring();
    schedule_restart(RESTART_BACKOFF_SECONDS);
}

static void terminate_daemon(void)
{
    if (g_terminating) return;
    g_terminating = 1;
    cancel_restart_timer();
    logmsg("stopping persistent capture supervisor");
    stop_pipeline();
    exit(0);
}

static dispatch_source_t install_termination_source(int signal_number)
{
    signal(signal_number, SIG_IGN);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                       (uintptr_t)signal_number, 0,
                                                       dispatch_get_main_queue());
    if (source != NULL) {
        dispatch_source_set_event_handler(source, ^{
            terminate_daemon();
        });
        dispatch_resume(source);
    }
    return source;
}

int main(void)
{
    // PacketLogger writes to a pipe. The supervisor owns lifecycle and restarts the pair on either
    // side exiting, so a transient broken pipe must not kill the supervisor itself.
    signal(SIGPIPE, SIG_IGN);

    logmsg("starting persistent capture supervisor");

    // Handle termination through dispatch so cleanup never runs inside an async signal handler.
    g_term_source = install_termination_source(SIGTERM);
    g_int_source = install_termination_source(SIGINT);
    (void)g_term_source;
    (void)g_int_source;

    // Reap child exits and recover the whole stream as one unit. The ring is explicitly marked
    // inactive during recovery so clients never mistake a frozen producer for live audio.
    signal(SIGCHLD, SIG_DFL);
    dispatch_source_t sigchld = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGCHLD, 0,
                                                       dispatch_get_main_queue());
    if (sigchld != NULL) {
        dispatch_source_set_event_handler(sigchld, ^{
            int status = 0;
            pid_t dead = -1;
            int lost_pipeline_child = 0;
            while ((dead = waitpid(-1, &status, WNOHANG)) > 0) {
                if (dead == g_router) {
                    g_router = -1;
                    lost_pipeline_child = 1;
                }
                if (dead == g_packetlogger) {
                    g_packetlogger = -1;
                    lost_pipeline_child = 1;
                }
            }
            if (lost_pipeline_child) handle_pipeline_exit();
        });
        dispatch_resume(sigchld);
    }

    install_ring_watchdog();

    // Start before accepting demand notifications. A cold PacketLogger launch now happens once at
    // daemon boot/reload, never on the user's Siri press path.
    if (!start_pipeline()) {
        schedule_restart(packetlogger_available()
            ? RESTART_BACKOFF_SECONDS
            : MISSING_RETRY_SECONDS);
    }

    // Compatibility/recovery hooks. Existing App and HAL code may continue publishing these Darwin
    // notifications; they no longer control normal process lifetime. If capture is down, however, a
    // fresh user demand shortens the retry window immediately.
    int virtual_token = 0;
    uint32_t rc = notify_register_dispatch(NOTIF_NAME, &virtual_token,
                                            dispatch_get_main_queue(), ^(int token) {
        (void)token;
        request_immediate_recovery();
    });
    if (rc != NOTIFY_STATUS_OK) {
        logmsg("notify_register_dispatch(%s) failed: %u — persistent capture still runs",
               NOTIF_NAME, rc);
    }

    int dictation_token = 0;
    rc = notify_register_dispatch(DICTATION_NOTIF_NAME, &dictation_token,
                                  dispatch_get_main_queue(), ^(int token) {
        (void)token;
        request_immediate_recovery();
    });
    if (rc != NOTIFY_STATUS_OK) {
        logmsg("notify_register_dispatch(%s) failed: %u — persistent capture still runs",
               DICTATION_NOTIF_NAME, rc);
    }

    logmsg("persistent capture ready; demand notifications are recovery-only");
    dispatch_main();
    return 0;
}
