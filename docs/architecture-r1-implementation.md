# Architecture R1 — implementation contract

Status: implementation branch; not merged.

## Invariants
- No change to Siri Remote HID event timing, F10 delivery, voice press/release corpus boundaries, Keychain identity, microphone data path, or MultitouchSupport signing topology.
- Never replace or launch the installed stable HyperVibe during CI.
- Every phase must pass diff check, strict SiriRemoteCore build/test, App build, signing topology checks, and isolated Runtime Smoke before merge.

## Phase 1 — real Core module boundary
- Replace app/build.sh source-level compilation of SiriRemoteCore with a built module and linked library.
- Add explicit imports to App call sites. Keep existing public types and behavior.
- Ensure the exact Core module used by unit tests is the one used by the App. Add a CI assertion forbidding ../SiriRemoteCore/Sources paths in production Swift source lists.
- Keep arm64 and x86_64 support, Swift module compatibility, and clean-build reproducibility.

## Phase 2 — input state machines
- Extract pure multi-remote button, hold, repeat, multi-tap, layer and voice chord state transitions into RemoteInputCore.
- Keep HID callbacks and side effects in RemoteInputHandler.
- Add deterministic event-sequence tests, including disconnect/reconnect, overlapping remotes and timing boundaries.

## Phase 3 — App composition
- Extract DeveloperCommandRouter and lifecycle-owned AppRuntime/feature registry from SiriRemoteApp.swift.
- Avoid broad @MainActor annotation without explicit caller migration and tests.

## Phase 4 — concurrency ownership
- Migrate UI isolation and worker ownership at boundaries; reduce strict concurrency baseline rather than suppressing warnings.
- Audit timer/notification teardown and sync-to-self paths.

## Acceptance
- Each phase has independent commits and green GitHub Actions checks.
- Full runtime smoke on final branch; hardware-dependent Siri Remote/microphone/TCC behavior remains explicitly unverified by hosted runner.
- Update HANDOFF.md with actual results, not planned success.

By ChatGPT
