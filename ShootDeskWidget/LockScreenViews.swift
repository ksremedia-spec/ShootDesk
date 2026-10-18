import WidgetKit
import SwiftUI

// Lock Screen versions of Next Shoot. iOS draws these in one tint over the wallpaper, so they use
// text weight and layout rather than color. Three sizes:
//   inline       – one line above the clock: "1:30 PM · 28 Erin Ct"
//   rectangular  – three lines under the clock: day + time, street, then a warning or town · agent
//   circular     – a small round badge: start time and day

struct LockScreenShootView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ShootEntry

    var body: some View {
        switch entry.state {
        case .noKey:
            LockMessage(symbol: "key.fill", short: "Aryeo", text: "Open ShootDesk to connect Aryeo")
        case .failed:
            LockMessage(symbol: "wifi.exclamationmark", short: "Offline", text: "Can't reach Aryeo")
        case .ready(let shoots, _, _):
            let parts = NextShoots.split(shoots, at: entry.date)
            if let next = parts.next {
                shoot(next)
                    .widgetURL(NextShoots.shootURL(next))
            } else {
                LockMessage(symbol: "calendar", short: "None", text: "No shoots booked")
            }
        }
    }

    @ViewBuilder private func shoot(_ s: WidgetShoot) -> some View {
        switch family {
        case .accessoryInline:
            Text(inlineText(s))
        case .accessoryCircular:
            LockCircle(shoot: s, now: entry.date)
        default:
            LockRectangle(shoot: s, now: entry.date)
        }
    }

    /// "1:30 PM · 28 Erin Ct", "Fri 10:30 AM · 27-29 Willow St", "Now · 28 Erin Ct"
    private func inlineText(_ s: WidgetShoot) -> String {
        let now = entry.date
        if s.isUnderway(at: now) { return "Now · \(s.street)" }
        let time = FieldTime.isSameDay(s.start, now) ? s.startClock : "\(FieldTime.format(s.start, "EEE")) \(s.startClock)"
        return "\(time) · \(s.street)"
    }
}

struct LockRectangle: View {
    let shoot: WidgetShoot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(firstLine)
                .font(.headline)
                .widgetAccentable()
                .lineLimit(1)
            Text(shoot.street)
                .font(.body)
                .lineLimit(1)
            if let warning = shoot.weather?.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Text("\(shoot.town) · \(shoot.agentFirstName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Today · 1:30 PM", "Friday · 10:30 AM", "Now · until 3:30 PM"
    private var firstLine: String {
        if shoot.isUnderway(at: now) { return "Now · until \(FieldTime.clockAMPM(shoot.end))" }
        return "\(shoot.dayLabel(at: now)) · \(shoot.startClock)"
    }
}

struct LockCircle: View {
    let shoot: WidgetShoot
    let now: Date

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(shoot.isUnderway(at: now) ? "NOW" : FieldTime.clock(shoot.start))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(dayShort)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .widgetAccentable()
            }
            .padding(4)
        }
    }

    /// "PM" today, "TMRW" tomorrow, otherwise the weekday ("FRI").
    private var dayShort: String {
        if shoot.isUnderway(at: now) { return "UNTIL \(FieldTime.clock(shoot.end))" }
        if FieldTime.isSameDay(shoot.start, now) { return FieldTime.format(shoot.start, "a") }
        if FieldTime.isSameDay(shoot.start, FieldTime.addDays(1, to: now)) { return "TMRW" }
        return FieldTime.format(shoot.start, "EEE").uppercased()
    }
}

/// States without a shoot to show (no key, offline with nothing saved, nothing booked).
struct LockMessage: View {
    @Environment(\.widgetFamily) private var family
    let symbol: String
    let short: String
    let text: String

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(text)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                    Text(short).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        default:
            Label(text, systemImage: symbol)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview(as: .accessoryRectangular) {
    NextShootWidget()
} timeline: {
    ShootEntry.sample()
}

#Preview(as: .accessoryInline) {
    NextShootWidget()
} timeline: {
    ShootEntry.sample()
}

#Preview(as: .accessoryCircular) {
    NextShootWidget()
} timeline: {
    ShootEntry.sample()
}
