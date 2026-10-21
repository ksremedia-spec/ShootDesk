import AVFoundation
import Foundation
import Speech

/// Tap-to-talk in Ask (Kyle, Oct 21), on Apple's own on-device speech recognition (SpeechAnalyzer, iOS 26+):
/// words appear as you speak, it sends itself after 2 seconds of quiet, and nothing leaves the phone. iOS manages
/// the speech model (often already there for keyboard dictation). Replaced WhisperKit, which isn't built for live
/// speech and was slow on the phone.
@MainActor @Observable
final class VoiceInput {
    enum Phase: Equatable {
        case idle
        case gettingReady(Double?)   // iOS is downloading its English speech model (rare; once)
        case listening
        case finishing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Words the recognizer has settled on.
    private(set) var settledText = ""
    /// Its current guess for the last few words; replaced as it hears more.
    private(set) var guessText = ""
    /// Recent loudness, newest last, 0...1, for the waveform.
    private(set) var levels: [Float] = Array(repeating: 0, count: 28)

    /// Called with the question when 2 seconds of quiet end a take.
    var onAutoSend: ((String) -> Void)?

    static var isAvailable: Bool { if #available(iOS 26.0, *) { return true } else { return false } }

    var text: String { [settledText, guessText].filter { !$0.isEmpty }.joined(separator: " ") }

    private var session: AnyObject?   // a LiveSession on iOS 26+
    private var silenceTask: Task<Void, Never>?
    private var lastSoundAt = Date()

    init() {
        // The old WhisperKit model (606 MB) is no longer used: give the space back.
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperKit", isDirectory: true)
        try? FileManager.default.removeItem(at: old)
        UserDefaults.standard.removeObject(forKey: "whisperModelFolder")
    }

    /// When Ask opens: make sure iOS has its speech model, so the first tap starts at once.
    func prepare() async {
        guard #available(iOS 26.0, *) else { return }
        do { try await LiveSession.ensureModel { [weak self] f in self?.phase = .gettingReady(f) } }
        catch { phase = .failed("Voice isn't available: \(error.localizedDescription)") }
        if case .gettingReady = phase { phase = .idle }
    }

    /// Tap: start listening. The panel shows straight away; the microphone follows a moment later.
    func start() {
        guard #available(iOS 26.0, *), phase == .idle || isFailed else { return }
        settledText = ""; guessText = ""
        levels = Array(repeating: 0, count: levels.count)
        phase = .listening
        lastSoundAt = Date()
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                phase = .failed("ShootDesk isn't allowed to use the microphone. Turn it on in Settings > ShootDesk.")
                return
            }
            let live = LiveSession()
            session = live
            do {
                try await live.start(
                    onText: { [weak self] settled, guess in
                        guard let self else { return }
                        if !settled.isEmpty { self.settledText = [self.settledText, settled].filter { !$0.isEmpty }.joined(separator: " ") }
                        self.guessText = guess
                    },
                    onLevel: { [weak self] level in
                        guard let self else { return }
                        self.levels.removeFirst(); self.levels.append(level)
                        if level > 0.08 { self.lastSoundAt = Date() }
                    })
            } catch {
                session = nil
                phase = .failed("The microphone didn't start: \(error.localizedDescription)")
                return
            }
            watchForQuiet()
        }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    /// After something's been said, 2 seconds of quiet sends it.
    private func watchForQuiet() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, self.phase == .listening else { return }
                if !self.text.isEmpty, Date().timeIntervalSince(self.lastSoundAt) >= 2 {
                    let q = await self.finish()
                    if !q.isEmpty { self.onAutoSend?(q) }
                    return
                }
            }
        }
    }

    /// Send button (or the quiet timer): stop and return the final text.
    func finish() async -> String {
        guard phase == .listening else { return "" }
        silenceTask?.cancel()
        phase = .finishing
        let t0 = Date()
        if #available(iOS 26.0, *), let live = session as? LiveSession {
            await live.finish()
        }
        NSLog("ShootDesk voice: final text %.2f s after stopping", Date().timeIntervalSince(t0))
        session = nil
        let q = text
        // The words stay put while the panel fades out; start() clears them.
        phase = .idle
        return q
    }

    /// X: throw the take away.
    func cancel() {
        silenceTask?.cancel()
        if #available(iOS 26.0, *), let live = session as? LiveSession {
            Task { await live.cancel() }
        }
        session = nil
        phase = .idle
    }

    func clearError() { if isFailed { phase = .idle } }
}

/// One listening session: the microphone, Apple's dictation recognizer, and the stream between them.
@available(iOS 26.0, *)
@MainActor
final class LiveSession {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    private static func recognizer() async -> DictationTranscriber {
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) ?? Locale(identifier: "en-US")
        return DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
    }

    /// Downloads iOS's English speech model if this phone doesn't have it yet.
    static func ensureModel(progress: @escaping (Double?) -> Void) async throws {
        let r = await recognizer()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [r]) {
            progress(nil)
            let p = request.progress
            let watch = Task { @MainActor in
                while !Task.isCancelled { progress(p.fractionCompleted); try? await Task.sleep(nanoseconds: 300_000_000) }
            }
            defer { watch.cancel() }
            try await request.downloadAndInstall()
        }
    }

    func start(onText: @escaping (_ settled: String, _ guess: String) -> Void,
               onLevel: @escaping (Float) -> Void) async throws {
        let recognizer = await Self.recognizer()
        try await Self.ensureModel { _ in }

        // Switching the audio on can take a moment; do it off the main thread so the listening panel opens smoothly.
        try await Task.detached(priority: .userInitiated) {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
        }.value

        let inputNode = engine.inputNode
        // The microphone's own format. Some setups (the simulator among them) report an empty one until asked
        // for the hardware side, so fall back to that.
        var micFormat = inputNode.outputFormat(forBus: 0)
        if micFormat.sampleRate == 0 || micFormat.channelCount == 0 { micFormat = inputNode.inputFormat(forBus: 0) }
        // What the recognizer wants (16 kHz mono, usually). Asked plainly if the "close to the mic" match fails.
        var target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recognizer], considering: micFormat)
        if target == nil { target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recognizer]) }
        // Last resort: the recognizer's usual input, 16 kHz mono. (The simulator offers no format at all: Apple's
        // engine doesn't run there, checked Oct 21. A real iPhone should.)
        if target == nil { target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false) }
        NSLog("ShootDesk voice: mic %@, recognizer %@", micFormat.description, target?.description ?? "none")
        guard let target, micFormat.sampleRate > 0, micFormat.channelCount > 0,
              let converter = AVAudioConverter(from: micFormat, to: target) else {
            throw NSError(domain: "ShootDesk", code: 1, userInfo: [NSLocalizedDescriptionKey: "No usable audio format"])
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let analyzer = SpeechAnalyzer(modules: [recognizer])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: target)
        try await analyzer.start(inputSequence: stream)

        results = Task { @MainActor in
            do {
                for try await r in recognizer.results {
                    let t = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.isFinal { onText(t, "") } else { onText("", t) }
                }
            } catch {}
        }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: micFormat) { buffer, _ in
            reportLevel(of: buffer, to: onLevel)
            if let converted = LiveSession.convert(buffer, with: converter, to: target) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        engine.prepare()
        try engine.start()
    }

    func finish() async {
        stopMic()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func cancel() async {
        stopMic()
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                    to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

/// Loudness of one microphone buffer, scaled so normal speech fills most of the waveform.
private func reportLevel(of buffer: AVAudioPCMBuffer, to report: @escaping (Float) -> Void) {
    guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
    var sum: Float = 0
    for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
    let rms = (sum / Float(buffer.frameLength)).squareRoot()
    let level = min(1, max(0, (20 * log10(max(rms, 1e-7)) + 55) / 45))   // about -55 dB silent, -10 dB loud
    Task { @MainActor in report(level) }
}
