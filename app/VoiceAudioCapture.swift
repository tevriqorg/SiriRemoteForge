import SiriRemoteCore
//
//  VoiceAudioCapture.swift
//  HyperVibe
//
//  A non-real-time reader over HyperVibe's two existing 48 kHz audio rings. It probes briefly for
//  live Siri Remote audio, otherwise locks the utterance to the pinned built-in microphone. Locking
//  one source per utterance avoids a mid-sentence timbre jump and makes streamed PCM deterministic.
//

import Foundation

struct VoiceCapturedAudio {
    enum Source: String {
        case remote
        case builtIn
    }

    /// Why the attempt ended with the audio it holds. `remote_start_timeout` and `no_frames` are
    /// deliberately distinct outcomes: the old code could only report "builtIn / 0 frames" on a
    /// machine that has no built-in microphone, which read like a successful capture. A remote
    /// producer that never started in time is now an explicit failure, not a vague 0-frame success.
    enum Outcome: String {
        case remoteCaptured = "remote_captured"
        case builtInCaptured = "builtin_captured"
        case remoteStartTimeout = "remote_start_timeout"
        case noFrames = "no_frames"
    }

    let pcm16: Data
    let sampleRate: Int
    let source: Source
    let frameCount: Int
    let meanSquare: Double
    let outcome: Outcome
    /// Milliseconds from press to the first remote frame observed in this attempt, or nil when the
    /// remote producer never produced during it. Diagnostic only.
    let remoteFirstFrameLatencyMilliseconds: Double?

    var duration: TimeInterval {
        sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0
    }

    init(pcm16: Data,
         sampleRate: Int,
         source: Source,
         frameCount: Int,
         meanSquare: Double,
         outcome: Outcome? = nil,
         remoteFirstFrameLatencyMilliseconds: Double? = nil) {
        self.pcm16 = pcm16
        self.sampleRate = sampleRate
        self.source = source
        self.frameCount = frameCount
        self.meanSquare = meanSquare
        self.outcome = outcome ?? (frameCount > 0
            ? (source == .remote ? .remoteCaptured : .builtInCaptured)
            : .noFrames)
        self.remoteFirstFrameLatencyMilliseconds = remoteFirstFrameLatencyMilliseconds
    }
}

/// Pure decision policy for which audio source an attempt runs on, shared with the native
/// regression suite. The three facts that drive it are deliberately separated:
///
/// - `remoteReady`     — the remote producer is live and delivering real frames;
/// - `remotePending`   — the remote producer has not produced yet (cold start in progress);
/// - `builtInAvailable`— this Mac actually exposes a usable built-in microphone.
///
/// A Mac mini has `builtInAvailable == false`. A pending remote must then never lock the attempt
/// to the built-in ring: that ring stays empty forever, and the old "builtIn / 0 frames" record
/// looked like a successful capture. Instead capture stays remote-pending, locks to `remote` on its
/// first frame, and only gives up at an explicit 3 s `remote_start_timeout`.
enum VoiceRemoteProbePolicy {
    static let maximumWaitNanoseconds: UInt64 = 650_000_000
    /// Hard ceiling for a remote producer that never starts. Past this the attempt is reported as
    /// `remote_start_timeout` rather than an ambiguous empty capture.
    static let remoteStartupTimeoutNanoseconds: UInt64 = 3_000_000_000
    static let preRollFrames: UInt64 = 14_400 // 300 ms at 48 kHz
    /// 20 ms of fresh remote audio at 48 kHz is enough to prefer the remote over a probe.
    static let remoteUsableAdvanceFrames: UInt64 = 960

    static func firstCursor(baseline: UInt64, producerWasActive: Bool) -> UInt64 {
        guard producerWasActive, baseline > preRollFrames else { return baseline }
        return baseline - preRollFrames
    }

    /// A real built-in probe is only a valid fallback when the machine has a built-in microphone
    /// AND that probe actually produced samples. `builtInAvailable == false` can never fall back.
    static func shouldPreferBuiltInForColdRemote(
        remoteWasActiveAtStart: Bool,
        builtInAvailable: Bool,
        builtInFrameCount: Int
    ) -> Bool {
        builtInAvailable && !remoteWasActiveAtStart && builtInFrameCount > 0
    }

    /// Result of one probe evaluation.
    enum ProbeResolution: Equatable {
        case remote
        case builtIn
        /// No source decided yet: keep polling the remote ring. Never a built-in lock.
        case keepRemotePending
        /// The remote producer did not start within the timeout and no fallback exists.
        case remoteStartTimeout
    }

    /// Single source of truth for the probe/first-frame/timeout state machine.
    static func resolveProbe(
        builtInAvailable: Bool,
        builtInFrameCount: Int,
        remoteWasActiveAtStart: Bool,
        remoteWasLive: Bool,
        remoteAdvancedFrames: UInt64,
        elapsedNanoseconds: UInt64,
        preserveBeginningWhenRemoteCold: Bool
    ) -> ProbeResolution {
        // A live remote delivering real audio always wins, unless a *usable* built-in probe already
        // captured the utterance beginning and this caller wants it preserved.
        if remoteWasLive && remoteAdvancedFrames >= remoteUsableAdvanceFrames {
            if preserveBeginningWhenRemoteCold,
               shouldPreferBuiltInForColdRemote(
                   remoteWasActiveAtStart: remoteWasActiveAtStart,
                   builtInAvailable: builtInAvailable,
                   builtInFrameCount: builtInFrameCount
               ) {
                return .builtIn
            }
            return .remote
        }

        guard elapsedNanoseconds >= maximumWaitNanoseconds else { return .keepRemotePending }

        // Probe window exhausted and the remote has not delivered usable audio yet.
        if preserveBeginningWhenRemoteCold, builtInAvailable, builtInFrameCount > 0 {
            return .builtIn
        }
        if !preserveBeginningWhenRemoteCold, builtInAvailable {
            // Native Voice historically commits to the built-in mic after the probe; keep that, but
            // only when a built-in microphone actually exists.
            return .builtIn
        }
        // No usable fallback: hold remote-pending until the startup timeout makes failure explicit.
        return elapsedNanoseconds >= remoteStartupTimeoutNanoseconds
            ? .remoteStartTimeout
            : .keepRemotePending
    }

    /// The historical remote writer reset its monotonic frame counter to zero every time the
    /// privileged router restarted. A reader that captured the previous non-zero baseline would
    /// then wait forever for current > oldBaseline, even while fresh audio was already arriving.
    /// A backwards counter is unambiguous restart evidence, so rebase this capture to the new
    /// producer epoch. Newer writers preserve monotonicity and never take this compatibility path.
    static func rebasedBaselineAfterProducerRestart(baseline: UInt64, current: UInt64) -> UInt64 {
        current < baseline ? 0 : baseline
    }
}

/// All mutable state is confined to `queue`; public methods only enqueue work or consume the
/// single-producer AsyncStream.
final class VoiceAudioCaptureSession: @unchecked Sendable {
    static let outputSampleRate = 24_000

    let chunks: AsyncStream<Data>

    private let queue = DispatchQueue(label: "com.hypervibe.voice-audio-capture",
                                      qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private let continuation: AsyncStream<Data>.Continuation
    private let minimumDuration: TimeInterval
    private let maxDuration: TimeInterval
    private let onMinimumDurationReached: () -> Void
    private let onMaximumDuration: () -> Void
    private let onFirstAudioChunk: () -> Void
    private let retainPCM: Bool
    private let streamChunks: Bool
    private let onPCMChunk: (Data) -> Void
    private let preserveBeginningWhenRemoteCold: Bool
    /// Whether a built-in microphone actually exists on this Mac. When false, the state machine can
    /// never lock an attempt to the built-in ring; a pending remote stays pending until it starts or
    /// hits the explicit startup timeout.
    private let builtInAvailable: Bool

    private var timer: DispatchSourceTimer?
    private var startedAtNanoseconds: UInt64 = 0
    private var stopped = false
    /// Set once when the attempt resolves to a terminal failure with no usable audio.
    private var pendingOutcome: VoiceCapturedAudio.Outcome?
    /// Milliseconds from start to the first remote frame observed in this attempt.
    private var remoteFirstFrameLatencyMilliseconds: Double?
    /// Producer state captured at press time, for the press-time diagnostic line.
    private var remoteProducerActiveAtStart = false
    private var builtinProducerActiveAtStart = false
    private var loggedRemotePending = false
    private var source: VoiceCapturedAudio.Source?

    private var builtinCursor: UInt64 = 0
    private var remoteCursor: UInt64 = 0
    private var remoteBaseline: UInt64 = 0
    private var remoteWasActiveAtStart = false
    private var remoteWasLive = false
    private var remoteAdvancedFrames: UInt64 = 0

    private var builtinProbe: [Float] = []
    private var remoteProbe: [Float] = []
    private var builtinBuffer = [Float](repeating: 0, count: 4096)
    private var remoteBuffer = [Float](repeating: 0, count: 4096)
    private var downsampler = Downsampler48To24()

    private var capturedPCM = Data()
    private var capturedFrames = 0
    /// Read-only peek for diagnostics: how much audio the ring has actually delivered so far.
    /// Lets failure paths log the real captured amount without stopping the capture first.
    var frameCountSoFar: Int { capturedFrames }
    private var sumSquares: Double = 0
    private var announcedFirstChunk = false
    private var announcedMinimumDuration = false
    /// The begin cue is played by the Mac while capture is already hot. A tiny lock-protected
    /// monotonic deadline lets the audio queue consume—but not publish—those acoustic frames, so
    /// neither Realtime nor the Final WAV can transcribe HyperVibe's own acknowledgement.
    private let exclusionLock = NSLock()
    private var excludeUntilNanoseconds: UInt64 = 0

    /// Native dictation raises remote-pipeline demand on the raw press edge. A healthy remote wins
    /// as soon as it delivers 20 ms of fresh audio; until then the attempt stays remote-pending.
    ///
    /// `builtInAvailable` defaults to the live machine probe. Tests may override it explicitly.
    /// When this Mac has no built-in microphone, a pending remote is never locked to the built-in
    /// ring; it stays pending until the first remote frame or the explicit startup timeout.
    init(minimumDuration: TimeInterval,
         maxDuration: TimeInterval,
         onMinimumDurationReached: @escaping () -> Void,
         onMaximumDuration: @escaping () -> Void,
         onFirstAudioChunk: @escaping () -> Void = {},
         retainPCM: Bool = true,
         streamChunks: Bool = true,
         preserveBeginningWhenRemoteCold: Bool = false,
         builtInAvailable: Bool = BuiltinMicFeeder.builtInMicAvailable,
         onPCMChunk: @escaping (Data) -> Void = { _ in }) {
        self.minimumDuration = max(0, minimumDuration)
        self.maxDuration = max(1, maxDuration)
        self.onMinimumDurationReached = onMinimumDurationReached
        self.onMaximumDuration = onMaximumDuration
        self.onFirstAudioChunk = onFirstAudioChunk
        self.retainPCM = retainPCM
        self.streamChunks = streamChunks
        self.preserveBeginningWhenRemoteCold = preserveBeginningWhenRemoteCold
        self.builtInAvailable = builtInAvailable
        self.onPCMChunk = onPCMChunk
        var localContinuation: AsyncStream<Data>.Continuation!
        // Native Voice consumes the stream and retains final PCM. Corpus explicitly disables both
        // paths and uses onPCMChunk to journal audio to disk, so a long thinking hold cannot grow
        // memory linearly with its duration.
        let bufferingPolicy: AsyncStream<Data>.Continuation.BufferingPolicy =
            streamChunks ? .unbounded : .bufferingNewest(1)
        chunks = AsyncStream<Data>(bufferingPolicy: bufferingPolicy) {
            localContinuation = $0
        }
        continuation = localContinuation
        builtinProbe.reserveCapacity(6_000)
        remoteProbe.reserveCapacity(15_000)
        if retainPCM { capturedPCM.reserveCapacity(65_536) }
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() async -> VoiceCapturedAudio {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: VoiceCapturedAudio(
                        pcm16: Data(), sampleRate: Self.outputSampleRate,
                        source: .builtIn, frameCount: 0, meanSquare: 0
                    ))
                    return
                }
                continuation.resume(returning: self.stopOnQueue())
            }
        }
    }

    /// Termination-only drain. Normal callers must use async `stop()`; AppDelegate invokes this
    /// from the main thread while the process is shutting down so queued PCM is not abandoned before
    /// the asynchronous corpus writer gets a chance to run.
    func stopBlockingForTermination() -> VoiceCapturedAudio {
        syncOnQueue { stopOnQueue() }
    }

    /// Synchronous access is termination/support-only. Execute inline when already on the capture
    /// queue so a future queue-owned caller cannot deadlock by synchronising onto itself.
    private func syncOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return work() }
        return queue.sync(execute: work)
    }

    func excludeAcousticFeedback(for duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = UInt64(min(1, duration) * 1_000_000_000)
        exclusionLock.lock()
        excludeUntilNanoseconds = max(excludeUntilNanoseconds, now &+ delta)
        exclusionLock.unlock()
    }

    private func startOnQueue() {
        guard timer == nil, !stopped else { return }
        startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        announceMinimumDurationIfNeeded()

        var active: UInt32 = 0
        if srm_builtin_audio_state(&builtinCursor, &active) != 0 { builtinCursor = 0 }
        builtinProducerActiveAtStart = active != 0
        if srm_remote_audio_state(&remoteBaseline, &active) == 0 {
            remoteWasActiveAtStart = active != 0
            remoteProducerActiveAtStart = active != 0
            remoteCursor = remoteBaseline
        } else {
            remoteBaseline = 0
            remoteCursor = 0
            remoteProducerActiveAtStart = false
        }

        // Press-time ground truth. This is the line that tells a future reader whether the attempt
        // began with a warm remote producer or had to wait for one; it is emitted once per attempt.
        rmDebug("🎙 capture start builtInAvailable=\(builtInAvailable) "
                + "remoteProducerActive=\(remoteProducerActiveAtStart) "
                + "builtInProducerActive=\(builtinProducerActiveAtStart) "
                + "preserveBegin=\(preserveBeginningWhenRemoteCold)")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    private func poll() {
        guard !stopped else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= startedAtNanoseconds,
           Double(now - startedAtNanoseconds) / 1_000_000_000 >= maxDuration {
            _ = stopOnQueue()
            DispatchQueue.main.async { [onMaximumDuration] in onMaximumDuration() }
            return
        }

        // Once a source is chosen, stop touching the other ring entirely. This halves ring reads
        // and removes two transient Array allocations from every steady-state tick.
        if source == .builtIn {
            let count = readBuiltin()
            append48k(builtinBuffer, count: count)
            return
        }
        if source == .remote {
            let count = readRemoteIfLive()
            append48k(remoteBuffer, count: count)
            return
        }

        let builtinCount = readBuiltin()
        let remoteCount = readRemoteIfLive()

        if builtinCount > 0 {
            builtinProbe.append(contentsOf: builtinBuffer.prefix(builtinCount))
        }
        if remoteCount > 0 {
            remoteProbe.append(contentsOf: remoteBuffer.prefix(remoteCount))
        }
        // The first remote frame of this attempt is the latency figure operators actually need.
        if remoteFirstFrameLatencyMilliseconds == nil, remoteCount > 0 {
            remoteFirstFrameLatencyMilliseconds =
                Double(now - startedAtNanoseconds) / 1_000_000
            rmDebug(String(format: "🎙 remote first frame latency=%.1fms",
                           remoteFirstFrameLatencyMilliseconds ?? 0))
        }

        let elapsed = now - startedAtNanoseconds
        let resolution = VoiceRemoteProbePolicy.resolveProbe(
            builtInAvailable: builtInAvailable,
            builtInFrameCount: builtinProbe.count,
            remoteWasActiveAtStart: remoteWasActiveAtStart,
            remoteWasLive: remoteWasLive,
            remoteAdvancedFrames: remoteAdvancedFrames,
            elapsedNanoseconds: elapsed,
            preserveBeginningWhenRemoteCold: preserveBeginningWhenRemoteCold
        )
        switch resolution {
        case .remote:
            select(.remote)
        case .builtIn:
            select(.builtIn)
        case .keepRemotePending:
            // Log the wait once so a slow producer is visible, not silent.
            if !loggedRemotePending, elapsed >= VoiceRemoteProbePolicy.maximumWaitNanoseconds {
                loggedRemotePending = true
                rmDebug("🎙 remote pending — no built-in fallback available; waiting for producer "
                        + "(timeout=\(VoiceRemoteProbePolicy.remoteStartupTimeoutNanoseconds / 1_000_000)ms)")
            }
        case .remoteStartTimeout:
            // Producer never started in time. Record the failure explicitly but keep polling: a
            // very slow producer that arrives after the timeout should still be captured rather
            // than discarded, matching the corpus raw-attempt contract.
            if pendingOutcome == nil {
                pendingOutcome = .remoteStartTimeout
                rmDebug("🎙 remote_start_timeout after "
                        + "\(VoiceRemoteProbePolicy.remoteStartupTimeoutNanoseconds / 1_000_000)ms "
                        + "builtInAvailable=\(builtInAvailable) — no audio yet; still polling")
            }
        }
        return
    }

    private func readBuiltin() -> Int {
        var active: UInt32 = 0
        let count = builtinBuffer.withUnsafeMutableBufferPointer { buffer in
            srm_builtin_audio_read(&builtinCursor, buffer.baseAddress,
                                   buffer.count, &active)
        }
        guard active != 0, count > 0 else { return 0 }
        return Int(count)
    }

    private func readRemoteIfLive() -> Int {
        var current: UInt64 = 0
        var active: UInt32 = 0
        guard srm_remote_audio_state(&current, &active) == 0, active != 0 else { return 0 }

        if !remoteWasLive {
            let rebased = VoiceRemoteProbePolicy.rebasedBaselineAfterProducerRestart(
                baseline: remoteBaseline, current: current
            )
            if rebased != remoteBaseline {
                rmDebug("🎙 remote ring counter restarted \(remoteBaseline)→\(current); rebasing capture")
                remoteBaseline = rebased
                remoteCursor = rebased
            }
            guard current > remoteBaseline else { return 0 }
            remoteWasLive = true
            remoteAdvancedFrames = current - remoteBaseline
            // A newly launched router has no valid current-session audio before the baseline;
            // reading backwards there would leak the previous dictation's final 300 ms.
            remoteCursor = VoiceRemoteProbePolicy.firstCursor(
                baseline: remoteBaseline, producerWasActive: remoteWasActiveAtStart
            )
        } else if current > remoteCursor {
            remoteAdvancedFrames = max(remoteAdvancedFrames, current - remoteBaseline)
        }

        let count = remoteBuffer.withUnsafeMutableBufferPointer { buffer in
            srm_remote_audio_read(&remoteCursor, buffer.baseAddress,
                                  buffer.count, &active)
        }
        guard count > 0 else { return 0 }
        return Int(count)
    }

    private func select(_ selected: VoiceCapturedAudio.Source) {
        guard source == nil else { return }
        source = selected
        switch selected {
        case .remote:
            append48k(remoteProbe)
        case .builtIn:
            append48k(builtinProbe)
        }
        builtinProbe.removeAll(keepingCapacity: false)
        remoteProbe.removeAll(keepingCapacity: false)
    }

    private func append48k(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append48k($0) }
    }

    private func append48k(_ buffer: [Float], count: Int) {
        guard count > 0 else { return }
        buffer.withUnsafeBufferPointer { pointer in
            append48k(UnsafeBufferPointer(rebasing: pointer.prefix(count)))
        }
    }

    private func append48k(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let chunk = downsampler.convert(samples)
        guard !chunk.isEmpty else { return }
        exclusionLock.lock()
        let excluded = DispatchTime.now().uptimeNanoseconds < excludeUntilNanoseconds
        exclusionLock.unlock()
        // Conversion still advances the decimator across excluded frames, avoiding a stale odd
        // sample at the first real speech packet after the cue.
        guard !excluded else { return }
        if retainPCM { capturedPCM.append(chunk) }
        onPCMChunk(chunk)
        capturedFrames += chunk.count / MemoryLayout<Int16>.size
        if !announcedFirstChunk {
            announcedFirstChunk = true
            onFirstAudioChunk()
        }
        announceMinimumDurationIfNeeded()

        chunk.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for littleEndian in values {
                let value = Double(Int16(littleEndian: littleEndian)) / 32768.0
                sumSquares += value * value
            }
        }
        if streamChunks { continuation.yield(chunk) }
    }

    private func announceMinimumDurationIfNeeded() {
        guard !announcedMinimumDuration,
              Double(capturedFrames) / Double(Self.outputSampleRate) >= minimumDuration else {
            return
        }
        announcedMinimumDuration = true
        DispatchQueue.main.async { [onMinimumDurationReached] in
            onMinimumDurationReached()
        }
    }

    /// Terminal resolution. The release edge may arrive before any source was chosen — for example
    /// a very short press on a cold remote. This never locks a no-built-in-mic Mac to the built-in
    /// ring; such an attempt ends as `remote_start_timeout` (producer never started) or `no_frames`.
    @discardableResult
    private func stopOnQueue() -> VoiceCapturedAudio {
        if !stopped {
            stopped = true
            timer?.cancel()
            timer = nil
            if source == nil {
                let remoteHasUsableAudio = remoteWasLive && remoteAdvancedFrames >= 480
                // Parity with the original stop path: a built-in *probe* only overrides a
                // usable remote when the caller explicitly wants the utterance beginning preserved
                // and the machine really has a built-in microphone that supplied samples.
                let preferBuiltIn = preserveBeginningWhenRemoteCold
                    && VoiceRemoteProbePolicy.shouldPreferBuiltInForColdRemote(
                        remoteWasActiveAtStart: remoteWasActiveAtStart,
                        builtInAvailable: builtInAvailable,
                        builtInFrameCount: builtinProbe.count
                    )
                if remoteHasUsableAudio && !preferBuiltIn {
                    select(.remote)
                } else if builtInAvailable {
                    // A real built-in microphone exists; a committed built-in probe is a valid end
                    // state even if it captured nothing (native Voice behavior).
                    select(.builtIn)
                } else {
                    // No usable source at all. Keep the failure explicit instead of silently
                    // reporting an empty built-in capture as if it had succeeded.
                    pendingOutcome = remoteWasActiveAtStart ? .noFrames : .remoteStartTimeout
                    rmDebug("🎙 stop with no usable source builtInAvailable=false "
                            + "remoteWasActiveAtStart=\(remoteWasActiveAtStart) "
                            + "→ \(pendingOutcome?.rawValue ?? "no_frames")")
                }
            }
            continuation.finish()
        }
        let selected = source ?? .builtIn
        let outcome: VoiceCapturedAudio.Outcome
        if capturedFrames > 0 {
            outcome = selected == .remote ? .remoteCaptured : .builtInCaptured
        } else {
            outcome = pendingOutcome ?? .noFrames
        }
        if outcome == .remoteCaptured {
            let latencyText = remoteFirstFrameLatencyMilliseconds
                .map { String(format: "%.1fms", $0) } ?? "n/a"
            rmDebug("🎙 capture outcome=\(outcome.rawValue) source=\(selected.rawValue) "
                    + "frames=\(capturedFrames) remoteFirstFrameLatency=\(latencyText)")
        } else {
            rmDebug("🎙 capture outcome=\(outcome.rawValue) source=\(selected.rawValue) "
                    + "frames=\(capturedFrames) builtInAvailable=\(builtInAvailable)")
        }
        return VoiceCapturedAudio(
            pcm16: capturedPCM,
            sampleRate: Self.outputSampleRate,
            source: selected,
            frameCount: capturedFrames,
            meanSquare: capturedFrames > 0 ? sumSquares / Double(capturedFrames) : 0,
            outcome: outcome,
            remoteFirstFrameLatencyMilliseconds: remoteFirstFrameLatencyMilliseconds
        )
    }
}

/// Voice-grade 2:1 conversion. Averaging each adjacent pair is both a decimator and a one-tap
/// anti-alias filter; keeping the odd frame across chunks prevents timing drift at packet edges.
struct Downsampler48To24 {
    private var pending: Float?

    mutating func convert(_ input: [Float]) -> Data {
        input.withUnsafeBufferPointer { convert($0) }
    }

    mutating func convert(_ input: UnsafeBufferPointer<Float>) -> Data {
        guard !input.isEmpty else { return Data() }
        let carried = pending
        let sampleCount = (input.count + (carried == nil ? 0 : 1)) / 2
        var output = Data(count: sampleCount * MemoryLayout<Int16>.size)
        var index = 0
        var outputIndex = 0
        var nextPending: Float?
        output.withUnsafeMutableBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            if let first = carried {
                values[outputIndex] = Self.encode((first + input[0]) * 0.5)
                outputIndex += 1
                index = 1
            }
            while index + 1 < input.count {
                values[outputIndex] = Self.encode((input[index] + input[index + 1]) * 0.5)
                outputIndex += 1
                index += 2
            }
            if index < input.count { nextPending = input[index] }
        }
        pending = nextPending
        return output
    }

    private static func encode(_ sample: Float) -> Int16 {
        let finite = sample.isFinite ? sample : 0
        let clamped = max(-1, min(1, finite))
        return Int16(clamped * 32767).littleEndian
    }
}
