# Swift concurrency ownership

`SiriRemoteCore` is required to build and test with `-warn-concurrency` and
`-strict-concurrency=complete` without warnings. The App is also compiled in complete
concurrency-checking mode in CI, but its current AppKit/Cocoa ownership migration is
tracked by `scripts/swift-concurrency-baseline.txt`. The gate rejects any new warning or
an increased count for an existing warning. Existing entries may only stay flat or shrink.

The App baseline is migration debt, not a statement that every diagnostic is harmless.
A full `@MainActor` experiment showed that converting the legacy AppKit composition root,
timers, notifications, and HUD/window controllers is an architecture migration: it changes
isolation at `main.swift`, deinitializers, Timer callbacks, and Notification callbacks.
That migration must be behavior-tested separately rather than mixed into a safety cleanup.

## Audited unchecked-Sendable invariants

`@unchecked Sendable` is allowed only where the type documents the synchronization rule:

- Voice audio capture and Corpus WAV spooling confine mutable state to a serial queue or lock.
- Voice history serializes its cache/filesystem state; blocking reads use same-queue guards.
- Realtime callback routing and correction monitoring protect shared tokens/handlers by lock.
- Realtime transcription protects close state by lock and transcript state by actor; its
  receive task is installed before the object escapes `connect`.
- Voice text delivery owns cross-process Accessibility work on a private serial worker.
- Voice feedback confines AVAudioPlayer instances to its playback queue.
- Voice text processing protects mutable prewarm caches by lock and delegates history writes
  to the queue-owned history store.
- The Corpus persistence helper carries immutable snapshots across its I/O boundary.
- The self-test timing probe uses a lock around its single mutable timestamp.

Queue-confined synchronous helpers must execute inline when already on their own queue.
`VoiceAudioCaptureSession`, `VoiceHistoryStore`, and Corpus termination draining follow this
rule so a future queue-owned caller cannot introduce a sync-to-self deadlock.

Do not suppress a new diagnostic merely by adding `@unchecked Sendable`. Either establish
and document a real ownership invariant, move the state behind an actor/serial queue/lock,
or keep the warning visible until the structural migration owns it.
