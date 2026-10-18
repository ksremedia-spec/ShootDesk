import WidgetKit
import SwiftUI

enum WidgetStyle {
    /// Horizon azure, same as the app (#3D9BEA).
    static let accent = Color(red: 61 / 255, green: 155 / 255, blue: 234 / 255)
}

extension WidgetFamily {
    /// The Lock Screen sizes.
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: return true
        default: return false
        }
    }
}

struct NextShootView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ShootEntry

    var body: some View {
        if family.isAccessory {
            // Lock Screen: the system draws these in its own tinted style, with no background.
            LockScreenShootView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        } else {
            content
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
    }

    @ViewBuilder private var content: some View {
        switch entry.state {
        case .noKey:
            MessageView(symbol: "key.fill", title: "Connect Aryeo", detail: "Open ShootDesk and add your Aryeo key in Settings.")
        case .failed:
            MessageView(symbol: "wifi.exclamationmark", title: "Can't reach Aryeo", detail: "Trying again shortly.")
        case .ready(let shoots, let fetchedAt, let offline):
            let parts = NextShoots.split(shoots, at: entry.date)
            if let next = parts.next {
                switch family {
                case .systemSmall:
                    SmallShootView(shoot: next, now: entry.date)
                        .widgetURL(NextShoots.shootURL(next))
                case .systemMedium:
                    MediumShootView(shoot: next, now: entry.date)
                        .widgetURL(NextShoots.shootURL(next))
                default:
                    // Large, and the full-page size on iOS 27.
                    LargeShootView(next: next, later: parts.later, now: entry.date, fetchedAt: fetchedAt,
                                   offline: offline, maxLater: family == .systemLarge ? 3 : 9)
                        .widgetURL(NextShoots.shootURL(next))
                }
            } else {
                MessageView(symbol: "calendar", title: "No shoots booked",
                            detail: "Nothing in the next \(NextShoots.lookAheadDays) days.")
            }
        }
    }
}

// MARK: - Pieces

/// "TODAY", "TOMORROW", "TUESDAY", "THU, OCT 22", or "NOW" while the shoot is underway.
func shootHeader(_ shoot: WidgetShoot, _ now: Date) -> String {
    shoot.isUnderway(at: now) ? "NOW" : shoot.dayLabel(at: now).uppercased()
}

/// "1:30 PM", or "Until 3:30 PM" while underway.
func shootBigTime(_ shoot: WidgetShoot, _ now: Date) -> String {
    shoot.isUnderway(at: now) ? "Until \(FieldTime.clockAMPM(shoot.end))" : shoot.startClock
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

struct ShootTags: View {
    let shoot: WidgetShoot
    var body: some View {
        HStack(spacing: 3) {
            if shoot.drone { Tag(text: "DRONE") }
            if shoot.video { Tag(text: "VIDEO") }
        }
    }
}

struct WeatherLine: View {
    let weather: ShootWeather
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: weather.symbol).symbolRenderingMode(.multicolor)
            Text(weather.warning ?? weather.line).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(weather.warning == nil ? Color.secondary : Color.orange)
    }
}

/// Starts-in countdown for the next few hours; the system keeps it ticking.
struct Countdown: View {
    let shoot: WidgetShoot
    let now: Date
    var body: some View {
        let gap = shoot.start.timeIntervalSince(now)
        if gap > 0 && gap < 3 * 3600 {
            Text("Starts in \(shoot.start, style: .relative)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct DirectionsButton: View {
    let shoot: WidgetShoot
    var body: some View {
        if let url = NextShoots.directionsURL(shoot) {
            Link(destination: url) {
                Label("Directions", systemImage: "location.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(WidgetStyle.accent, in: Capsule())
            }
        }
    }
}

struct MessageView: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(WidgetStyle.accent)
                .widgetAccentable()
            Spacer(minLength: 0)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Small

struct SmallShootView: View {
    let shoot: WidgetShoot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(shootHeader(shoot, now))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetStyle.accent)
                    .widgetAccentable()
                    .lineLimit(1)
                Spacer(minLength: 0)
                ShootTags(shoot: shoot)
            }
            Text(shootBigTime(shoot, now))
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.top, 2)
            Spacer(minLength: 4)
            // One line for the street now that the package sits under it; a small widget has no room for two.
            Text(shoot.street)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text("\(shoot.town) · \(shoot.agentFirstName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(shoot.package)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let w = shoot.weather {
                WeatherLine(weather: w).padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Medium

struct MediumShootView: View {
    let shoot: WidgetShoot
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(shootHeader(shoot, now))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetStyle.accent)
                    .widgetAccentable()
                Text(shootBigTime(shoot, now))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.top, 2)
                Countdown(shoot: shoot, now: now)
                Spacer(minLength: 4)
                Text(shoot.street)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(shoot.town) · \(shoot.agent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 6) {
                if let w = shoot.weather {
                    HStack(spacing: 6) {
                        Image(systemName: w.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(w.temperatureF.map { "\($0)°" } ?? w.summary)
                                .font(.subheadline.weight(.semibold))
                            Text(w.rainChance.map { "\($0)% rain" } ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let warning = w.warning {
                        Text(warning)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Text(shoot.package)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                DirectionsButton(shoot: shoot)
            }
            .frame(width: 118, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Large and full page

struct LargeShootView: View {
    let next: WidgetShoot
    let later: [WidgetShoot]
    let now: Date
    let fetchedAt: Date
    let offline: Bool
    let maxLater: Int

    /// "Updated 1:40 AM", or "Offline · saved Wed 3:15 PM" when showing an older saved copy.
    private var updatedLabel: String {
        let sameDay = FieldTime.isSameDay(fetchedAt, now)
        let when = sameDay ? FieldTime.clockAMPM(fetchedAt) : FieldTime.format(fetchedAt, "EEE h:mm a")
        return offline ? "Offline · saved \(when)" : "Updated \(when)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NEXT SHOOT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetStyle.accent)
                    .widgetAccentable()
                Spacer()
                Text(updatedLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(shootHeader(next, now).capitalized) · \(next.isUnderway(at: now) ? shootBigTime(next, now) : next.timeRange)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ShootTags(shoot: next)
                }
                Text(next.street)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(next.town) · \(next.agent)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(next.package)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Countdown(shoot: next, now: now)
                HStack {
                    if let w = next.weather { WeatherLine(weather: w) }
                    Spacer(minLength: 6)
                    DirectionsButton(shoot: next)
                }
                .padding(.top, 4)
            }

            Divider()

            Text("COMING UP")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            if later.isEmpty {
                Text("Nothing else booked in the next \(NextShoots.lookAheadDays) days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(later.prefix(maxLater)) { s in
                    LaterRow(shoot: s, now: now)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct LaterRow: View {
    let shoot: WidgetShoot
    let now: Date

    var body: some View {
        if let url = NextShoots.shootURL(shoot) {
            Link(destination: url) { row }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(shoot.dayLabel(at: now))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(shoot.startClock)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(shoot.street).font(.subheadline).lineLimit(1)
                Text("\(shoot.town) · \(shoot.agent)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(shoot.package).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 4)
            ShootTags(shoot: shoot)
        }
    }
}

// MARK: - Previews (Xcode canvas only; fictional data)

#Preview(as: .systemSmall) {
    NextShootWidget()
} timeline: {
    ShootEntry.sample()
}

#Preview(as: .systemMedium) {
    NextShootWidget()
} timeline: {
    ShootEntry.sample()
}

#Preview(as: .systemLarge) {
    NextShootWidget()
} timeline: {
    ShootEntry.sample()
}
