# HANDOFF — tevriqorg/SiriRemoteForge current development state

This is the **active** handoff for the tevriqorg fork. Historical upstream experiments, release logs
and superseded implementation notes are archived under `deprecated/`; they are reference material,
not current operating instructions.

Last structural refresh: 2026-09-23.

## Repository identity

- Development fork: `https://github.com/tevriqorg/SiriRemoteForge`
- Canonical upstream for provenance only: `https://github.com/HOLODATA-COM/SiriRemoteForge`
- Default branch: `main`
- Current development PR: **#1 — runtime lazy-loading + external Voice Corpus**
- Local configuration remains `~/.config/siriremote/config.jsonc`.
- Installed live App path remains `/Applications/HyperVibe.app` during real-device testing.

The source still carries the historical internal name **HyperVibe**. Do not mix a product rename into
the current runtime/corpus/signing migration.

## Current build and signing identity

The fork no longer uses the upstream `siriRemote Local Signing` certificate/keychain as its local
development identity.

Development packaging now uses:

- default App bundle id: `org.tevriq.siriremoteforge`;
- Credential Broker id: `<app-bundle-id>.CredentialBroker`;
- developer signing: the developer's own `Apple Development:` certificate;
- optional exact selector: `HYPERVIBE_SIGN_ID`;
- optional bundle-id override: `HYPERVIBE_BUNDLE_ID`;
- no silent ad-hoc fallback.

`app/create_app_bundle.sh` auto-selects an Apple Development identity only when exactly one valid
identity exists. Zero or multiple identities is a hard stop until the local machine supplies
`HYPERVIBE_SIGN_ID`.

The main App and Credential Broker now derive their peer bundle identifiers dynamically rather than
hard-coding `com.hypervibe.app`, while still requiring a matching certificate-bound designated
requirement.

The outer App intentionally remains without hardened runtime because the private MultitouchSupport
callback path is incompatible with it. Nested Sparkle helpers retain hardened runtime.

### Identity migration consequence

The first live install under the new certificate/bundle id is a genuine macOS code-identity change.
Expect fresh checks/prompts for Accessibility, Input Monitoring and Microphone, plus a Launch at
Login re-check. This is migration behavior, not by itself an App regression.

## Development build must not replace stable App first

Compilation/package verification happens before touching the user's working stable installation.

Recommended staging:

```sh
cd app
./build.sh

# Only needed when the Mac has more than one valid Apple Development identity:
# export HYPERVIBE_SIGN_ID='Apple Development: …'

HYPERVIBE_SIGN_MODE=developer ./create_app_bundle.sh
codesign --verify --deep --strict --verbose=2 ".build/HyperVibe-Dev.app"
```

Do **not** launch the staged development bundle while the installed stable App is running; both can
compete for Siri Remote HID/media handling.

For real-device smoke testing:

1. preserve a rollback copy of `/Applications/HyperVibe.app`;
2. stop the stable process;
3. verify the candidate's nested signature;
4. install the candidate at the canonical path;
5. grant/re-check TCC permissions for the new identity;
6. run exactly one HyperVibe UI process;
7. restore the stable bundle immediately if the smoke test fails.

See `AGENTS.md` for the non-negotiable form of these rules.

## Current runtime refactor in PR #1

The goal is “disabled feature + relaunch = subsystem is not constructed/prewarmed”, without deleting
feature source yet.

Launch/on-demand gating currently covers:

- Native Voice coordinator / credential preload / network prewarm;
- Voice Pipeline HUD;
- Status Widget;
- Long-press HUD;
- Demo Remote controller/observers;
- Sparkle updater controller when automatic checks are disabled;
- App Wheel controller/model until first summon.

`SettingsWindowController` was inspected and its expensive SwiftUI window/hosting controller was
already lazy.

`BuiltinMicFeeder` intentionally remains available because it also serves the external/virtual-mic
path. Do not gate it behind Native Voice without proving the external Siri Remote microphone path
does not depend on it.

## External Side/F10 behavior

The current real workflow is:

```text
physical Side press
  → immediate holdKeystroke(F10) key-down
  → optional Corpus begin

physical Side release
  → immediate F10 key-up
  → Corpus end
```

The old 0.2 s promotion delay was removed from `holdKeystroke`. A true held shortcut mirrors the
physical button directly. `pushToTalk` and Native Voice retain their separate promotion/tap
semantics.

Every teardown path must release a live held key: swallowed release, modal ownership, remote
disconnect and normal App termination must not leave F10 latched down.

## Voice Corpus

Canonical schema and invariants: `docs/voice-corpus.md`.

The feature is opt-in through `settings.corpusCaptureEnabled` / Settings → Voice.

Default root:

```text
~/Library/Application Support/HyperVibe/Corpus/
└── YYYY-MM-DD/
    └── <time-id>/
        ├── audio.wav
        ├── capture.json
        ├── observation.json
        ├── ime.clipboard.json       # optional
        └── ime.accessibility.json   # optional
```

Raw policy:

- physical press/release defines the sample boundary;
- no VAD, text-presence, short-press or minimum-speech filter deletes Raw data;
- missing text is normal observation state, not failure;
- Raw does not infer network failure, IME failure or absence of speech;
- starting attempt N+1 closes N's pending text-attribution watcher before N+1 can own new text,
  even if Corpus has just been disabled or N+1 cannot create its sample directory;
- a focus change or Secure Input appearing during the post-release observation window ends text
  attribution immediately (`interrupted_by_focus_change` / `interrupted_by_secure_input`);
- missing labels are preferred to wrong audio/text pairing;
- normal App termination synchronously drains pending Corpus writes where possible;
- Corpus audio is streamed directly to its WAV spool instead of retaining the whole utterance PCM or
  an unconsumed AsyncStream. `capture.json` records generated vs stored frame counts and
  `audio_storage_status`; long thinking holds therefore grow disk usage rather than linearly
  growing App memory.

Nightly ASR/VAD/alignment belongs to a later **Analysis** layer and must not overwrite Raw files.

## Known deferred issues

These are known but intentionally outside the current first compile/smoke pass:

1. Native Voice remains structurally unreachable behind a base `holdKeystroke` binding because the
   held-shortcut branch has higher routing priority. Do not “fix” that while validating the external
   F10 workflow unless the task explicitly changes scope.
2. The App is still a monolithic swiftc target. Runtime laziness is phase 1; a later target/module
   split is the place to stop linking unused frameworks entirely.
3. The inherited Sparkle release infrastructure is **not trusted for this fork**. Local `-local.`
   builds embed no feed/key and disable both scheduled and manual checks. Any future non-local
   release must explicitly supply this fork's own `HYPERVIBE_UPDATE_FEED_URL` and
   `HYPERVIBE_UPDATE_PUBLIC_KEY`; packaging fails otherwise.
4. The Keychain service string `com.hypervibe.credentials.v6` is retained for compatibility for
   now; it is not the App's code-signing identity.

## Validation gate

PR #1 stays Draft until the real Mac validates the current head. Tracking issue: **#2**.

Minimum source/build checks:

```sh
git diff --check main...chatgpt/lazy-disabled-subsystems-20260922
swift build --package-path SiriRemoteCore
swift test --package-path SiriRemoteCore
cd app && ./build.sh
```

Then package (without installing) using Apple Development signing and strict nested verification.

The first real-device smoke must verify at least:

- immediate F10 down/up with Corpus OFF;
- no stuck F10 on disconnect/quit;
- disabled heavy subsystems are absent at launch;
- Corpus normal sentence;
- speech with no observed IME text;
- silence/thinking;
- very short press;
- two close attempts without cross-attribution;
- quit/relaunch immediately after a release;
- audio source is normally the Siri Remote rather than unintended built-in fallback;
- memory before/after with the same feature settings.

Do not merge based on static review alone.

## Active vs deprecated material

Active technical sources:

- `AGENTS.md` — operating/build/deployment rules;
- this file — current state and next gate;
- `docs/voice-corpus.md` — Raw Corpus contract;
- `mic/` — working microphone stack;
- `docs/mic-reverse-engineering.md` — still-useful microphone evidence/history.

Archived material:

- `deprecated/HANDOFF-legacy-upstream-2026-09-23.md` — previous 275 KB living handoff/history;
- `deprecated/driverkit/` — superseded DriverKit proof of concept.

Do not treat files under `deprecated/` as current instructions.

By ChatGPT
