import SwiftUI
import UIKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Big saves to Photos (a whole set of photos, or a video) so you can see them coming in: a small pill in the app,
/// and the Lock Screen / Dynamic Island while you're in another app. Single photos don't use this.
/// One at a time; a new one replaces the card of the last.
@MainActor @Observable
final class TransferCenter {
    struct Transfer: Equatable {
        var title: String        // "129 Huttleston Ave"
        var kind: String         // "34 photos", "Video"
        var fraction: Double     // 0...1
        var line: String         // "12 of 34", "45%"
        var finished = false
        var failed = false
        var paused = false
    }

    private(set) var current: Transfer?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var lastPush = Date.distantPast
    private var hideTask: Task<Void, Never>?

    func begin(title: String, kind: String, line: String) {
        hideTask?.cancel()
        current = Transfer(title: title, kind: kind, fraction: 0, line: line)
        // iOS lets the app keep working for a short while after you leave it; ask for that time.
        if background == .invalid {
            background = UIApplication.shared.beginBackgroundTask(withName: "Save to Photos") { [weak self] in
                Task { @MainActor in self?.ranOutOfTime() }
            }
        }
        lastPush = .distantPast
        pushActivity(start: true)
    }

    func progress(_ fraction: Double, line: String) {
        guard var t = current, !t.finished else { return }
        t.fraction = min(1, max(0, fraction))
        t.line = line
        t.paused = false
        current = t
        // The Lock Screen only needs a fresh number about once a second.
        if Date().timeIntervalSince(lastPush) > 1 { pushActivity() }
    }

    func finish(ok: Bool, line: String) {
        guard var t = current else { return }
        t.finished = true
        t.failed = !ok
        t.fraction = ok ? 1 : t.fraction
        t.line = line
        current = t
        pushActivity(end: true)
        endBackground()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { withAnimation(.snappy) { self.current = nil } }
        }
    }

    private func ranOutOfTime() {
        // Out of background time: iOS pauses the app until it's opened again.
        if var t = current, !t.finished {
            t.paused = true
            current = t
            pushActivity()
        }
        endBackground()
    }

    private func endBackground() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        background = .invalid
    }

    private func pushActivity(start: Bool = false, end: Bool = false) {
        lastPush = Date()
        #if canImport(ActivityKit)
        guard let t = current, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = TransferActivityAttributes.ContentState(fraction: t.fraction, line: t.line, finished: t.finished,
                                                             failed: t.failed, paused: t.paused)
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            let running = Activity<TransferActivityAttributes>.activities
            if start {
                for a in running { await a.end(nil, dismissalPolicy: .immediate) }
                let attributes = TransferActivityAttributes(title: t.title, kind: t.kind)
                _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            } else if end {
                for a in running { await a.end(content, dismissalPolicy: .after(Date().addingTimeInterval(8))) }
            } else {
                for a in running { await a.update(content) }
            }
        }
        #endif
    }
}

/// The pill: small, bottom left, above the tab bar. A ring that fills, and "12 of 34".
struct TransferPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let t = model.transfers.current {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                    if t.finished {
                        Image(systemName: t.failed ? "exclamationmark" : "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(t.failed ? Color.orange : Color.green)
                    } else {
                        Circle().trim(from: 0, to: t.fraction)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.3), value: t.fraction)
                    }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.finished ? (t.failed ? "Save didn't finish" : "Saved to Photos") : "Saving \(t.kind.lowercased())")
                        .font(.caption.weight(.semibold))
                    Text(t.line).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .lineLimit(1)
            }
            .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .padding(.leading, Gutter.of(.compact))
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// Shows the save-progress pill over this tab (it sits above the tab bar wherever that is).
    func transferPill() -> some View {
        overlay(alignment: .bottomLeading) { TransferPill() }
    }
}

/// Downloads one file with progress (URLSession's async download doesn't report any).
enum ProgressDownload {
    static func file(from url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        final class Box: @unchecked Sendable { var observation: NSKeyValueObservation? }
        let box = Box()
        return try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.downloadTask(with: url) { tmp, _, error in
                box.observation = nil
                if let error { cont.resume(throwing: error); return }
                guard let tmp else { cont.resume(throwing: URLError(.badServerResponse)); return }
                // The temporary file is deleted when this returns, so move it now.
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                do { try FileManager.default.moveItem(at: tmp, to: dest); cont.resume(returning: dest) }
                catch { cont.resume(throwing: error) }
            }
            box.observation = task.progress.observe(\.fractionCompleted) { p, _ in onProgress(p.fractionCompleted) }
            task.resume()
        }
    }
}
