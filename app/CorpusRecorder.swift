//
//  CorpusRecorder.swift
//  HyperVibe
//
//  Long-term, append-oriented capture for the external Siri-button voice workflow.
//  It deliberately does NOT depend on Native Voice or any cloud model: one physical
//  external-voice hold becomes an immutable WAV + capture metadata, and a best-effort
//  clipboard observation is written separately if the IME publishes one.
//

import AppKit
import ApplicationServices
import Carbon
import Foundation

private final class VoiceCorpusWAVSpool {
    struct Finalization {
        let status: String
        let storedFrameCount: Int
    }

    private let lock = NSLock()
    private var handle: FileHandle?
    private var url: URL?
    private var bufferedBeforeConfigure: [Data] = []
    private var pcmBytesWritten = 0
    private var writeError: Error?
    private var finalized = false

    /// Capture starts before filesystem setup so the physical press edge remains authoritative.
    /// Chunks arriving in that brief gap are kept only until configure() installs the file handle.
    func configure(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil, !finalized else {
            throw CocoaError(.fileWriteUnknown)
        }

        let header = Self.wavHeader(sampleRate: VoiceAudioCaptureSession.outputSampleRate, pcmBytes: 0)
        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            self.handle = handle
            self.url = url
            for chunk in bufferedBeforeConfigure {
                try handle.write(contentsOf: chunk)
                pcmBytesWritten += chunk.count
            }
            bufferedBeforeConfigure.removeAll(keepingCapacity: false)
        } catch {
            try? self.handle?.close()
            self.handle = nil
            self.url = nil
            bufferedBeforeConfigure.removeAll(keepingCapacity: false)
            throw error
        }
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finalized, writeError == nil else { return }

        guard let handle else {
            bufferedBeforeConfigure.append(chunk)
            return
        }
        do {
            try handle.write(contentsOf: chunk)
            pcmBytesWritten += chunk.count
        } catch {
            writeError = error
        }
    }

    /// Filesystem setup is asynchronous so it cannot delay a physical button edge. If setup fails,
    /// stop accepting pre-config chunks immediately instead of growing RAM for the rest of the hold.
    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        writeError = writeError ?? error
        bufferedBeforeConfigure.removeAll(keepingCapacity: false)
        try? handle?.close()
        handle = nil
    }

    func finalize(sampleRate: Int, expectedFrameCount: Int) -> Finalization {
        lock.lock()
        defer { lock.unlock() }

        if finalized {
            let frames = pcmBytesWritten / MemoryLayout<Int16>.size
            let complete = writeError == nil && frames == expectedFrameCount
            return Finalization(status: complete ? "complete" : "incomplete",
                                storedFrameCount: frames)
        }
        finalized = true

        if handle == nil, !bufferedBeforeConfigure.isEmpty {
            writeError = writeError ?? CocoaError(.fileWriteUnknown)
            bufferedBeforeConfigure.removeAll(keepingCapacity: false)
        }

        if let handle {
            do {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Self.wavHeader(
                    sampleRate: sampleRate,
                    pcmBytes: pcmBytesWritten
                ))
                try handle.synchronize()
                try handle.close()
            } catch {
                writeError = writeError ?? error
                try? handle.close()
            }
            self.handle = nil
        } else if url == nil {
            writeError = writeError ?? CocoaError(.fileWriteUnknown)
        }

        let storedFrames = pcmBytesWritten / MemoryLayout<Int16>.size
        let complete = writeError == nil && storedFrames == expectedFrameCount
        return Finalization(
            status: complete ? "complete" : "incomplete",
            storedFrameCount: storedFrames
        )
    }

    private static func wavHeader(sampleRate: Int, pcmBytes: Int) -> Data {
        let safePCMBytes = max(0, min(pcmBytes, Int(UInt32.max) - 36))
        var data = Data()
        appendASCII("RIFF", to: &data)
        appendLE(UInt32(36 + safePCMBytes), to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt32(sampleRate), to: &data)
        appendLE(UInt32(sampleRate * 2), to: &data)
        appendLE(UInt16(2), to: &data)
        appendLE(UInt16(16), to: &data)
        appendASCII("data", to: &data)
        appendLE(UInt32(safePCMBytes), to: &data)
        return data
    }

    private static func appendASCII(_ string: String, to data: inout Data) {
        if let bytes = string.data(using: .ascii) { data.append(bytes) }
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

final class VoiceCorpusRecorder {
    private final class Session {
        let id: UUID
        let startedAt: Date
        let directoryURL: URL
        let actionKey: String
        let actionKind: String
        let shortcutKeys: String
        let applicationName: String?
        let bundleIdentifier: String?
        let applicationPID: pid_t?
        let clipboardBaselineChangeCount: Int
        let capture: VoiceAudioCaptureSession
        let audioSpool: VoiceCorpusWAVSpool
        var textTarget: VoiceTextTarget?
        var endedAt: Date?
        var clipboardCaptured = false
        var accessibilityCaptured = false
        var frontmostAppChangedDuringObservation = false
        var focusTargetChangedDuringObservation = false
        var secureInputSeenDuringObservation = false
        var axProbeInFlight = false

        init(id: UUID, startedAt: Date, directoryURL: URL,
             actionKey: String, actionKind: String, shortcutKeys: String,
             applicationName: String?, bundleIdentifier: String?, applicationPID: pid_t?,
             clipboardBaselineChangeCount: Int, capture: VoiceAudioCaptureSession,
             audioSpool: VoiceCorpusWAVSpool) {
            self.id = id
            self.startedAt = startedAt
            self.directoryURL = directoryURL
            self.actionKey = actionKey
            self.actionKind = actionKind
            self.shortcutKeys = shortcutKeys
            self.applicationName = applicationName
            self.bundleIdentifier = bundleIdentifier
            self.applicationPID = applicationPID
            self.clipboardBaselineChangeCount = clipboardBaselineChangeCount
            self.capture = capture
            self.audioSpool = audioSpool
        }
    }

    private struct CaptureRecord: Codable {
        let version: Int
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let actionKey: String
        let actionKind: String
        let shortcutKeys: String
        let applicationName: String?
        let bundleIdentifier: String?
        let audioFile: String
        let audioSource: String
        let audioStorageStatus: String
        let audioStoredFrameCount: Int
        let sampleRate: Int
        let frameCount: Int
        let durationSeconds: Double
        let meanSquare: Double

        private enum CodingKeys: String, CodingKey {
            case version, id
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case actionKey = "action_key"
            case actionKind = "action_kind"
            case shortcutKeys = "shortcut_keys"
            case applicationName = "application_name"
            case bundleIdentifier = "bundle_identifier"
            case audioFile = "audio_file"
            case audioSource = "audio_source"
            case audioStorageStatus = "audio_storage_status"
            case audioStoredFrameCount = "audio_stored_frame_count"
            case sampleRate = "sample_rate"
            case frameCount = "frame_count"
            case durationSeconds = "duration_seconds"
            case meanSquare = "mean_square"
        }
    }

    private struct AttemptObservation: Codable {
        let version: Int
        let id: UUID
        let finalizedAt: Date
        let textStatus: String
        let clipboardObserved: Bool
        let accessibilityObserved: Bool
        let frontmostAppChanged: Bool
        let focusTargetChanged: Bool
        let secureInputSeen: Bool
        let observationWindowLimitSeconds: Double
        let speechStatus: String
        let imeOutcome: String
        let networkStatus: String

        private enum CodingKeys: String, CodingKey {
            case version, id
            case finalizedAt = "finalized_at"
            case textStatus = "text_status"
            case clipboardObserved = "clipboard_observed"
            case accessibilityObserved = "accessibility_observed"
            case frontmostAppChanged = "frontmost_app_changed"
            case focusTargetChanged = "focus_target_changed"
            case secureInputSeen = "secure_input_seen"
            case observationWindowLimitSeconds = "observation_window_limit_seconds"
            case speechStatus = "speech_status"
            case imeOutcome = "ime_outcome"
            case networkStatus = "network_status"
        }
    }

    private struct IMEObservation: Codable {
        let version: Int
        let capturedAt: Date
        let source: String
        let text: String
        let attributionStatus: String
        let pasteboardChangeCount: Int?
        let replacedCharacterCount: Int?

        private enum CodingKeys: String, CodingKey {
            case version, source, text
            case capturedAt = "captured_at"
            case attributionStatus = "attribution_status"
            case pasteboardChangeCount = "pasteboard_change_count"
            case replacedCharacterCount = "replaced_character_count"
        }
    }

    private let fileManager: FileManager
    let rootURL: URL
    private let ioQueue = DispatchQueue(label: "com.hypervibe.voice-corpus", qos: .utility)
    private let onStorageStatus: (String?) -> Void
    private var active: Session?
    private var pendingObservation: Session?
    private var clipboardWatchGeneration = 0
    private let textObservationInterval: TimeInterval = 0.1
    private let textObservationAttempts = 50

    init(rootURL: URL? = nil, fileManager: FileManager = .default,
         onStorageStatus: @escaping (String?) -> Void = { _ in }) {
        self.fileManager = fileManager
        self.onStorageStatus = onStorageStatus
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.rootURL = rootURL ?? base
            .appendingPathComponent("HyperVibe", isDirectory: true)
            .appendingPathComponent("Corpus", isDirectory: true)
    }

    var isRecording: Bool { active != nil }

    /// Begin one external voice sample on the same raw press edge that starts the held shortcut.
    /// There is intentionally no duration/speech/text gate: even a very short press, silence, or
    /// an IME/network failure remains a valid raw attempt for later analysis.
    func begin(_ handled: Controller.HandledAction) {
        guard active == nil else {
            rmDebug("🗂 corpus: ignored overlapping begin for \(handled.key)")
            return
        }
        guard let action = Self.externalVoiceAction(handled.action) else { return }

        // Attribution ownership changes on the physical attempt edge, not after filesystem setup.
        // This must happen even if the new sample later cannot be persisted.
        invalidatePendingObservationForNewAttempt()

        let id = UUID()
        let startedAt = Date()
        let app = NSWorkspace.shared.frontmostApplication
        let pasteboard = NSPasteboard.general

        // Keep only O(1) capture/state work on the physical button edge. Filesystem setup and AX
        // messaging happen off-thread so Corpus cannot stretch the external F10 key lifecycle.
        let audioSpool = VoiceCorpusWAVSpool()
        let capture = VoiceAudioCaptureSession(
            minimumDuration: 0,
            maxDuration: 3_600,
            onMinimumDurationReached: {},
            onMaximumDuration: { rmDebug("🗂 corpus: one-hour emergency safety cap reached") },
            retainPCM: false,
            streamChunks: false,
            onPCMChunk: { [weak audioSpool] chunk in audioSpool?.append(chunk) }
        )
        capture.start()

        let directoryURL = sampleDirectory(id: id, date: startedAt)
        let session = Session(
            id: id,
            startedAt: startedAt,
            directoryURL: directoryURL,
            actionKey: handled.key,
            actionKind: action.kind,
            shortcutKeys: action.keys,
            applicationName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            applicationPID: app?.processIdentifier,
            clipboardBaselineChangeCount: pasteboard.changeCount,
            capture: capture,
            audioSpool: audioSpool
        )
        active = session

        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.prepareDirectory(directoryURL)
                try audioSpool.configure(at: directoryURL.appendingPathComponent("audio.wav"))
            } catch {
                audioSpool.fail(error)
                try? self.fileManager.removeItem(at: directoryURL)
                self.reportStorageFailure(
                    "Voice Corpus cannot prepare its sample directory: \(error.localizedDescription)"
                )
            }
        }

        // Resolve the pre-attempt AX target away from the input callback. Observation later
        // re-validates the focused element before any changed text is attributed to this sample.
        if let app {
            let seed = VoiceTextTargetSeed(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                applicationName: app.localizedName ?? L("Current App")
            )
            DispatchQueue.global(qos: .userInitiated).async {
                let target = VoiceTextDeliverer.resolveTarget(seed)
                DispatchQueue.main.async {
                    // If a very short press ended before the baseline was captured, prefer no AX
                    // label. A post-release "before" snapshot can only create false confidence.
                    guard session.endedAt == nil,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier
                            == session.applicationPID,
                          !target.isSecure else { return }
                    session.textTarget = target
                }
            }
        }
        rmDebug("🗂 corpus: began id=\(id.uuidString) key=\(handled.key)")
    }

    /// A newer physical external-voice attempt takes text-attribution ownership immediately,
    /// even when Corpus has just been disabled or the new sample cannot be persisted. Missing text
    /// on the older sample is safer than attaching the newer attempt's IME result to it.
    func invalidatePendingObservationForNewAttempt() {
        if let previous = pendingObservation {
            finalizeObservation(
                previous,
                textStatus: previous.accessibilityCaptured
                    ? "observed" : "interrupted_by_next_attempt"
            )
            pendingObservation = nil
        }
        clipboardWatchGeneration &+= 1
    }

    /// End the matching external voice sample. Audio persistence happens off the main thread.
    /// Clipboard observation remains deliberately best-effort: it records only a change made after
    /// this utterance began, never the pre-existing clipboard contents.
    func end(actionKey: String) {
        guard let session = active, session.actionKey == actionKey else { return }
        active = nil
        let endedAt = Date()
        session.endedAt = endedAt
        let watchGeneration = clipboardWatchGeneration
        pendingObservation = session
        watchTextObservations(for: session, generation: watchGeneration, attempt: 0)

        Task { [weak self] in
            let audio = await session.capture.stop()
            guard let self else { return }
            self.ioQueue.async {
                let storage = session.audioSpool.finalize(
                    sampleRate: audio.sampleRate,
                    expectedFrameCount: audio.frameCount
                )
                self.persistCapture(
                    session: session,
                    endedAt: endedAt,
                    audio: audio,
                    storage: storage
                )
            }
        }
    }

    private static func externalVoiceAction(_ action: Action) -> (kind: String, keys: String)? {
        switch action {
        case .holdKeystroke(let keys):
            return ("holdKeystroke", keys)
        case .pushToTalk(let keys):
            return ("pushToTalk", keys)
        default:
            return nil
        }
    }

    private func sampleDirectory(id: UUID, date: Date) -> URL {
        let day = Self.dayFormatter.string(from: date)
        let stamp = Self.sampleFormatter.string(from: date)
        let suffix = id.uuidString.prefix(8).lowercased()
        return rootURL
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)
    }

    private func prepareDirectory(_ url: URL) throws {
        let dayURL = url.deletingLastPathComponent()
        for directory in [rootURL, dayURL, url] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }
    }

    private func persistCapture(
        session: Session,
        endedAt: Date,
        audio: VoiceCapturedAudio,
        storage: VoiceCorpusWAVSpool.Finalization
    ) {
        if storage.status != "complete" {
            reportStorageFailure(
                "Voice Corpus audio is incomplete for sample \(session.id.uuidString)."
            )
        }
        do {
            let recordURL = session.directoryURL.appendingPathComponent("capture.json")
            let record = CaptureRecord(
                version: 1,
                id: session.id,
                startedAt: session.startedAt,
                endedAt: endedAt,
                actionKey: session.actionKey,
                actionKind: session.actionKind,
                shortcutKeys: session.shortcutKeys,
                applicationName: session.applicationName,
                bundleIdentifier: session.bundleIdentifier,
                audioFile: "audio.wav",
                audioSource: audio.source.rawValue,
                audioStorageStatus: storage.status,
                audioStoredFrameCount: storage.storedFrameCount,
                sampleRate: audio.sampleRate,
                frameCount: audio.frameCount,
                durationSeconds: audio.duration,
                meanSquare: audio.meanSquare
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(record).write(to: recordURL, options: .atomic)
            try secureFile(recordURL)
            rmDebug("🗂 corpus: saved id=\(session.id.uuidString) "
                    + "source=\(audio.source.rawValue) duration=\(String(format: "%.2f", audio.duration))s "
                    + "storage=\(storage.status) frames=\(storage.storedFrameCount)/\(audio.frameCount)")
        } catch {
            reportStorageFailure(
                "Voice Corpus cannot save capture metadata: \(error.localizedDescription)"
            )
            rmDebug("🗂 corpus: metadata save failed id=\(session.id.uuidString): "
                    + error.localizedDescription)
        }
    }

    /// Poll briefly after release because external IMEs often publish their completed string a few
    /// hundred milliseconds later. Clipboard and Accessibility are independent observations: when
    /// both are available we keep both, allowing later offline alignment to decide which is useful.
    /// A new utterance invalidates the previous watch so text from sample N+1 cannot attach to N.
    private func watchTextObservations(for session: Session, generation: Int, attempt: Int) {
        guard generation == clipboardWatchGeneration,
              pendingObservation === session else { return }

        let secureInput = IsSecureEventInputEnabled()
        let sameFrontmostApp =
            NSWorkspace.shared.frontmostApplication?.processIdentifier == session.applicationPID

        if secureInput {
            session.secureInputSeenDuringObservation = true
            let status = session.accessibilityCaptured
                ? "observed" : "interrupted_by_secure_input"
            finalizeObservation(session, textStatus: status)
            if pendingObservation === session { pendingObservation = nil }
            return
        }
        if !sameFrontmostApp {
            session.frontmostAppChangedDuringObservation = true
            let status = session.accessibilityCaptured
                ? "observed" : "interrupted_by_focus_change"
            finalizeObservation(session, textStatus: status)
            if pendingObservation === session { pendingObservation = nil }
            return
        }

        if !session.clipboardCaptured {
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != session.clipboardBaselineChangeCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty, text.count <= 100_000 {
                session.clipboardCaptured = true
                let observation = IMEObservation(
                    version: 1,
                    capturedAt: Date(),
                    source: "clipboard_change_after_external_voice",
                    text: text,
                    attributionStatus: "unattributed_observation",
                    pasteboardChangeCount: pasteboard.changeCount,
                    replacedCharacterCount: nil
                )
                ioQueue.async { [weak self] in
                    self?.persistIME(observation, filename: "ime.clipboard.json", for: session)
                }
            }
        }

        // AX is sampled only a handful of times, and the cross-process work stays off the main
        // queue. This matters when attempts are close together: a hung/custom editor must not delay
        // the next physical F10 press while an older sample is still waiting for text.
        if !session.accessibilityCaptured,
           !session.axProbeInFlight,
           [2, 5, 10, 20, 35, 50].contains(attempt),
           let target = session.textTarget,
           let before = target.valueBeforeInsertion,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
            session.axProbeInFlight = true
            let seed = VoiceTextTargetSeed(
                pid: target.pid,
                bundleIdentifier: target.bundleIdentifier,
                applicationName: target.applicationName
            )
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let current = VoiceTextDeliverer.resolveTarget(seed)
                DispatchQueue.main.async {
                    guard let self else { return }
                    session.axProbeInFlight = false
                    self.consumeAXObservation(
                        current,
                        original: target,
                        before: before,
                        session: session,
                        generation: generation
                    )
                }
            }
        }

        // The pasteboard is global. Preserve it as Raw evidence, but never let it alone establish
        // an audio/text pair. Only a target-verified AX delta makes text_status observationally true.
        if session.clipboardCaptured && session.accessibilityCaptured {
            finalizeObservation(session, textStatus: "observed")
            if pendingObservation === session { pendingObservation = nil }
            return
        }

        guard attempt < textObservationAttempts else {
            if session.axProbeInFlight {
                DispatchQueue.main.asyncAfter(deadline: .now() + textObservationInterval) { [weak self] in
                    self?.watchTextObservations(
                        for: session, generation: generation, attempt: attempt + 1
                    )
                }
                return
            }
            let observed = session.accessibilityCaptured
            finalizeObservation(session, textStatus: observed ? "observed" : "not_observed")
            if pendingObservation === session { pendingObservation = nil }
            if !observed {
                rmDebug("🗂 corpus: text not observed id=\(session.id.uuidString)"
                        + " (speech/network/IME outcome intentionally not inferred)")
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + textObservationInterval) { [weak self] in
            self?.watchTextObservations(for: session, generation: generation, attempt: attempt + 1)
        }
    }

    private func consumeAXObservation(
        _ current: VoiceTextTarget,
        original target: VoiceTextTarget,
        before: String,
        session: Session,
        generation: Int
    ) {
        guard generation == clipboardWatchGeneration,
              pendingObservation === session,
              !session.accessibilityCaptured else { return }

        if current.isSecure {
            session.secureInputSeenDuringObservation = true
            finalizeObservation(session, textStatus: "interrupted_by_secure_input")
            pendingObservation = nil
            return
        }

        let sameElement: Bool = {
            guard let original = target.focusedElement,
                  let now = current.focusedElement else { return false }
            return CFEqual(original, now)
        }()
        let compatibleReplacement: Bool = {
            guard let original = target.focusSignature,
                  let now = current.focusSignature else { return false }
            return now.isCompatibleReplacement(for: original)
        }()
        guard sameElement || compatibleReplacement else {
            session.focusTargetChangedDuringObservation = true
            finalizeObservation(session, textStatus: "interrupted_by_focus_change")
            pendingObservation = nil
            return
        }

        guard let after = current.valueBeforeInsertion,
              let delta = Self.changedText(before: before, after: after) else { return }
        session.accessibilityCaptured = true
        let observation = IMEObservation(
            version: 1,
            capturedAt: Date(),
            source: "accessibility_value_diff_after_external_voice",
            text: delta.inserted,
            attributionStatus: "target_verified",
            pasteboardChangeCount: nil,
            replacedCharacterCount: delta.removedCount
        )
        ioQueue.async { [weak self] in
            self?.persistIME(observation, filename: "ime.accessibility.json", for: session)
        }

        if session.clipboardCaptured {
            finalizeObservation(session, textStatus: "observed")
            pendingObservation = nil
        }
    }

    private static func changedText(before: String, after: String)
        -> (inserted: String, removedCount: Int)? {
        guard before != after else { return nil }
        let old = Array(before)
        let new = Array(after)
        var prefix = 0
        while prefix < old.count && prefix < new.count && old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix
              && suffix < new.count - prefix
              && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let newEnd = new.count - suffix
        guard prefix <= newEnd else { return nil }
        let inserted = String(new[prefix..<newEnd])
        guard !inserted.isEmpty else { return nil }
        return (inserted, old.count - prefix - suffix)
    }

    private func finalizeObservation(_ session: Session, textStatus: String) {
        let observation = makeAttemptObservation(session, textStatus: textStatus)
        ioQueue.async { [weak self] in
            self?.persistObservation(observation, for: session)
        }
    }

    private func makeAttemptObservation(_ session: Session, textStatus: String) -> AttemptObservation {
        AttemptObservation(
            version: 1,
            id: session.id,
            finalizedAt: Date(),
            textStatus: textStatus,
            clipboardObserved: session.clipboardCaptured,
            accessibilityObserved: session.accessibilityCaptured,
            frontmostAppChanged: session.frontmostAppChangedDuringObservation,
            focusTargetChanged: session.focusTargetChangedDuringObservation,
            secureInputSeen: session.secureInputSeenDuringObservation,
            observationWindowLimitSeconds: Double(textObservationAttempts) * textObservationInterval,
            speechStatus: "not_analyzed",
            imeOutcome: "not_inferred",
            networkStatus: "not_measured"
        )
    }

    private func persistObservation(_ observation: AttemptObservation, for session: Session) {
        do {
            let url = session.directoryURL.appendingPathComponent("observation.json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(observation).write(to: url, options: .atomic)
            try secureFile(url)
            rmDebug("🗂 corpus: observation finalized id=\(session.id.uuidString)"
                    + " text=\(observation.textStatus)")
        } catch {
            reportStorageFailure(
                "Voice Corpus cannot save observation metadata: \(error.localizedDescription)"
            )
            rmDebug("🗂 corpus: observation save failed id=\(session.id.uuidString): "
                    + error.localizedDescription)
        }
    }

    /// Best-effort process-shutdown flush. Device teardown normally closes a held shortcut first,
    /// but the ordinary corpus writer is asynchronous; waiting for this queue and synchronously
    /// draining the capture prevents a quit/relaunch immediately after release from losing the raw
    /// sample. A forced kill/power loss is outside the process's ability to guarantee.
    func flushForTermination() {
        clipboardWatchGeneration &+= 1

        if let session = active {
            active = nil
            let endedAt = Date()
            session.endedAt = endedAt
            let audio = session.capture.stopBlockingForTermination()
            ioQueue.sync {
                let storage = session.audioSpool.finalize(
                    sampleRate: audio.sampleRate,
                    expectedFrameCount: audio.frameCount
                )
                persistCapture(session: session, endedAt: endedAt, audio: audio, storage: storage)
                persistObservation(
                    makeAttemptObservation(session, textStatus: "interrupted_by_app_termination"),
                    for: session
                )
            }
        } else if let session = pendingObservation {
            pendingObservation = nil
            let endedAt = session.endedAt ?? Date()
            let audio = session.capture.stopBlockingForTermination()
            ioQueue.sync {
                let storage = session.audioSpool.finalize(
                    sampleRate: audio.sampleRate,
                    expectedFrameCount: audio.frameCount
                )
                // This may repeat already-completed metadata; spool finalization is idempotent and
                // the JSON replacement is atomic.
                persistCapture(session: session, endedAt: endedAt, audio: audio, storage: storage)
                let status = session.accessibilityCaptured
                    ? "observed" : "interrupted_by_app_termination"
                persistObservation(makeAttemptObservation(session, textStatus: status), for: session)
            }
        } else {
            // Wait behind any already-enqueued corpus writes before the process exits.
            ioQueue.sync {}
        }
    }

    private func persistIME(_ observation: IMEObservation, filename: String, for session: Session) {
        do {
            let url = session.directoryURL.appendingPathComponent(filename)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(observation).write(to: url, options: .atomic)
            try secureFile(url)
            rmDebug("🗂 corpus: attached \(observation.source) id=\(session.id.uuidString) "
                    + "chars=\(observation.text.count)")
        } catch {
            reportStorageFailure(
                "Voice Corpus cannot save text observation: \(error.localizedDescription)"
            )
            rmDebug("🗂 corpus: IME save failed id=\(session.id.uuidString): "
                    + error.localizedDescription)
        }
    }

    private func reportStorageFailure(_ message: String) {
        rmDebug("🗂 corpus storage failure: \(message)")
        let callback = onStorageStatus
        DispatchQueue.main.async { callback(message) }
    }

    private func secureFile(_ url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let sampleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "HHmmss-SSS"
        return f
    }()
}
