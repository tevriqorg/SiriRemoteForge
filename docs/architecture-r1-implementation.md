# Architecture R1 — implementation contract

Status: **implementation complete; hosted-runner acceptance passed; pending final PR #8 merge to `main`.**

## Invariants
- No intentional change to Siri Remote HID event timing, F10 delivery, voice press/release corpus boundaries, Keychain identity, microphone data path, or MultitouchSupport signing topology.
- CI never replaces or launches the installed stable HyperVibe.
- Every implementation phase must pass diff checks, strict SiriRemoteCore build/test, App build, signing topology checks, and the relevant isolated runtime checks before merge.

## Phase 1 — real Core module boundary — COMPLETE
- Production App builds and links the real SwiftPM `SiriRemoteCore` module instead of recompiling Core sources into the App target.
- App call sites import the module explicitly; public types and behavior remain compatible.
- CI forbids production Swift source lists from compiling `../SiriRemoteCore/Sources` directly.
- Static-library topology preserves the existing single-bundle runtime/signing model.

## Phase 2 — input state machines — COMPLETE
- Pure multi-remote button, hold, repeat, multi-tap, layer and voice-chord state moved into `RemoteInputCore`.
- HID callbacks and side effects remain in `RemoteInputHandler`.
- Deterministic tests cover disconnect/reconnect, overlapping remotes and timing/state boundaries.
- Validated staging commit: `f75cbfdb956b63667fc6012406ca63f519f26488`; landed into the R1 branch through PR #9.

## Phase 3 — App composition — COMPLETE
- `AppRuntime` owns the long-lived physical-input subsystem graph and passive-input teardown boundary.
- `DeveloperCommandRouter` owns immutable developer/test/snapshot command-line routing.
- `SiriRemoteApp.swift` remains the AppKit composition root; no broad `@MainActor` blanket annotation was introduced.
- Validated staging commit: `83425fbfbce2016b36eda0b4aac7fd045bb7504a`; landed into the R1 branch through PR #10.

## Phase 4 — concurrency ownership — COMPLETE
- UI/worker ownership and teardown paths were audited, including guarded `DispatchQueue.main.sync`, Corpus queue draining, permission timer/observer teardown and passive-input teardown.
- Two real `WindowControl` strict-concurrency diagnostics were removed by eliminating shared stored `CFString` state; the checked-in concurrency baseline was reduced by the same two entries. No warning suppression was added.
- Validated staging commit: `ba6f7e40a8271562c019413ba67ba131a39a3d12`; landed into the R1 branch through PR #11.

## Actual acceptance results — 2026-10-09

The final Phase 4 hosted-runner gate passed all of the following:

- ownership/teardown audit;
- strict `SiriRemoteCore` build;
- strict `SiriRemoteCore` tests;
- strict App concurrency diagnostics against the **smaller** baseline;
- ordinary App build;
- ad-hoc development bundle assembly;
- strict nested `codesign --verify`;
- isolated `--test-voice-input` Runtime Smoke using the staged bundle.

Phase 2 and Phase 3/4 independently passed the same build/test/concurrency/package/signing gates before their staging commits were merged into the R1 branch.

Hosted GitHub runners cannot validate real Siri Remote HID ownership, microphone hardware, macOS TCC grants, Launch at Login identity migration, or competition with an already-installed production HyperVibe. Those remain explicitly **unverified by hosted runner** and are the only remaining local-device smoke surface.

By ChatGPT
