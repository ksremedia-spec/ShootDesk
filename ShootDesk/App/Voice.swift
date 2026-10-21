import Foundation
import WhisperKit

/// Press and hold to talk in Ask. WhisperKit (Argmax) runs OpenAI's Whisper speech model on the phone:
/// the recording never leaves it. The model is downloaded once (from Argmax's page on Hugging Face) into
/// Application Support, kept out of iCloud backups, and loaded the first time Ask needs it.
@MainActor @Observable
final class VoiceInput {
    enum Phase: Equatable {
        case needsDownload
        case downloading(Double)     // 0...1
        case preparing               // loading the model; the very first load also tunes it for this phone
        case ready
        case listening
        case transcribing
        case failed(String)
    }

    /// The model Argmax recommends for iPhone ("maximum accuracy"), as named on Hugging Face.
    static let variant = "openai_whisper-large-v3-v20240930_626MB"
    static let sizeLabel = "626 MB"

    private(set) var phase: Phase = .needsDownload
    /// What Whisper has heard so far while you're still holding the button.
    private(set) var liveText = ""
    /// 0...1, how loud the last moment of audio was (for the little level meter).
    private(set) var level: Float = 0

    private var kit: WhisperKit?
    private var hint = ""
    /// What's settled so far while you talk: earlier sentences Whisper won't change, and where they end in the
    /// recording. Each pass only re-reads from there, so passes stay short however long you talk.
    private var confirmedText = ""
    private var confirmedEnd: Float = 0
    /// How much of the recording the last pass covered (samples).
    private var coveredSamples = 0
    private var liveTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    private static let folderKey = "whisperModelFolder"
    private static var base: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
        return dir
    }
    /// The model's folder. Saved relative to the app's own WhisperKit folder: the app's full path on the phone
    /// changes with every reinstall or update, so a saved full path stopped matching and voice asked to download
    /// again (seen Oct 21). Older saved full paths are read by their tail.
    private var savedFolder: URL? {
        guard var p = UserDefaults.standard.string(forKey: Self.folderKey) else { return nil }
        if let r = p.range(of: "/WhisperKit/") { p = String(p[r.upperBound...]) }
        let url = Self.base.appendingPathComponent(p, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    init() {
        if savedFolder != nil { phase = .preparing }
    }

    var isDownloaded: Bool { savedFolder != nil }
    var isBusy: Bool {
        switch phase {
        case .downloading, .preparing, .transcribing: return true
        default: return false
        }
    }

    /// The one-time download. Safe to call again after a failure; Hugging Face resumes what it can.
    func download() async {
        if case .downloading = phase { return }
        phase = .downloading(0)
        do {
            let folder = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.base) { progress in
                let f = progress.fractionCompleted
                // Progress updates can arrive late; never let one put a finished download back to "downloading".
                Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(f) } }
            }
            let full = folder.standardizedFileURL.path, root = Self.base.standardizedFileURL.path + "/"
            UserDefaults.standard.set(full.hasPrefix(root) ? String(full.dropFirst(root.count)) : full, forKey: Self.folderKey)
            await prepare()
        } catch {
            phase = .failed("The voice download stopped: \(error.localizedDescription)")
        }
    }

    /// Loads the model into memory. Seconds normally; the first time on a phone it can take a couple of minutes.
    func prepare() async {
        guard kit == nil else { if !isBusy { phase = .ready }; return }
        guard let folder = savedFolder else { phase = .needsDownload; return }
        phase = .preparing
        do {
            let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error,
                                          prewarm: true, load: true, download: false)
            let t0 = Date()
            kit = try await WhisperKit(config)
            NSLog("ShootDesk voice: model ready after %.0f s", Date().timeIntervalSince(t0))
            phase = .ready
        } catch {
            phase = .failed("Couldn't load the voice model: \(error.localizedDescription)")
        }
    }

    /// Finger down: start recording. Returns false if the mic isn't allowed or the model isn't ready.
    func start(hint: String) async -> Bool {
        NSLog("ShootDesk voice: hold, phase %@", "\(phase)")
        guard phase == .ready, let kit else { return false }
        guard await AudioProcessor.requestRecordPermission() else {
            phase = .failed("ShootDesk isn't allowed to use the microphone. Turn it on in Settings > ShootDesk.")
            return false
        }
        self.hint = hint
        liveText = ""
        confirmedText = ""
        confirmedEnd = 0
        coveredSamples = 0
        do {
            try kit.audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)
        } catch {
            phase = .failed("The microphone didn't start: \(error.localizedDescription)")
            return false
        }
        phase = .listening
        // Words as you talk: pass after pass, back to back, each starting where the settled part ends, and the
        // words shown as Whisper writes them, not when a pass finishes.
        liveTask = Task { [weak self] in
            while let self, self.phase == .listening {
                let fresh = kit.audioProcessor.audioSamples.count - self.coveredSamples
                if fresh < 16_000 / 2 {   // under half a second of new sound: wait for more
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    continue
                }
                await self.pass(settle: true)
            }
        }
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard let self, self.phase == .listening else { return }
                self.level = min(1, max(0, kit.audioProcessor.relativeEnergy.last ?? 0))
            }
        }
        return true
    }

    /// Finger up: stop and return the final text (empty if nothing was said).
    func stop() async -> String {
        guard phase == .listening, let kit else { return "" }
        liveTask?.cancel(); levelTask?.cancel()
        kit.audioProcessor.stopRecording()
        level = 0
        phase = .transcribing
        // One pass at a time: let the one that's running finish (it already covers nearly everything), then
        // read only what came after it, from the settled point. Usually a second or two of sound.
        await liveTask?.value
        let started = Date()
        if kit.audioProcessor.audioSamples.count - coveredSamples > 16_000 / 4 || liveText.isEmpty {
            await pass(settle: false)
        }
        NSLog("ShootDesk voice: final text %.1f s after letting go", Date().timeIntervalSince(started))
        let text = liveText
        liveText = ""
        phase = .ready
        return text
    }

    /// Finger slid away: throw the recording out.
    func cancel() {
        guard phase == .listening, let kit else { return }
        liveTask?.cancel(); levelTask?.cancel()
        kit.audioProcessor.stopRecording()
        level = 0
        liveText = ""
        phase = .ready
    }

    func deleteModel() {
        cancel()
        kit = nil
        if let folder = savedFolder { try? FileManager.default.removeItem(at: folder) }
        UserDefaults.standard.removeObject(forKey: Self.folderKey)
        phase = .needsDownload
    }

    func clearError() {
        if case .failed = phase { phase = kit != nil ? .ready : (isDownloaded ? .preparing : .needsDownload) }
    }

    /// One read of the recording from the settled point on. While you're still talking (`settle`), every
    /// sentence but the last is settled, so the next pass starts after it.
    private func pass(settle: Bool) async {
        guard let kit else { return }
        let samples = Array(kit.audioProcessor.audioSamples)
        guard samples.count > 16_000 / 3 else { return }   // under a third of a second: nothing said
        coveredSamples = samples.count
        var options = DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: false)
        options.clipTimestamps = [confirmedEnd]
        if let tok = kit.tokenizer, !hint.isEmpty {
            // Names and towns Whisper should expect, so "Rebello" doesn't come out "Rebel low".
            let tokens = tok.encode(text: " " + hint).filter { $0 < tok.specialTokens.specialTokenBegin }
            options.promptTokens = Array(tokens.suffix(200))
        }
        let settledSoFar = confirmedText
        let t0 = Date()
        var results: [TranscriptionResult] = []
        do {
            results = try await kit.transcribe(audioArray: samples, decodeOptions: options, callback: { progress in
                let partial = Self.clean(progress.text)
                Task { @MainActor [weak self] in
                    guard let self, !partial.isEmpty else { return }
                    self.liveText = Self.join(settledSoFar, partial)
                }
                return nil
            })
        } catch {
            NSLog("ShootDesk voice: pass failed: %@", "\(error)")
        }
        NSLog("ShootDesk voice: pass %.1f s of sound from %.1f s, took %.1f s, %d segments: %@",
              Double(samples.count) / 16_000, Double(confirmedEnd), Date().timeIntervalSince(t0),
              results.flatMap(\.segments).count, results.map(\.text).joined(separator: " | "))
        let segments = results.flatMap(\.segments).filter { $0.end > confirmedEnd }
        if settle, segments.count > 1 {
            let done = segments.dropLast()
            confirmedText = Self.join(confirmedText, Self.clean(done.map(\.text).joined(separator: " ")))
            confirmedEnd = done.last?.end ?? confirmedEnd
            liveText = Self.join(confirmedText, Self.clean(segments.last?.text ?? ""))
        } else {
            let rest = Self.clean(segments.map(\.text).joined(separator: " "))
            if !rest.isEmpty || settle == false { liveText = Self.join(confirmedText, rest) }
        }
    }

    nonisolated private static func join(_ a: String, _ b: String) -> String {
        [a, b].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whisper marks silence as "[BLANK_AUDIO]" and similar; drop those and tidy the spaces.
    nonisolated static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
