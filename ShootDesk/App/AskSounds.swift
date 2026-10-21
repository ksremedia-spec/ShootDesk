import AudioToolbox
import Foundation

/// The small sounds in Ask: send, answer ready, mic on and mic off. Made here as short soft tones (no sound
/// files to ship) and played as system sounds, which iOS keeps quiet when the phone is on silent.
/// Settings > Ask sounds turns them off.
enum AskSounds {
    enum Sound: CaseIterable {
        case send, done, micOn, micOff

        /// (frequency Hz, length seconds) notes played one after another.
        var notes: [(Double, Double)] {
            switch self {
            case .send: return [(660, 0.05), (990, 0.07)]
            case .done: return [(880, 0.09), (1318.5, 0.16)]
            case .micOn: return [(1046.5, 0.05)]
            case .micOff: return [(784, 0.05)]
            }
        }
        var fileName: String { "ask-\(self).wav" }
    }

    static let settingKey = "askSounds"
    static var enabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    private static var ids: [Sound: SystemSoundID] = [:]

    static func play(_ s: Sound) {
        guard enabled else { return }
        if ids[s] == nil, let url = write(s) {
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr { ids[s] = id }
        }
        if let id = ids[s] { AudioServicesPlaySystemSound(id) }
    }

    /// A 16-bit mono WAV of soft sine notes with a quick fade in and a longer fade out, so nothing clicks.
    private static func write(_ s: Sound) -> URL? {
        let rate = 44_100.0
        var samples: [Int16] = []
        for (freq, length) in s.notes {
            let n = Int(rate * length)
            for i in 0..<n {
                let t = Double(i) / rate
                let attack = min(1, t / 0.006)
                let release = min(1, (length - t) / (length * 0.7))
                let v = sin(2 * .pi * freq * t) * attack * max(0, release) * 0.28
                samples.append(Int16(v * Double(Int16.max)))
            }
        }
        var data = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian)
        put(UInt16(1).littleEndian); put(UInt16(1).littleEndian)
        put(UInt32(rate).littleEndian); put(UInt32(rate * 2).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); put(bytes.littleEndian)
        for v in samples { put(v.littleEndian) }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(s.fileName)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}
