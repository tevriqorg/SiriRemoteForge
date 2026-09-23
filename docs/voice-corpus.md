# Voice Corpus Raw Data Contract

Voice Corpus is an opt-in local recorder for the external Siri Remote voice workflow. Its job is to
preserve facts, not to decide whether an utterance was "good", whether the user spoke, whether the
IME failed, or whether the network was available.

## Boundary

For the current `button.siri = holdKeystroke(f10)` workflow:

- physical Side press = raw attempt start;
- F10 key-down is emitted immediately on that press;
- Corpus audio capture starts on the same continuous-action edge;
- physical Side release = F10 key-up + raw attempt end.

There is no 0.2 second activation gate for `holdKeystroke`. Very short presses, long thinking pauses,
silence and environmental sound are preserved. VAD must never decide the Raw boundary.

`pushToTalk` and Native Voice are separate features and retain their own promotion/tap semantics.

## Storage

Default root:

```text
~/Library/Application Support/HyperVibe/Corpus/
└── YYYY-MM-DD/
    └── HHmmss-SSS-<id>/
        ├── audio.wav
        ├── capture.json
        ├── observation.json
        ├── ime.clipboard.json       # optional
        └── ime.accessibility.json   # optional
```

Directory permissions are 0700. Sample files are 0600.

### audio.wav

Mono PCM16 produced by the existing `VoiceAudioCaptureSession`. The capture chooses the live Siri
Remote ring when available and otherwise falls back to the built-in microphone ring. The chosen
source is recorded in `capture.json`.

### capture.json

Immutable physical/capture facts:

- attempt id;
- start/end timestamps;
- resolved action and shortcut;
- frontmost application metadata;
- audio source, sample rate, frame count, duration and mean-square level.

The presence or absence of speech is not decided here.

### ime.clipboard.json

Best-effort observation only. Written when the pasteboard changes after the attempt while:

- the application that was frontmost at attempt start is still frontmost; and
- Secure Input is not active.

A clipboard observation is evidence, not automatically ground truth.

### ime.accessibility.json

Best-effort observation only. When the original focused text field exposes readable Accessibility
text, HyperVibe stores only the changed span after the attempt. The field's pre-existing contents are
never persisted. Secure fields and Secure Input are excluded.

### observation.json

Final raw observation state. Typical fields include:

```json
{
  "text_status": "not_observed",
  "clipboard_observed": false,
  "accessibility_observed": false,
  "frontmost_app_changed": false,
  "secure_input_seen": false,
  "speech_status": "not_analyzed",
  "ime_outcome": "not_inferred",
  "network_status": "not_measured"
}
```

`text_status` is observational, not evaluative:

- `observed`: at least one text source was observed;
- `not_observed`: no text source was observed within the configured post-release window;
- `interrupted_by_next_attempt`: a newer physical attempt took ownership of text attribution first;
- `interrupted_by_app_termination`: the App shut down while the attempt/observation was still open.

No-text does **not** mean "IME failed". It may represent, among other things:

- real speech while the IME had no usable network/service;
- a long thinking pause or environmental sound with no speech;
- speech that the IME chose not to transcribe;
- text that the App could not observe through Clipboard or Accessibility;
- a very short press;
- another condition not knowable at capture time.

Raw data therefore keeps `speech_status = not_analyzed`, `ime_outcome = not_inferred`, and
`network_status = not_measured` until a later analysis layer has actual evidence.

## Attribution rule

A missing label is safer than a wrong label.

After release, text is observed for a bounded window. If a new Side attempt begins before the
previous window completes, the previous watcher is finalized before the new attempt owns
attribution. Text from sample N+1 must never be attached to audio from sample N.

## Raw → Analysis → Dataset

The intended pipeline is:

```text
Raw Corpus
  audio + factual observations
        ↓
Nightly Analysis
  VAD / ASR / alignment / confidence / anomaly labels
        ↓
Curated Dataset
  selected training/evaluation examples
```

Nightly analysis may add derived files, but must not overwrite Raw audio, `capture.json`, or the
original IME observations. A newer model should be able to reprocess the same historical Raw corpus.

Examples of analysis-time classifications include:

- speech + observed IME text;
- speech + no observed IME text;
- silence / environmental audio;
- long pause with late speech;
- short/likely accidental press;
- ASR/IME disagreement.

Those are derived labels, not capture-time facts.

## Shutdown and abnormal termination

Remote disconnect and other press-scoped teardown paths release a live held shortcut and close the
Corpus attempt. Normal App termination additionally drains the active/pending capture and queued
Corpus writes synchronously before exit.

A forced process kill, OS crash or power loss cannot be made durable by an in-process recorder alone.
If crash-level durability later becomes important, the storage layer should move to incremental
audio journaling rather than changing the Raw semantics above.

By ChatGPT
