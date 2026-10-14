# HANDOFF — tevriqorg/SiriRemoteForge current development state

This is the **active** handoff for the tevriqorg fork. Historical upstream experiments, old release logs and superseded notes live under `deprecated/`; they are reference material, not current operating instructions.

Last structural refresh: 2026-10-09.

Last content update: 2026-10-09.

## Current authority

- Repository: `tevriqorg/SiriRemoteForge`
- Default branch: `main`
- Current Architecture R1 integration PR: **#8**
- R1 branch: `chatgpt/architecture-r1-20261008`
- Local configuration: `~/.config/siriremote/config.jsonc`
- Installed live App path during real-device testing: `/Applications/HyperVibe.app`
- The source still uses the historical internal product name **HyperVibe**. Do not mix a product rename into the current architecture/signing work.

## Architecture R1 — completed on branch, 2026-10-09

Architecture R1 is no longer an unfinished experiment. All four implementation phases have passed their hosted-runner gates and the validated staging results have been landed back into the R1 branch.

### Phase 1 — real Core module boundary

Production App builds and links the real SwiftPM `SiriRemoteCore` module instead of recompiling Core source files into the App module. CI protects that boundary so production source lists cannot regress to `../SiriRemoteCore/Sources` compilation.

### Phase 2 — physical-input state isolation

Pure button/hold/repeat/multi-tap/layer/voice-chord state lives in `RemoteInputCore`; HID callbacks, timers and side effects stay in `RemoteInputHandler`.

Deterministic tests cover mirrored/overlapping remotes, disconnect/reset, hold boundaries, tap runs, layer state, repeat engagement and voice-chord transitions.

Validated staging commit: `f75cbfdb956b63667fc6012406ca63f519f26488`.

Landed into the R1 branch through **PR #9**.

### Phase 3 — App composition boundary

`AppRuntime` owns the long-lived physical-input subsystem graph:

- `RemoteDetector`
- `RemoteInputHandler`
- `MediaKeyInterceptor`
- `TouchHandler`

It also owns the single passive-input teardown boundary.

`DeveloperCommandRouter` owns immutable developer/test/snapshot command-line routing. `SiriRemoteApp.swift` remains the AppKit composition root; no broad `@MainActor` annotation was used as a shortcut.

Validated staging commit: `83425fbfbce2016b36eda0b4aac7fd045bb7504a`.

Landed into the R1 branch through **PR #10**.

### Phase 4 — concurrency ownership and teardown

The final ownership audit verifies:

- the remaining `DispatchQueue.main.sync` in `VoiceTextDelivery` is protected by a main-thread guard, so it cannot sync main-to-main;
- Corpus termination draining uses the queue-aware `drainIOQueueAndRun()` path;
- permission-health Timer invalidation is present;
- Notification observers are removed during App teardown;
- `AppWatcher` removes its workspace observer;
- `AppRuntime.stopPassiveInput()` is the passive-input shutdown boundary.

Two real `WindowControl` strict-concurrency warnings were eliminated by replacing shared stored `CFString` constants with computed values. The checked-in concurrency baseline was reduced by the same two entries; no suppression was added.

Validated staging commit: `ba6f7e40a8271562c019413ba67ba131a39a3d12`.

Landed into the R1 branch through **PR #11**.

## Actual R1 validation results

The final Phase 4 gate passed:

- ownership/teardown audit;
- strict `SiriRemoteCore` build;
- strict `SiriRemoteCore` tests;
- strict App concurrency diagnostics against the smaller baseline;
- ordinary App build;
- ad-hoc development bundle assembly;
- strict nested `codesign --verify`;
- isolated staged-bundle Runtime Smoke: `--test-voice-input`.

Phase 2 and Phase 3/4 independently passed the same Core/App/concurrency/build/signing gates before their staging commits were merged back into R1.

### Explicit hosted-runner limitation

GitHub-hosted macOS runners do **not** validate real Siri Remote HID ownership, microphone hardware, macOS TCC grants, Launch at Login identity migration, or coexistence/competition with an already-installed stable HyperVibe. Those are intentionally left for the local-device smoke. Do not describe them as CI-verified.

## Local candidate build / smoke

Build and stage without touching the working installation first:

```sh
cd app
./build.sh

# Only needed if the Mac has more than one valid Apple Development identity:
# export HYPERVIBE_SIGN_ID='Apple Development: …'

HYPERVIBE_SIGN_MODE=developer ./create_app_bundle.sh
codesign --verify --deep --strict --verbose=2 ".build/HyperVibe-Dev.app"
```

A safe isolated self-test is available before any real-device cutover:

```sh
.build/HyperVibe-Dev.app/Contents/MacOS/HyperVibe --test-voice-input
```

That path is intentionally handled before App delegate startup and does not seize the Siri Remote, install input hooks or trigger TCC checks.

Do **not** launch the normal staged development UI while the installed stable HyperVibe is running; both can compete for Siri Remote HID/media handling.

For a real-device smoke:

1. preserve a rollback copy of `/Applications/HyperVibe.app`;
2. stop the stable process;
3. verify the candidate's nested signature;
4. install the candidate at the canonical path;
5. grant/re-check TCC permissions if the code identity changed;
6. run exactly one HyperVibe UI process;
7. verify remote buttons/touch, F10 press/release, disconnect/quit cleanup, Voice and Corpus behavior;
8. restore the stable bundle immediately if the smoke fails.

See `AGENTS.md` for the non-negotiable deployment rules.

## Behavior invariants carried forward

Architecture work must not intentionally change:

- Siri Remote HID event timing;
- immediate external F10 PTT down/up behavior;
- voice press/release Corpus boundaries;
- Keychain identity or migration policy;
- microphone routing/data path;
- MultitouchSupport signing topology.

### External Side/F10 route

Current behavior remains:

```text
physical Side press
  → immediate holdKeystroke(F10) key-down
  → optional Corpus begin

physical Side release
  → immediate F10 key-up
  → Corpus end
```

The base `button.siri = holdKeystroke(f10)` route owns the whole physical press/release lifecycle. Teardown paths must always release a live held key so F10 cannot remain latched after swallowed release, modal ownership, disconnect or App termination.

## Touch and synchronization hardening retained from 2026-10-08

The pre-R1 hardening remains part of the required baseline:

- touch starvation recovery is single-shot per quiet period instead of repeatedly stop/start cycling the touch device;
- `VoiceTextDeliveryWorker.currentFrontmostPID()` avoids main-to-main sync deadlock by reading AppKit directly when already on the main thread;
- `VoiceCorpusRecorder.flushForTermination()` drains through queue-aware `drainIOQueueAndRun()` rather than blindly synchronising onto its own queue.

Do not undo these while simplifying ownership.

## Voice Corpus contract

Canonical schema and invariants live in `docs/voice-corpus.md`.

The feature remains opt-in through `settings.corpusCaptureEnabled` / Settings → Voice. Raw capture follows the physical press/release boundary. Missing text is an observation state, not failure; missing labels are preferred to wrong audio/text pairing. Focus/Secure Input interruption and next-attempt attribution guards must remain conservative. Nightly ASR/VAD/alignment belongs to a later Analysis layer and must not rewrite Raw files.

## Voice capture audio-source state machine (2026-10-11)

The press-and-hold "no speech" failures came from the audio-source state machine mislabeling a
cold/un-started Siri Remote as a successful zero-frame `builtIn` capture. On a Mac with no built-in
microphone (Mac mini), the 650 ms probe locked each attempt to a silent `builtIn` source.

Fix (App side): the probe no longer falls back to `builtIn` when no built-in mic exists; it keeps
the remote pending and starts capture at the first remote frame, with an explicit ~3 s
`remote_start_timeout` recorded via `audio_capture_outcome` (`remote_captured` / `builtin_captured` /
`remote_start_timeout` / `no_frames`). Diagnostics now log producer-ready state at press,
first-frame latency and the final source. `BuiltinMicFeeder`/external-mic capability is retained.

Cold-start hardening (daemon side, `mic/captured/srm_captured.c`): PacketLogger's cold exec caused
7–12 s startup gaps after long idle. The stop-debounce rose to 10 s, PacketLogger is re-primed on a
60 s idle keep-warm (and 3 s after teardown) on a background serial queue with 1 s timer leeway, and
`pipeline up` now records `ready_ms`. A queued keep-warm is drained before a real pipeline start so
two PacketLogger HCI sessions never overlap. **Installed 2026-10-11** via `install.sh`; live daemon
logs `ready_ms` (warm starts ~148–320 ms) and fires the keep-warm on cadence. A first install left a
30 s timer leeway that could defer the post-teardown re-prime by up to 30 s (observed two ~6–10 s
cold starts); reduced to 1 s leeway + 3 s post-stop delay, after which no cold start recurred.
**Second install 2026-10-14** rebuilds the daemon with two robustness fixes (found in a 10-14 failure
triage): (1) the teardown now sends SIGTERM first so the router's signal handler clears the ring's
`producerActive`, then SIGKILL as a backstop plus a daemon-side `clear_remote_ring_active()`
shm/mmaps the ring and atomically stores `producerActive=0` — removing a stale `producerActive==1`
left by a SIGKILLed router. (2) The pre-warm now forks via `spawn_child_noblock()` (fork+execv with a
CLOEXEC status pipe) instead of `posix_spawn`, which blocked until the cold exec finished; the warm-up
can now observe `g_prewarm_cancel` within ~50 ms, so `start_pipeline`'s `dispatch_sync` drain returns
in a few hundred ms instead of stalling the main queue past the app's 3 s window. Liveness checks use
`waitpid`-based `child_gone()` (never `kill(pid,0)`, which can hit a recycled pid); `g_pipeline_up` is
now `_Atomic`. Installed 2026-10-14 11:53; live daemon logs `pipeline up ... ready_ms=242` on the first
warm demand. Note: `/var/log/srm_captured.log` had gone missing while the old daemon ran (fd pointed at
a deleted inode after log cleanup); the reload recreates it and restores daemon-side observability.
Memory note: the daemon itself is ~1.3 MB resident and flat — the recurring cold-start latency is
driven by system-wide memory pressure (swap near full, PacketLogger's pages evicted), not by daemon
memory use, so daemon self-restart/self-cleanup would not help.

## Current build and signing identity

Development packaging uses:

- default App bundle id: `org.tevriq.siriremoteforge`;
- Credential Broker id: `<app-bundle-id>.CredentialBroker`;
- the developer's own `Apple Development:` identity;
- optional exact identity selector: `HYPERVIBE_SIGN_ID`;
- optional bundle-id override: `HYPERVIBE_BUNDLE_ID`;
- no silent ad-hoc fallback for developer packaging.

The main App and Credential Broker trust relationship is Bundle ID + Apple Team ID rather than one exact leaf certificate. The outer App intentionally remains without hardened runtime because the private MultitouchSupport callback path is incompatible with it; nested Sparkle helpers retain hardened runtime.

A first install under a new certificate/bundle identity can legitimately require fresh Accessibility, Input Monitoring and Microphone grants plus a Launch at Login re-check.

## Local device gate — passed, 2026-10-09

Base: `main` @ `9aefbd1` plus #12 (`2a88d21`, local SwiftPM swiftmodule-layout fix).

- Core build/tests, App build, developer signing, strict nested codesign: pass.
- Isolated `--test-voice-input`: PASS (123 checks).
- Stable app identity was already `org.tevriq.siriremoteforge` / Team `JAMBVS7987` / same leaf cert, so TCC and Launch-at-Login carried over with no new grants.
- Candidate installed at `/Applications/HyperVibe.app`; exactly one UI process; HID event delivery and Voice Isolation DSP registration observed in logs; quit is clean (no crash, no latch).
- Rollback copy: `work/HyperVibe-stable-rollback-20261009.app` (pre-#12 stable bundle).
- Physical remote button/touch/F10 sweep requires the human operator and remains the only operator-owned acceptance item.

## Known deferred items

- The App is still one direct `swiftc` App target even though Core and RemoteInput state now have real module boundaries. Further target decomposition is separate work.
- The inherited Sparkle release infrastructure is not trusted for this fork. Non-local releases must explicitly supply this fork's update feed/key.
- Voice credentials use `org.tevriq.siriremoteforge.credentials.v1`; the historical namespace may be read only as a one-way migration source so stable-App rollback remains possible.
- Existing `au.holodata...` microphone component identifiers are intentionally unchanged; their ownership/upgrade migration remains separate work.
- The remaining strict-concurrency baseline is debt, not permission to add new warnings. CI must continue to reject growth; future work should shrink it incrementally.

## Active technical sources

- `AGENTS.md` — build/deployment operating rules;
- this file — current repository state and next local gate;
- `docs/architecture-r1-implementation.md` — Architecture R1 contract and actual acceptance;
- `docs/voice-corpus.md` — Raw Corpus contract;
- `mic/` — working microphone stack;
- `docs/mic-reverse-engineering.md` — useful microphone evidence/history.

Material under `deprecated/` is historical only.

By ChatGPT
