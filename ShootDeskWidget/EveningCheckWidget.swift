import WidgetKit
import SwiftUI
import Security

// The "Evening Check" widget: the same check as the app's Tonight screen (rain, wind, drone airspace,
// bad agent emails, missing shoot times, sunset, and a better day to move to), refreshed about every
// hour from two small Aryeo requests. Tapping it opens Tonight; tapping a shoot opens that shoot.

struct EveningCheckWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CheckWidget.widgetKind, provider: CheckProvider()) { entry in
            CheckView(entry: entry)
        }
        .configurationDisplayName("Evening Check")
        .description("Your next shoots checked for weather, drone airspace and agent emails.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Timeline

struct CheckEntry: TimelineEntry {
    enum State {
        case noKey
        case failed
        case ready(check: WidgetCheck, offline: Bool)
    }

    let date: Date
    let state: State

    var needsRetry: Bool {
        switch state {
        case .ready(let check, let offline): return offline || !check.weatherUnknown.isEmpty
        case .failed: return true
        case .noKey: return false
        }
    }

    /// Made-up example for the widget gallery (not real client data).
    static func sample(now: Date = Date()) -> CheckEntry {
        let tomorrow = FieldTime.addDays(1, to: FieldTime.startOfDay(now)).addingTimeInterval(10.5 * 3600)
        let problem = WidgetCheckItem(id: "sample-1", number: 1, start: tomorrow, street: "12 Harbor View Rd",
                                      town: "Dartmouth", agent: "Sample Agent",
                                      issues: [WidgetIssue(kind: "rain", title: "Rain during the shoot", detail: "70% chance"),
                                               WidgetIssue(kind: "airspace", title: "2 mi from New Bedford airport", detail: "")],
                                      suggestedDate: FieldTime.addDays(3, to: tomorrow), suggestedReason: "Sunny, 5% rain")
        let fine = WidgetCheckItem(id: "sample-2", number: 2, start: tomorrow.addingTimeInterval(4 * 3600),
                                   street: "48 Elm St", town: "Westport", agent: "Example Agent",
                                   issues: [], suggestedDate: nil, suggestedReason: nil)
        return CheckEntry(date: now, state: .ready(check: WidgetCheck(checkedAt: now, items: [problem, fine]), offline: false))
    }
}

struct CheckProvider: TimelineProvider {
    func placeholder(in context: Context) -> CheckEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (CheckEntry) -> Void) {
        if context.isPreview {
            completion(.sample())
            return
        }
        Task { completion(await CheckLoader.entry(now: Date())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CheckEntry>) -> Void) {
        Task {
            let now = Date()
            let entry = await CheckLoader.entry(now: now)
            // Re-check in an hour (20 minutes if Aryeo or the weather didn't answer), and right after
            // midnight, when "tomorrow" becomes a different day.
            let soon = now.addingTimeInterval(entry.needsRetry ? 20 * 60 : 60 * 60)
            let midnight = FieldTime.addDays(1, to: FieldTime.startOfDay(now))
            var entries = [entry]
            // If iOS runs the midnight refresh late, this redraw at least relabels "Tomorrow" as "Today".
            if midnight < soon { entries.append(CheckEntry(date: midnight, state: entry.state)) }
            completion(Timeline(entries: entries, policy: .after(min(soon, midnight.addingTimeInterval(2 * 60)))))
        }
    }
}

enum CheckLoader {
    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EveningCheck", isDirectory: true)
            .appendingPathComponent("check.json")
    }

    static func entry(now: Date) async -> CheckEntry {
        HTTP.timeout = 10
        let key = Keychain.read(KeyName.aryeo)
        if key.value.isEmpty {
            // Same rule as Next Shoot: a locked keychain after a restart isn't "no key".
            return key.status == errSecItemNotFound ? CheckEntry(date: now, state: .noKey) : savedOrFailed(now)
        }
        do {
            let check = try await CheckWidget.run(aryeo: AryeoClient(key: key.value), weather: WeatherClient(), now: now)
            check.save(to: cacheURL)
            return CheckEntry(date: now, state: .ready(check: check, offline: false))
        } catch {
            return savedOrFailed(now)
        }
    }

    private static func savedOrFailed(_ now: Date) -> CheckEntry {
        // A saved copy from an earlier day checked a different "tomorrow"; don't show it as current.
        if let saved = WidgetCheck.load(from: cacheURL), FieldTime.isSameDay(saved.checkedAt, now) {
            return CheckEntry(date: now, state: .ready(check: saved, offline: true))
        }
        return CheckEntry(date: now, state: .failed)
    }
}

// MARK: - Views

struct CheckView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CheckEntry

    var body: some View {
        content
            .widgetURL(NextShoots.tonightURL)
            .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    @ViewBuilder private var content: some View {
        switch entry.state {
        case .noKey:
            MessageView(symbol: "key.fill", title: "Connect Aryeo", detail: "Open ShootDesk and add your Aryeo key in Settings.")
        case .failed:
            MessageView(symbol: "wifi.exclamationmark", title: "Can't reach Aryeo", detail: "Trying again shortly.")
        case .ready(let check, let offline):
            switch family {
            case .systemSmall:
                SmallCheckView(check: check, now: entry.date, offline: offline)
            case .systemMedium:
                ListCheckView(check: check, now: entry.date, offline: offline, maxProblems: 2, maxIssueLines: 1)
            default:
                ListCheckView(check: check, now: entry.date, offline: offline, maxProblems: 3, maxIssueLines: 3)
            }
        }
    }
}

/// "Checked 8:49 AM" or "Offline · checked 6:10 AM"
private func checkedLabel(_ check: WidgetCheck, offline: Bool) -> String {
    let t = FieldTime.clockAMPM(check.checkedAt)
    return offline ? "Offline · checked \(t)" : "Checked \(t)"
}

struct CheckHeader: View {
    let check: WidgetCheck
    let offline: Bool
    var body: some View {
        HStack {
            Text("EVENING CHECK")
                .font(.caption2.weight(.bold))
                .foregroundStyle(WidgetStyle.accent)
                .widgetAccentable()
            Spacer(minLength: 4)
            Text(checkedLabel(check, offline: offline))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Green check only when everything was checked and nothing was flagged; orange warning when something
/// needs you; grey question mark when the weather couldn't be checked.
struct StatusIcon: View {
    let check: WidgetCheck
    var body: some View {
        if !check.needsYou.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
        } else if !check.weatherUnknown.isEmpty {
            Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.secondary)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        }
    }
}

struct SmallCheckView: View {
    let check: WidgetCheck
    let now: Date
    let offline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EVENING CHECK")
                .font(.caption2.weight(.bold))
                .foregroundStyle(WidgetStyle.accent)
                .widgetAccentable()
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                StatusIcon(check: check)
                Text(check.headline)
                    .lineLimit(2)
            }
            .font(.headline)
            if let first = check.needsYou.first {
                Text("\(first.whenLabel(at: now)) · \(first.street)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(first.issues.map { $0.title }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(check.weatherUnknown.isEmpty ? check.subline : "Couldn't get the forecast. Trying again soon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text(checkedLabel(check, offline: offline))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Medium and large: the shoots that need you with their warnings, then the ones that are clear.
struct ListCheckView: View {
    let check: WidgetCheck
    let now: Date
    let offline: Bool
    let maxProblems: Int
    let maxIssueLines: Int

    private var isLarge: Bool { maxIssueLines > 1 }

    /// Room left for the "no warnings" rows after the problem shoots (keeps busy nights from overflowing).
    private var clearRoom: Int { max(0, 4 - min(check.needsYou.count, maxProblems)) }

    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 8 : 5) {
            if isLarge { CheckHeader(check: check, offline: offline) }
            HStack(spacing: 6) {
                StatusIcon(check: check)
                Text(check.headline).font(.headline).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                // Medium has no header row, so the check time goes here.
                Text(isLarge ? check.subline : checkedLabel(check, offline: offline))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(check.needsYou.prefix(maxProblems)) { item in
                ProblemRow(item: item, now: now, maxIssueLines: maxIssueLines)
            }
            if isLarge && check.needsYou.count > maxProblems {
                Text("+ \(check.needsYou.count - maxProblems) more in the app")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isLarge && check.needsYou.isEmpty {
                // Medium with nothing flagged: list what was checked.
                ForEach(check.clear.prefix(3)) { item in
                    ClearRow(item: item, now: now)
                }
            }
            if isLarge && !check.clear.isEmpty {
                Divider()
                ForEach(check.clear.prefix(clearRoom)) { item in
                    ClearRow(item: item, now: now)
                }
                if check.clear.count > clearRoom {
                    Text("+ \(check.clear.count - clearRoom) more with no warnings")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ProblemRow: View {
    let item: WidgetCheckItem
    let now: Date
    let maxIssueLines: Int

    var body: some View {
        if let url = NextShoots.shootURL(orderID: item.id) {
            Link(destination: url) { row }
        } else {
            row
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(item.whenLabel(at: now)) · \(item.street)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if maxIssueLines == 1 {
                    // Medium: one icon per warning, to save room.
                    ForEach(item.issues, id: \.self) { issue in
                        Image(systemName: issue.symbol).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if maxIssueLines == 1 {
                Text(item.issues.first?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                ForEach(item.issues.prefix(maxIssueLines), id: \.self) { issue in
                    Label {
                        Text(issue.title).lineLimit(1)
                    } icon: {
                        Image(systemName: issue.symbol).foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
                if let move = item.suggestionLine {
                    Label(move, systemImage: "arrow.turn.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetStyle.accent)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct ClearRow: View {
    let item: WidgetCheckItem
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.weatherChecked ? "checkmark.circle.fill" : "questionmark.circle.fill")
                .foregroundStyle(item.weatherChecked ? Color.green : Color.secondary)
                .font(.caption)
            Text("\(item.whenLabel(at: now)) · \(item.street)\(item.weatherChecked ? "" : " · weather not checked")")
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(item.agent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview(as: .systemSmall) {
    EveningCheckWidget()
} timeline: {
    CheckEntry.sample()
}

#Preview(as: .systemMedium) {
    EveningCheckWidget()
} timeline: {
    CheckEntry.sample()
}

#Preview(as: .systemLarge) {
    EveningCheckWidget()
} timeline: {
    CheckEntry.sample()
}
