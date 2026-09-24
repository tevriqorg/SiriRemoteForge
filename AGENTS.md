# Project operating rules

These rules apply to the tevriqorg development fork. Historical upstream rules live under
`deprecated/` and are not active instructions.

## Build identity

1. Local development App bundles use this fork's identity:
   - default App bundle id: `org.tevriq.siriremoteforge`;
   - Credential Broker bundle id: `<app-bundle-id>.CredentialBroker`.
   Override the App id only with `HYPERVIBE_BUNDLE_ID`; the broker follows automatically.
2. Development signing uses the developer's own **Apple Development** certificate.
   `app/create_app_bundle.sh` selects:
   - the exact `HYPERVIBE_SIGN_ID`, when supplied; otherwise
   - the single valid `Apple Development:` identity in the normal keychain search list.
   If none or more than one is available, stop and require an explicit choice.
3. Never silently fall back to ad-hoc signing for a development build. `adhoc` exists only for an
   explicitly requested public/release artifact.
4. App ↔ Credential Broker trust is bundle identifier + Apple Team ID. Do not pin normal
   development trust to one leaf certificate, and do not weaken it to identifier-only validation.
5. Fork Keychain credentials use `org.tevriq.siriremoteforge.credentials.v1`. Legacy
   `com.hypervibe.credentials.v6` may be read only as a non-destructive migration source; migration
   must not delete it because the currently installed stable App may need it for rollback.
6. The outer App deliberately remains without hardened runtime because the current
   MultitouchSupport callback path is incompatible with it. Nested Sparkle helpers retain their
   hardened-runtime signing.
7. A change of signing certificate or bundle id is a macOS code-identity migration. Expect the
   first live install to require fresh Accessibility / Input Monitoring / Microphone authorization
   and re-check Launch at Login. Do not diagnose those first-run prompts as feature regressions.

## Development build vs live App

1. Building, unit testing, packaging and signature verification must happen **without replacing the
   currently installed stable App**.
2. A development bundle should be staged outside `/Applications`, for example:
   `app/.build/HyperVibe-Dev.app`. Do not launch it while the installed stable App is running:
   both would compete for Siri Remote HID/media handling.
3. Before the first real-device smoke test of a new development identity:
   - preserve a rollback copy of the currently installed `/Applications/HyperVibe.app`;
   - stop the stable process;
   - verify the development bundle's full nested signature;
   - only then install the candidate at `/Applications/HyperVibe.app`.
4. During live testing there must be exactly one HyperVibe UI process, executing
   `/Applications/HyperVibe.app/Contents/MacOS/HyperVibe`.
5. If smoke testing fails, restore the preserved stable bundle and its one-process state before
   ending the task. Never leave a half-installed development build as the user's only working copy.

## Repository and validation

1. Current implementation/state belongs in `HANDOFF.md`; historical experiments and superseded
   handoffs belong in `deprecated/`.
2. The working virtual-microphone stack is `mic/`. The old DriverKit proof of concept is archived
   under `deprecated/driverkit/` and is not part of the active build.
3. Before merge:
   - `git diff --check`;
   - `swift build --package-path SiriRemoteCore`;
   - `swift test --package-path SiriRemoteCore`;
   - `cd app && ./build.sh`;
   - package with Apple Development signing and run strict nested `codesign --verify`.
4. GitHub issues, comments and commits made for this fork end with `By ChatGPT`.
5. Local `-local.` builds must not embed or contact a Sparkle feed. A non-local release package must
   supply both `HYPERVIBE_UPDATE_FEED_URL` and `HYPERVIBE_UPDATE_PUBLIC_KEY`, owned by this fork;
   never reuse the inherited upstream appcast/key.

Public release signing/notarization is a separate workflow and must not be inferred from the local
Apple Development workflow.
