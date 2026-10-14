//
//  srm_captured.c — the "Siri Remote Mic" capture daemon.
//
//  Runs as root from a LaunchDaemon. It exists to answer demand: the HAL plug-in broadcasts
//  `au.holodata.SiriRemoteMic.consumers` whenever an app opens or closes the virtual mic device
//  (state = number of devices with IO running; treat >=1 as "in use"). HyperVibe's native dictation
//  reads the shared ring directly, so it independently publishes `...dictation` with its live PID.
//  This daemon ORs both demands and runs the heavy, privileged capture pipeline — PacketLogger
//  (HCI sniff) feeding srm_router (voice extraction → shared-memory ring) — only while either route
//  needs it. The PID is watched for exit so an App crash cannot leave capture running.
//
//  WHY ROOT: PacketLogger's HCI capture and the MobileBluetooth debug traces both require root.
//  A LaunchDaemon is the standard way to grant exactly that, once, instead of a per-use password.
//  The pipeline binaries are unchanged from the validated manual path; this only orchestrates them.
//
//  BUILD:   ./build.sh          INSTALL: ./install.sh (needs sudo)          REMOVE: ./uninstall.sh
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

#include "../driver/SiriRemoteMicShared.h"   // SRM_SHM_NAME / SRMSharedMemory for the ring backstop

extern char **environ;

// --- fixed paths (see install.sh — the router is copied next to this binary) -------------------
#define NOTIF_NAME    "au.holodata.SiriRemoteMic.consumers"
#define DICTATION_NOTIF_NAME "au.holodata.SiriRemoteMic.dictation"
#define PKLG_PATH     "/tmp/srm_captured.pklg"
#define PACKETLOGGER  "/Applications/PacketLogger.app/Contents/Resources/packetlogger"
#define ROUTER_PATH   "/Library/Application Support/SiriRemoteMic/srm_router"
#define BT_DEBUG_DOMAIN "/Library/Preferences/com.apple.MobileBluetooth.debug"

// A grace period before tearing the pipeline down after the last app closes the device. Apps
// routinely close-then-reopen the input (device format changes, call renegotiation) and a native
// dictation hold is often followed by another within a few seconds; without this every such blip
// would restart PacketLogger. A longer window keeps the already-warm PacketLogger process alive
// across those gaps so the next press skips the cold exec. 10 s still tears down promptly once the
// user is genuinely finished.
#define STOP_DEBOUNCE_SECONDS 10

// Long-idle keep-warm. Once PacketLogger has been torn down its code pages are evicted under memory
// pressure, so the next start after a quiet period pays a 7-12 s cold exec (observed). The one-shot
// boot warm-up goes stale after minutes. Re-run the warm-up periodically while idle so a real demand
// practically always finds PacketLogger resident; a fresh session re-primes sooner (see stop_pipeline).
#define KEEPWARM_INTERVAL_SECONDS 60
#define KEEPWARM_AFTER_STOP_SECONDS 3

static pid_t g_packetlogger = -1;
static pid_t g_router = -1;
static _Atomic int g_pipeline_up = 0;
static int   g_hci_ready = 0;
static dispatch_source_t g_stop_timer = NULL;
static dispatch_source_t g_dictation_process = NULL;
static int      g_dictation_token = 0;
static uint64_t g_virtual_demand = 0;
static pid_t    g_dictation_pid = 0;

static dispatch_source_t g_keepwarm_timer = NULL;
// Prewarm is slow (a cold exec) and must never run on the main queue, or a demand edge arriving
// mid-prewarm would be delayed by exactly the stall we are removing. A dedicated serial queue lets
// the warm-up run in the background; start_pipeline aborts and drains it (see below) so two
// PacketLogger HCI sessions can never overlap.
static dispatch_queue_t g_keepwarm_queue = NULL;
// The pid of an in-flight keep-warm PacketLogger (0 when none) and a flag the demand path sets to
// make it stop early instead of the user waiting behind it.
static _Atomic pid_t g_prewarm_pid = 0;
static _Atomic int   g_prewarm_cancel = 0;

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

// posix_spawn a child, return its pid (or -1). argv[0] is conventionally the program name.
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
    if (pid > 0) waitpid(pid, NULL, 0);
}

static int packetlogger_available(void)
{
    return access(PACKETLOGGER, X_OK) == 0;
}

// Enable the Bluetooth HCI debug traces PacketLogger needs to see the remote's voice notifications
// (RawAudioTrace) and defeat the profile-required wall (HCISkipAuth). These reset on reboot, so the
// daemon re-asserts them; SIGUSR1 (-30) makes bluetoothd reload debug config WITHOUT disconnecting.
static void ensure_hci_traces(void)
{
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

// PacketLogger's cold-exec cost on a throwaway capture we immediately discard; nothing reads it.
// `interruptible` selects the idle keep-warm mode: it runs on g_keepwarm_queue and can be aborted
// immediately when a real demand arrives, so the two PacketLogger HCI sessions never overlap. At
// boot it runs to completion synchronously, before the demand watch is armed.
static void prewarm_packetlogger(int interruptible);

// Background keep-warm entry point: runs on g_keepwarm_queue so the main queue stays free to
// service a demand edge. Re-checks the pipeline state after any in-flight prewarm finishes.
static void keepwarm_async(void)
{
    if (atomic_load_explicit(&g_prewarm_pid, memory_order_acquire) != 0) return;  // one already running
    atomic_store_explicit(&g_prewarm_cancel, 0, memory_order_release);
    dispatch_async(g_keepwarm_queue, ^{
        if (g_pipeline_up) return;      // a real demand overtook us; nothing to warm
        logmsg("idle keep-warm: re-priming PacketLogger");
        prewarm_packetlogger(1);
    });
}

// Fork+exec so the caller returns IMMEDIATELY, before the child's (potentially slow, cold) exec.
// posix_spawn deliberately blocks until the child has successfully exec'd — exactly the multi-second
// cold PacketLogger launch — so a spawn built on it could not be cancelled or yield mid-exec.
// A CLOEXEC status pipe preserves exec-failure detection: the child writes errno to the pipe only if
// execv fails, then _exit; on success the pipe closes at exec (EOF). Everything the child does
// before exec is async-signal-safe (write/execv/_exit only), so forking a multi-threaded dispatch
// process is safe here. Returns the pid, or -1 with errno set if the fork or exec failed.
static pid_t spawn_child_noblock(const char *path, char *const argv[])
{
    int fds[2];
    if (pipe(fds) != 0) { logmsg("pipe for %s failed: %s", path, strerror(errno)); return -1; }
    (void)fcntl(fds[1], F_SETFD, FD_CLOEXEC);       // child side closes automatically only on exec
    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        close(fds[0]); close(fds[1]);
        logmsg("fork for %s failed: %s", path, strerror(saved));
        errno = saved;
        return -1;
    }
    if (pid == 0) {
        close(fds[0]);
        execv(path, argv);
        int saved = errno;                          // async-signal-safe path: write + _exit only
        (void)!write(fds[1], &saved, sizeof saved);
        _exit(127);
    }
    close(fds[1]);
    // Bounded, non-blocking wait for the exec outcome. On success the CLOEXEC pipe hits EOF the
    // instant exec replaces the image; on failure the child writes errno. A cold exec can take
    // seconds, so we wait only ~300 ms: if the child is still loading we return optimistically and let
    // the caller's downstream gate (the .pklg file-appear loop) decide — we never block on cold exec.
    (void)fcntl(fds[0], F_SETFL, O_NONBLOCK);
    int execErrno = 0;
    ssize_t n = -1;
    for (int i = 0; i < 30; ++i) {
        n = read(fds[0], &execErrno, sizeof execErrno);
        if (n != -1 || errno != EAGAIN) break;      // got an answer (bytes or EOF) or a real error
        usleep(10 * 1000);
    }
    close(fds[0]);
    if (n == (ssize_t)sizeof execErrno) {           // child reported a failed exec
        int status; (void)waitpid(pid, &status, 0); // reap the failed child so it can't linger
        logmsg("spawn %s failed: %s", path, strerror(execErrno));
        errno = execErrno;
        return -1;
    }
    return pid;
}

// Returns 1 if our child is gone (exited or already reaped by the SIGCHLD source), 0 if still alive.
// Uses waitpid, NOT kill(pid,0): once the reaper has collected this pid it can be recycled by the
// kernel, and kill() on a recycled pid would signal an unrelated process. waitpid identifies only our
// own child and reports ECHILD once it has been reaped, which is exactly "gone".
static int child_gone(pid_t pid)
{
    int status;
    pid_t r = waitpid(pid, &status, WNOHANG);
    return (r == pid) || (r < 0 && errno == ECHILD);
}

static void prewarm_packetlogger(int interruptible)
{
    const char *warm = "/tmp/srm_prewarm.pklg";
    unlink(warm);
    char *plargs[] = { "packetlogger", "convert", "-o", (char *)warm, NULL };
    pid_t pid = spawn_child_noblock(PACKETLOGGER, plargs);
    if (pid <= 0) return;
    // Publish the pid BEFORE waiting, so start_pipeline's drain can see an in-flight warm-up.
    if (interruptible) atomic_store_explicit(&g_prewarm_pid, pid, memory_order_release);
    // Wait until the child has faulted in its frameworks and written the first HCI bytes — that write
    // IS the cold cost being paid. Bail immediately if asked to cancel, or if the child dies on its own
    // (exec failure), so start_pipeline's drain never waits on a dead or unwanted warm-up.
    for (int i = 0; i < 200; ++i) {                 // up to 10 s
        struct stat st;
        if (child_gone(pid)) {
            if (interruptible) atomic_store_explicit(&g_prewarm_pid, 0, memory_order_release);
            unlink(warm);
            return;                                 // nothing left to kill or reap
        }
        if (stat(warm, &st) == 0 && st.st_size > 0) break;
        if (interruptible && atomic_load_explicit(&g_prewarm_cancel, memory_order_acquire)) break;
        usleep(50 * 1000);
    }
    usleep(200 * 1000);                             // small margin past the first write
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);                          // reap BEFORE publishing 0, so the drain cannot
    if (interruptible) atomic_store_explicit(&g_prewarm_pid, 0, memory_order_release);  // race ahead
    unlink(warm);                                   // into a second PacketLogger while ours lingers
    logmsg("PacketLogger pre-warmed");
}

static void start_pipeline(void)
{
    if (g_pipeline_up) return;
    struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
    if (!packetlogger_available()) {
        logmsg("PacketLogger missing — remote voice capture remains disabled");
        return;
    }
    // Claim the pipeline first, so any idle keep-warm block still queued on g_keepwarm_queue sees
    // g_pipeline_up and declines to start. Then abort + drain an in-flight warm-up before we spawn
    // our own PacketLogger: two concurrent HCI sessions must never overlap. This drain is a
    // dispatch_sync, so it returns only once the warm-up block has fully finished (child SIGKILLed and
    // reaped) — the strict serialization the invariant needs. It is safe to block the main queue here
    // because the warm-up now forks WITHOUT waiting on exec, so it observes g_prewarm_cancel within
    // ~50 ms and exits within its bounded 200 ms post-write margin: the sync therefore returns in a
    // few hundred ms, not the multi-second cold-exec stall the earlier posix_spawn version could block on.
    atomic_store_explicit(&g_pipeline_up, 1, memory_order_release);
    atomic_store_explicit(&g_prewarm_cancel, 1, memory_order_release);
    if (g_keepwarm_queue) dispatch_sync(g_keepwarm_queue, ^{});
    atomic_store_explicit(&g_prewarm_cancel, 0, memory_order_release);
    // Full Setup never bundles PacketLogger. If the user installs it after this daemon starts,
    // prepare HCI capture lazily on the first real demand; no reboot or daemon reload is required.
    if (!g_hci_ready) ensure_hci_traces();

    logmsg("demand active → starting capture pipeline");

    unlink(PKLG_PATH);
    char *plargs[] = { "packetlogger", "convert", "-o", PKLG_PATH, NULL };
    // Non-blocking spawn: a cold PacketLogger exec can take many seconds, and this runs on the main
    // queue — blocking here would delay every queued demand edge past the app's readiness window. We
    // still gate the router on the file appearing below, so ordering is preserved.
    g_packetlogger = spawn_child_noblock(PACKETLOGGER, plargs);
    if (g_packetlogger < 0) { g_pipeline_up = 0; return; }

    // Wait until PacketLogger's lossless file exists and is growing before the router tails it
    // (the router treats a missing/empty file as an error). ~5 s cap; it normally appears instantly.
    for (int i = 0; i < 100; ++i) {
        struct stat st;
        if (stat(PKLG_PATH, &st) == 0 && st.st_size > 0) break;
        usleep(50 * 1000);
    }

    char *rargs[] = { "srm_router", "--pklg", PKLG_PATH, NULL };
    // Non-blocking here too, for the same reason: a cold router exec must not stall the main queue.
    g_router = spawn_child_noblock(ROUTER_PATH, rargs);
    if (g_router < 0) logmsg("router failed to start — pipeline degraded");
    else {
        struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
        long ready_ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
        logmsg("pipeline up (packetlogger=%d router=%d) ready_ms=%ld", g_packetlogger, g_router, ready_ms);
    }
}

static int process_is_alive(pid_t pid);   // defined below — used by the bounded teardown wait

// Deterministically clear the router's producer-active flag in the shared ring. stop_pipeline tears
// the router down with SIGKILL, whose signal handler (the only other place that clears the flag)
// cannot run — so a reader could otherwise observe producerActive==1 with a frozen writeIndex and
// classify the press as a stalled producer rather than "no producer at all". Clearing it here makes
// the teardown state unambiguous no matter how the child died.
static void clear_remote_ring_active(void)
{
    int fd = shm_open(SRM_SHM_NAME, O_RDWR, 0);
    if (fd < 0) return;                     // never created yet — nothing stale to clear
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size >= (off_t)sizeof(SRMSharedMemory)) {
        SRMSharedMemory *m = mmap(NULL, sizeof(*m), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (m != MAP_FAILED) {
            if (m->magic == SRM_MAGIC && m->version == SRM_VERSION) {
                atomic_store_explicit(&m->producerActive, 0, memory_order_release);
            }
            munmap(m, sizeof(*m));
        }
    }
    close(fd);
}

static void stop_pipeline(void)
{
    if (!atomic_load_explicit(&g_pipeline_up, memory_order_acquire)) return;
    atomic_store_explicit(&g_pipeline_up, 0, memory_order_release);
    logmsg("demand idle → stopping capture pipeline");
    // Ask both children to exit cleanly first, so the router's signal handler clears the ring flag
    // and PacketLogger closes its HCI session, then hard-kill as a backstop. Liveness here is
    // waitpid(WNOHANG): we run on the main queue, so the SIGCHLD reaper cannot run concurrently and
    // cannot steal these children — and unlike kill(pid,0) it sees through a zombie (a freshly
    // signalled child) so the loop exits as soon as the child is really gone. Never a blocking wait:
    // an earlier version used waitpid(...,0) and hung the daemon when the router stalled.
    if (g_router > 0)       kill(g_router, SIGTERM);
    if (g_packetlogger > 0) kill(g_packetlogger, SIGTERM);
    for (int i = 0; i < 10; ++i) {
        if ((g_router <= 0 || child_gone(g_router)) &&
            (g_packetlogger <= 0 || child_gone(g_packetlogger))) break;
        usleep(10 * 1000);
    }
    if (g_router > 0)       { kill(g_router, SIGKILL);       g_router = -1; }
    if (g_packetlogger > 0) { kill(g_packetlogger, SIGKILL); g_packetlogger = -1; }
    // Backstop for a SIGKILLed router whose handler never ran (see the comment above).
    clear_remote_ring_active();
    unlink(PKLG_PATH);
    // Bring the idle keep-warm forward: the process just killed has warm pages only briefly, so
    // re-prime soon instead of waiting a full interval. Leeway stays tight — a 30 s leeway would let
    // the system defer this re-prime by up to 30 s, which is exactly the cold window we must close.
    if (g_keepwarm_timer) {
        dispatch_source_set_timer(g_keepwarm_timer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)KEEPWARM_AFTER_STOP_SECONDS * NSEC_PER_SEC),
            (uint64_t)KEEPWARM_INTERVAL_SECONDS * NSEC_PER_SEC, (uint64_t)NSEC_PER_SEC);
    }
}

static void cancel_stop_timer(void)
{
    if (g_stop_timer) { dispatch_source_cancel(g_stop_timer); g_stop_timer = NULL; }
}

static int process_is_alive(pid_t pid)
{
    if (pid <= 0) return 0;
    if (kill(pid, 0) == 0) return 1;
    return errno == EPERM;
}

static void reconcile_demand(void)
{
    if (g_virtual_demand >= 1 || process_is_alive(g_dictation_pid)) {
        cancel_stop_timer();        // a re-open cancels a pending teardown
        start_pipeline();
    } else {
        if (g_stop_timer) return;   // teardown already scheduled
        g_stop_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_stop_timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)STOP_DEBOUNCE_SECONDS * NSEC_PER_SEC),
                                  DISPATCH_TIME_FOREVER, (uint64_t)(0.5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(g_stop_timer, ^{
            cancel_stop_timer();
            stop_pipeline();
        });
        dispatch_resume(g_stop_timer);
    }
}

// The HAL consumer count remains owned exclusively by the plug-in. Native HyperVibe demand is
// combined separately below rather than overwriting this multi-client state.
static void handle_virtual_demand(int token)
{
    uint64_t state = 0;
    if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) g_virtual_demand = state;
    reconcile_demand();
}

static void cancel_dictation_process_watch(void)
{
    if (g_dictation_process != NULL) {
        dispatch_source_cancel(g_dictation_process);
        g_dictation_process = NULL;
    }
}

static void watch_dictation_process(pid_t pid)
{
    cancel_dictation_process_watch();
    if (!process_is_alive(pid)) {
        g_dictation_pid = 0;
        return;
    }
    g_dictation_process = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                                  DISPATCH_PROC_EXIT,
                                                  dispatch_get_main_queue());
    if (g_dictation_process == NULL) {
        logmsg("cannot watch dictation pid %d — demand will follow explicit release", pid);
        return;
    }
    dispatch_source_set_event_handler(g_dictation_process, ^{
        if (g_dictation_pid != pid) return;
        logmsg("dictation owner pid %d exited — releasing demand", pid);
        g_dictation_pid = 0;
        cancel_dictation_process_watch();
        reconcile_demand();
    });
    dispatch_resume(g_dictation_process);
}

// Native HyperVibe capture reads the shared ring directly and therefore never opens the HAL
// device. Its notification state carries the owner PID so a crash cannot leave capture running.
static void handle_dictation_demand(int token)
{
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) state = 0;
    pid_t requested = state > 0 && state <= INT32_MAX ? (pid_t)state : 0;
    if (!process_is_alive(requested)) requested = 0;
    if (requested != g_dictation_pid) {
        g_dictation_pid = requested;
        watch_dictation_process(requested);
        logmsg("dictation demand %s", requested > 0 ? "active" : "idle");
    }
    reconcile_demand();
}

static void on_term(int sig)
{
    (void)sig;
    stop_pipeline();
    _exit(0);
}

int main(void)
{
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGPIPE, SIG_IGN);

    logmsg("starting");
    g_keepwarm_queue = dispatch_queue_create("au.holodata.SiriRemoteMic.keepwarm",
                                              DISPATCH_QUEUE_SERIAL);
    if (packetlogger_available()) {
        ensure_hci_traces();
        prewarm_packetlogger(0);        // blocking at boot, before demand is watched
    } else {
        logmsg("PacketLogger not installed — leaving Bluetooth HCI debug traces unchanged");
    }

    // Idle keep-warm: while the pipeline is down, re-prime PacketLogger so its pages stay resident
    // and the next real demand starts warm instead of paying a cold exec. The handler only schedules
    // work on g_keepwarm_queue; the slow prewarm never runs on the main queue.
    if (packetlogger_available()) {
        g_keepwarm_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                  dispatch_get_main_queue());
        dispatch_source_set_timer(g_keepwarm_timer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)KEEPWARM_INTERVAL_SECONDS * NSEC_PER_SEC),
            (uint64_t)KEEPWARM_INTERVAL_SECONDS * NSEC_PER_SEC, (uint64_t)NSEC_PER_SEC);
        dispatch_source_set_event_handler(g_keepwarm_timer, ^{
            if (g_pipeline_up) return;   // a live pipeline already has its code resident
            keepwarm_async();
        });
        dispatch_resume(g_keepwarm_timer);
    }

    // Reap any child that dies on its own (e.g. PacketLogger quitting) so it can't linger as a
    // zombie; if it was our live pipeline, drop our bookkeeping so the next demand edge restarts it.
    dispatch_source_t sigchld = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGCHLD, 0,
                                                       dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigchld, ^{
        int status;
        pid_t dead;
        while ((dead = waitpid(-1, &status, WNOHANG)) > 0) {
            if (dead == g_router)      { g_router = -1; }
            if (dead == g_packetlogger){ g_packetlogger = -1; }
            if (g_pipeline_up && g_router < 0 && g_packetlogger < 0) {
                logmsg("pipeline processes exited unexpectedly");
                g_pipeline_up = 0;
            }
        }
    });
    signal(SIGCHLD, SIG_DFL);   // let the dispatch source observe; default disposition delivers it
    dispatch_resume(sigchld);

    int token = 0;
    uint32_t rc = notify_register_dispatch(NOTIF_NAME, &token, dispatch_get_main_queue(), ^(int t) {
        handle_virtual_demand(t);
    });
    if (rc != NOTIFY_STATUS_OK) {
        logmsg("notify_register_dispatch(%s) failed: %u — cannot detect demand, exiting", NOTIF_NAME, rc);
        return 1;
    }

    uint32_t dictation_rc = notify_register_dispatch(DICTATION_NOTIF_NAME, &g_dictation_token,
                                                      dispatch_get_main_queue(), ^(int t) {
        handle_dictation_demand(t);
    });
    if (dictation_rc != NOTIFY_STATUS_OK) {
        logmsg("notify_register_dispatch(%s) failed: %u — native dictation will use built-in fallback",
               DICTATION_NOTIF_NAME, dictation_rc);
    }

    handle_virtual_demand(token);   // ground truth at startup (device may already be in use)
    if (dictation_rc == NOTIFY_STATUS_OK) handle_dictation_demand(g_dictation_token);
    logmsg("watching demand on %s + %s", NOTIF_NAME, DICTATION_NOTIF_NAME);
    dispatch_main();
    return 0;
}
