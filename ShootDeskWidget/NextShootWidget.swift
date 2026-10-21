import WidgetKit
import ActivityKit
import SwiftUI
import Security

// The Home Screen widget. It reads the Aryeo key from the keychain it shares with the app,
// asks Aryeo for the next two weeks of appointments (one small request) and the weather service for
// the forecast, then lays out a timeline so it moves to the next shoot on its own when one ends.

@main
struct ShootDeskWidgets: WidgetBundle {
    var body: some Widget {
        NextShootWidget()
        EveningCheckWidget()
        ShootLiveActivityWidget()
        TransferLiveActivityWidget()
    }
}

struct NextShootWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NextShoots.widgetKind, provider: NextShootProvider()) { entry in
            NextShootView(entry: entry)
        }
        .configurationDisplayName("Next Shoot")
        .description("Your next shoot from Aryeo, with the forecast for that hour. Larger sizes list what's coming up; Lock Screen sizes show it at a glance.")
        .supportedFamilies(Self.families)
    }

    /// Home Screen: small, medium, large, plus the full-page size iOS 27 added (made for the Duo's inner screen).
    /// Lock Screen: one line above the clock, a three-line block, or a round badge.
    static var families: [WidgetFamily] {
        // Large first: Kyle's preferred default size (Oct 17 2026).
        var f: [WidgetFamily] = [.systemLarge, .systemMedium, .systemSmall,
                                 .accessoryInline, .accessoryRectangular, .accessoryCircular]
        if #available(iOS 27.0, *) { f.append(.systemExtraLargePortrait) }
        return f
    }
}

// MARK: - Timeline

struct ShootEntry: TimelineEntry {
    enum State {
        case noKey
        case failed
        case ready(shoots: [WidgetShoot], fetchedAt: Date, offline: Bool)
    }

    let date: Date
    let state: State

    var isOffline: Bool {
        switch state {
        case .ready(_, _, let offline): return offline
        case .failed: return true
        case .noKey: return false
        }
    }

    /// Made-up example for the widget gallery (not real client data).
    static func sample(now: Date = Date()) -> ShootEntry {
        let start = now.addingTimeInterval(90 * 60)
        let first = WidgetShoot(id: "sample-1", orderID: "sample-1", number: 1, start: start,
                                end: start.addingTimeInterval(80 * 60), street: "12 Harbor View Rd", town: "Dartmouth",
                                agent: "Sample Agent", package: "Essentials + Drone", drone: true, video: false,
                                latitude: nil, longitude: nil, address: nil,
                                weather: ShootWeather(summary: "Sunny", temperatureF: 62, windMph: 7, rainChance: 5,
                                                      gustMph: nil, warning: nil))
        let tomorrow = FieldTime.addDays(1, to: start)
        let second = WidgetShoot(id: "sample-2", orderID: "sample-2", number: 2, start: tomorrow,
                                 end: tomorrow.addingTimeInterval(3600), street: "48 Elm St", town: "Westport",
                                 agent: "Example Agent", package: "Essentials Plus", drone: false, video: true,
                                 latitude: nil, longitude: nil, address: nil, weather: nil)
        return ShootEntry(date: now, state: .ready(shoots: [first, second], fetchedAt: now, offline: false))
    }
}

struct NextShootProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShootEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (ShootEntry) -> Void) {
        if context.isPreview {
            completion(.sample())
            return
        }
        Task { completion(await ShootLoader.entry(now: Date())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShootEntry>) -> Void) {
        Task {
            let now = Date()
            let first = await ShootLoader.entry(now: now)
            var entries = [first]
            if case .ready(let shoots, _, _) = first.state {
                // Redraw on its own when a shoot starts or ends and at midnight, with no extra downloads.
                for t in NextShoots.changeTimes(shoots, after: now) {
                    entries.append(ShootEntry(date: t, state: first.state))
                }
            }
            // Check Aryeo again in 30 minutes (15 if the last try failed). iOS may stretch this to save battery.
            let next = now.addingTimeInterval(first.isOffline ? 15 * 60 : 30 * 60)
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}

enum ShootLoader {
    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NextShoot", isDirectory: true)
            .appendingPathComponent("shoots.json")
    }

    static func entry(now: Date) async -> ShootEntry {
        // Short time limits so weak signal at a shoot can't stall the widget.
        HTTP.timeout = 10
        let key = Keychain.read(KeyName.aryeo)
        if key.value.isEmpty {
            // Only say "Connect Aryeo" when there really is no key. Right after a restart, before the
            // first unlock, the keychain is locked: fall back to the saved copy and retry soon.
            return key.status == errSecItemNotFound ? ShootEntry(date: now, state: .noKey) : savedOrFailed(now)
        }
        do {
            let started = Date()
            var shoots = try await NextShoots.fetch(aryeo: AryeoClient(key: key.value), weather: nil, now: now)
            // Skip the forecast if Aryeo alone was slow; the next refresh will add it.
            if Date().timeIntervalSince(started) < 8 {
                await NextShoots.addWeather(to: &shoots, using: WeatherClient(), now: now)
            }
            WidgetCache(fetchedAt: now, shoots: shoots).save(to: cacheURL)
            return ShootEntry(date: now, state: .ready(shoots: shoots, fetchedAt: now, offline: false))
        } catch {
            // No signal or Aryeo is down: show the last good copy rather than an error.
            return savedOrFailed(now)
        }
    }

    private static func savedOrFailed(_ now: Date) -> ShootEntry {
        if let saved = WidgetCache.load(from: cacheURL) {
            return ShootEntry(date: now, state: .ready(shoots: saved.shoots, fetchedAt: saved.fetchedAt, offline: true))
        }
        return ShootEntry(date: now, state: .failed)
    }
}


// MARK: - Live Activity

/// Lock Screen: the street in big serif type and a countdown to when you need to leave.
struct ShootLiveActivityWidget: Widget {
    private static let accent = Color(red: 61 / 255, green: 155 / 255, blue: 234 / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShootActivityAttributes.self) { context in
            LockScreenShoot(context: context)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(NextShoots.shootURL(orderID: context.attributes.orderID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "car.fill").font(.title3).foregroundStyle(Self.accent).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LeaveCountdown(state: context.state).font(.title3.weight(.semibold)).foregroundStyle(Self.accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.street).font(.system(.headline, design: .serif)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(LockScreenShoot.line(context.state, town: context.attributes.town))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "car.fill").foregroundStyle(Self.accent)
            } compactTrailing: {
                LeaveCountdown(state: context.state).foregroundStyle(Self.accent).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "car.fill").foregroundStyle(Self.accent)
            }
            .widgetURL(NextShoots.shootURL(orderID: context.attributes.orderID))
        }
    }
}

/// "12:41" counting down to the leave time, then "Now".
private struct LeaveCountdown: View {
    let state: ShootActivityAttributes.ContentState

    var body: some View {
        if state.leaveAt > Date() {
            Text(timerInterval: Date()...state.leaveAt, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text("Now")
        }
    }
}

private struct LockScreenShoot: View {
    let context: ActivityViewContext<ShootActivityAttributes>
    private static let accent = Color(red: 61 / 255, green: 155 / 255, blue: 234 / 255)

    static func line(_ s: ShootActivityAttributes.ContentState, town: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "Starts \(f.string(from: s.start)) in \(town)"
    }

    var body: some View {
        let s = context.state
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.leaveAt > Date() ? "Leave by \(Self.clock(s.leaveAt))" : "Time to leave")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.accent)
                Text(context.attributes.street)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Self.line(s, town: context.attributes.town))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                LeaveCountdown(state: s)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 130, alignment: .trailing)
                Text(s.drive)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(18)
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
}


// MARK: - Save progress (Lock Screen and Dynamic Island)

/// A big save to Photos while you're in another app: what's saving, a bar, and "12 of 34".
struct TransferLiveActivityWidget: Widget {
    private static let accent = Color(red: 61 / 255, green: 155 / 255, blue: 234 / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            TransferLockScreen(context: context)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TransferRing(state: context.state, size: 30).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.line).font(.headline).monospacedDigit().foregroundStyle(Self.accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.system(.headline, design: .serif)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(TransferLockScreen.status(context)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } compactLeading: {
                TransferRing(state: context.state, size: 18)
            } compactTrailing: {
                Text(context.state.finished ? (context.state.failed ? "!" : "Done") : "\(Int(context.state.fraction * 100))%")
                    .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Self.accent)
            } minimal: {
                TransferRing(state: context.state, size: 18)
            }
        }
    }
}

/// A ring that fills as the save goes; a tick when it's done.
private struct TransferRing: View {
    let state: TransferActivityAttributes.ContentState
    var size: CGFloat
    private static let accent = Color(red: 61 / 255, green: 155 / 255, blue: 234 / 255)

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: size / 8)
            if state.finished {
                Image(systemName: state.failed ? "exclamationmark" : "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(state.failed ? Color.orange : Color.green)
            } else {
                Circle().trim(from: 0, to: state.fraction)
                    .stroke(Self.accent, style: StrokeStyle(lineWidth: size / 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct TransferLockScreen: View {
    let context: ActivityViewContext<TransferActivityAttributes>
    private static let accent = Color(red: 61 / 255, green: 155 / 255, blue: 234 / 255)

    static func status(_ context: ActivityViewContext<TransferActivityAttributes>) -> String {
        let s = context.state
        if s.finished { return s.failed ? "Didn't finish. Open ShootDesk to try again." : "Saved to Photos" }
        if s.paused { return "Paused. Open ShootDesk to finish." }
        return "Saving \(context.attributes.kind.lowercased())"
    }

    var body: some View {
        let s = context.state
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: s.finished ? (s.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") : "arrow.down.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(s.finished && !s.failed ? Color.green : (s.failed ? Color.orange : Self.accent))
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.status(context))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(s.finished && !s.failed ? Color.green : Self.accent)
                    .lineLimit(1)
                Text(context.attributes.title)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !s.finished {
                    ProgressView(value: s.fraction).tint(Self.accent)
                }
            }
            Spacer(minLength: 4)
            Text(s.line)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.vertical, 4)
    }
}
