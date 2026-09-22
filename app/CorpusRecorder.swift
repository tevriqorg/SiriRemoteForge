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
import Foundation

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
        let clipboardBaselineChangeCount: Int
        let capture: VoiceAudioCaptureSession
        var textTarget: VoiceTextTarget?
        var clipboardCaptured = false
        var accessibilityCaptured = false

        init(id: UUID, startedAt: Date, directoryURL: URL,
             actionKey: String, actionKind: String, shortcutKeys: String,
             applicationName: String?, bundleIdentifier: String?,
             clipboardBaselineChangeCount: Int, capture: VoiceAudioCaptureSession) {
            self.id = id
            self.startedAt = startedAt
            self.directoryURL = directoryURL
            self.actionKey = actionKey
            self.actionKind = actionKind
            self.shortcutKeys = shortcutKeys
            self.applicationName = applicationName
            self.bundleIdentifier = bundleIdentifier
            self.clipboardBaselineChangeCount = clipboardBaselineChangeCount
            self.capture = capture
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
            case sampleRate = "sample_rate"
            case frameCount = "frame_count"
            case durationSeconds = "duration_seconds"
            case meanSquare = "mean_square"
        }
    }

    private struct IMEObservation: Codable {
        let version: Int
        let capturedAt: Date
        let source: String
        let text: String
        let pasteboardChangeCount: Int?
        let replacedCharacterCount: Int?

        private enum CodingKeys: String, CodingKey {
            case version, source, text
            case capturedAt = "captured_at"
            case pasteboardChangeCount = "pasteboard_change_count"
            case replacedCharacterCount = "replaced_character_count"
        }
    }

    private let fileManager: FileManager
    let rootURL: URL
    private let ioQueue = DispatchQueue(label: "com.hypervibe.voice-corpus", qos: .utility)
    private var active: Session?
    private var clipboardWatchGeneration = 0

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.rootURL = rootURL ?? base
            .appendingPathComponent("HyperVibe", isDirectory: true)
            .appendingPathComponent("Corpus", isDirectory: true)
    }

    var isRecording: Bool { active != nil }

    /// Begin one external voice sample. Call only after the side-button hold has genuinely
    /// promoted to a continuous action; the existing 0.2 s accidental-touch guard therefore
    /// remains authoritative and quick taps never create empty corpus entries.
    func begin(_ handled: Controller.HandledAction) {
        guard active == nil else {
            rmDebug("🗂 corpus: ignored overlapping begin for \(handled.key)")
            return
        }
        guard let action = Self.externalVoiceAction(handled.action) else { return }

        let id = UUID()
        let startedAt = Date()
        let directoryURL = sampleDirectory(id: id, date: startedAt)
        do {
            try prepareDirectory(directoryURL)
        } catch {
            rmDebug("🗂 corpus: cannot create sample directory: \(error.localizedDescription)")
            return
        }

        let app = NSWorkspace.shared.frontmostApplication
        let pasteboard = NSPasteboard.general
        clipboardWatchGeneration &+= 1   // a new utterance owns future clipboard attribution

        // Corpus recording intentionally has no speech-length gate. Even a short but genuine
        // external hold is useful training/evaluation evidence. Five minutes is only a safety cap.
        let capture = VoiceAudioCaptureSession(
            minimumDuration: 0,
            maxDuration: 300,
            onMinimumDurationReached: {},
            onMaximumDuration: { rmDebug("🗂 corpus: five-minute safety cap reached") }
        )
        let session = Session(
            id: id,
            startedAt: startedAt,
            directoryURL: directoryURL,
            actionKey: handled.key,
            actionKind: action.kind,
            shortcutKeys: action.keys,
            applicationName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            clipboardBaselineChangeCount: pasteboard.changeCount,
            capture: capture
        )
        active = session
        capture.start()

        // Audio is already running before this bounded AX query. Keep only the in-memory BEFORE
        // state needed to derive this utterance's inserted/replaced text; never persist the field's
        // pre-existing contents. Secure targets are discarded immediately.
        if let app {
            let seed = VoiceTextTargetSeed(
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                applicationName: app.localizedName ?? L("Current App")
            )
            let target = VoiceTextDeliverer.resolveTarget(seed)
            if !target.isSecure { session.textTarget = target }
        }
        rmDebug("🗂 corpus: began id=\(id.uuidString) key=\(handled.key)")
    }

    /// End the matching external voice sample. Audio persistence happens off the main thread.
    /// Clipboard observation remains deliberately best-effort: it records only a change made after
    /// this utterance began, never the pre-existing clipboard contents.
    func end(actionKey: String) {
        guard let session = active, session.actionKey == actionKey else { return }
        active = nil
        let endedAt = Date()
        let watchGeneration = clipboardWatchGeneration
        watchClipboard(for: session, generation: watchGeneration, attempt: 0)

        Task { [weak self] in
            let audio = await session.capture.stop()
            guard let self else { return }
            self.ioQueue.async {
                self.persistCapture(session: session, endedAt: endedAt, audio: audio)
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
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
        var root = rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private func persistCapture(session: Session, endedAt: Date, audio: VoiceCapturedAudio) {
        do {
            let wavURL = session.directoryURL.appendingPathComponent("audio.wav")
            let recordURL = session.directoryURL.appendingPathComponent("capture.json")
            try Self.wavData(audio).write(to: wavURL, options: .atomic)
            try secureFile(wavURL)

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
                    + "source=\(audio.source.rawValue) duration=\(String(format: "%.2f", audio.duration))s")
        } catch {
            rmDebug("🗂 corpus: save failed id=\(session.id.uuidString): "
                    + error.localizedDescription)
        }
    }

    /// Poll briefly after release because external IMEs often publish their completed string a few
    /// hundred milliseconds later. Clipboard and Accessibility are independent observations: when
    /// both are available we keep both, allowing later offline alignment to decide which is useful.
    /// A new utterance invalidates the previous watch so text from sample N+1 cannot attach to N.
    private func watchClipboard(for session: Session, generation: Int, attempt: Int) {
        guard generation == clipboardWatchGeneration else { return }

        if !session.clipboardCaptured {
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != session.clipboardBaselineChangeCount,
               let text = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                session.clipboardCaptured = true
                let observation = IMEObservation(
                    version: 1,
                    capturedAt: Date(),
                    source: "clipboard_change_after_external_voice",
                    text: text,
                    pasteboardChangeCount: pasteboard.changeCount,
                    replacedCharacterCount: nil
                )
                ioQueue.async { [weak self] in
                    self?.persistIME(observation, filename: "ime.clipboard.json", for: session)
                }
            }
        }

        // AX is intentionally sampled only a handful of times so a slow custom editor cannot turn
        // the 100 ms clipboard poll into repeated cross-process IPC. We only persist the minimal
        // changed span, never the before/after field values.
        if !session.accessibilityCaptured,
           [2, 5, 10, 20].contains(attempt),
           let target = session.textTarget,
           let before = target.valueBeforeInsertion,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
           let element = target.focusedElement {
            AXUIElementSetMessagingTimeout(element, 0.025)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &value
            ) == .success, let after = value as? String,
               let delta = Self.changedText(before: before, after: after) {
                session.accessibilityCaptured = true
                let observation = IMEObservation(
                    version: 1,
                    capturedAt: Date(),
                    source: "accessibility_value_diff_after_external_voice",
                    text: delta.inserted,
                    pasteboardChangeCount: nil,
                    replacedCharacterCount: delta.removedCount
                )
                ioQueue.async { [weak self] in
                    self?.persistIME(observation, filename: "ime.accessibility.json", for: session)
                }
            }
        }

        let axUnavailable = session.textTarget?.valueBeforeInsertion == nil
        if session.clipboardCaptured && (session.accessibilityCaptured || axUnavailable) { return }
        guard attempt < 20 else {
            if !session.clipboardCaptured && !session.accessibilityCaptured {
                rmDebug("🗂 corpus: no IME text observed id=\(session.id.uuidString)")
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.watchClipboard(for: session, generation: generation, attempt: attempt + 1)
        }
    }

    private static func changedText(before: String, after: String)
        -> (inserted: String, removedCount: Int)? {
        guard before != after else { return nil }
        let old = Array(before)
        let new = Array(after)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix,
              suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let newEnd = new.count - suffix
        guard prefix <= newEnd else { return nil }
        let inserted = String(new[prefix..<newEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inserted.isEmpty else { return nil }
        return (inserted, old.count - prefix - suffix)
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
            rmDebug("🗂 corpus: IME save failed id=\(session.id.uuidString): "
                    + error.localizedDescription)
        }
    }

    private func secureFile(_ url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private static func wavData(_ audio: VoiceCapturedAudio) -> Data {
        var data = Data()
        appendASCII("RIFF", to: &data)
        appendLE(UInt32(36 + audio.pcm16.count), to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendLE(UInt32(16), to: &data)             // PCM fmt chunk size
        appendLE(UInt16(1), to: &data)              // PCM
        appendLE(UInt16(1), to: &data)              // mono
        appendLE(UInt32(audio.sampleRate), to: &data)
        appendLE(UInt32(audio.sampleRate * 2), to: &data) // 16-bit mono bytes/sec
        appendLE(UInt16(2), to: &data)              // block align
        appendLE(UInt16(16), to: &data)             // bits/sample
        appendASCII("data", to: &data)
        appendLE(UInt32(audio.pcm16.count), to: &data)
        data.append(audio.pcm16)
        return data
    }

    private static func appendASCII(_ string: String, to data: inout Data) {
        data.append(string.data(using: .ascii)!)
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
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
