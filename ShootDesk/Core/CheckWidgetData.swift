import Foundation

// Data for the "Evening Check" widget. It runs the exact same EveningCheck as the app's Tonight screen,
// but from two small Aryeo requests instead of the full order history:
//   1. appointments for the next 10 days (the shoots being checked, plus what's booked on days a
//      reschedule might be suggested for), and
//   2. the newest 30 orders (to catch recent orders that still have no shoot time).
// The one thing it can't do without the full history is the agent notes ("Back after 6 months",
// "Usually adds video"); those stay in the app. Every warning (rain, wind, airspace, bad email,
// no time yet, sunset) and the suggested better day are the same.

public struct WidgetIssue: Codable, Hashable, Sendable {
    public let kind: String
    public let title: String
    public let detail: String

    /// SF Symbol for each kind of warning.
    public var symbol: String {
        switch CheckIssue.Kind(rawValue: kind) {
        case .rain?: return "cloud.rain.fill"
        case .wind?: return "wind"
        case .airspace?: return "airplane"
        case .email?: return "envelope.badge"
        case .unscheduled?: return "calendar.badge.exclamationmark"
        case .sunset?: return "sunset.fill"
        case nil: return "exclamationmark.triangle.fill"
        }
    }
}

public struct WidgetCheckItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String          // order id
    public let number: Int
    public let start: Date?
    public let street: String
    public let town: String
    public let agent: String
    public let issues: [WidgetIssue]
    public let suggestedDate: Date?
    public let suggestedReason: String?
    /// False when the forecast couldn't be fetched for this shoot.
    public let weatherChecked: Bool

    public var needsAttention: Bool { !issues.isEmpty }

    public init(result: CheckResult) {
        id = result.job.order.id
        number = result.job.number
        start = result.job.start
        street = result.job.street
        town = result.job.town
        agent = result.job.agentName
        issues = result.issues.map { WidgetIssue(kind: $0.kind.rawValue, title: $0.title, detail: $0.detail) }
        suggestedDate = result.suggestion?.date
        suggestedReason = result.suggestion?.reason
        weatherChecked = result.weatherChecked
    }

    public init(id: String, number: Int, start: Date?, street: String, town: String, agent: String,
                issues: [WidgetIssue], suggestedDate: Date?, suggestedReason: String?, weatherChecked: Bool = true) {
        self.id = id; self.number = number; self.start = start; self.street = street; self.town = town
        self.agent = agent; self.issues = issues; self.suggestedDate = suggestedDate; self.suggestedReason = suggestedReason
        self.weatherChecked = weatherChecked
    }

    /// "Tomorrow 10:30 AM", "Saturday 9:00 AM", or "No time yet, order 1851".
    public func whenLabel(at now: Date) -> String {
        guard let s = start else { return "No time yet, order \(number)" }
        let cal = FieldTime.calendar
        let day: String
        if cal.isDate(s, inSameDayAs: now) { day = "Today" }
        else if cal.isDate(s, inSameDayAs: FieldTime.addDays(1, to: now)) { day = "Tomorrow" }
        else { day = FieldTime.format(s, "EEEE") }
        return "\(day) \(FieldTime.clockAMPM(s))"
    }

    /// "Move to Mon Oct 19, 10:30 AM"
    public var suggestionLine: String? {
        suggestedDate.map { "Move to \(FieldTime.format($0, "EEE MMM d")), \(FieldTime.clockAMPM($0))" }
    }
}

public struct WidgetCheck: Codable, Hashable, Sendable {
    public let checkedAt: Date
    /// Shoots that need you first, then the ones that are clear; each group soonest first.
    public let items: [WidgetCheckItem]

    public init(checkedAt: Date, items: [WidgetCheckItem]) {
        self.checkedAt = checkedAt
        self.items = items
    }

    public var needsYou: [WidgetCheckItem] { items.filter { $0.needsAttention } }
    public var clear: [WidgetCheckItem] { items.filter { !$0.needsAttention } }

    /// Shoots with no warnings whose weather couldn't be checked: never shown as "all clear".
    public var weatherUnknown: [WidgetCheckItem] { items.filter { !$0.weatherChecked } }

    /// True only when every shoot was fully checked and nothing was flagged.
    public var isAllClear: Bool { needsYou.isEmpty && weatherUnknown.isEmpty }

    /// "1 shoot needs you", "2 shoots need you", "Weather not checked", "All clear"
    public var headline: String {
        let n = needsYou.count
        if n == 0 { return weatherUnknown.isEmpty ? "All clear" : "Weather not checked" }
        return n == 1 ? "1 shoot needs you" : "\(n) shoots need you"
    }

    /// "2 shoots checked" / "Nothing booked tomorrow"
    public var subline: String {
        if items.isEmpty { return "Nothing booked tomorrow" }
        return items.count == 1 ? "1 shoot checked" : "\(items.count) shoots checked"
    }

    public static func load(from url: URL) -> WidgetCheck? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetCheck.self, from: data)
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

public enum CheckWidget {
    /// Must match the widget's `kind`, so the app can ask it to reload.
    public static let widgetKind = "EveningCheck"

    /// Runs the evening check from two small requests. Same rules as the app's Tonight screen.
    public static func run(aryeo: AryeoClient, weather: WeatherClient, now: Date = Date()) async throws -> WidgetCheck {
        async let apptsTask = aryeo.appointments(from: FieldTime.startOfDay(now), to: FieldTime.addDays(10, to: now))
        async let recentTask = aryeo.ordersPage(1, perPage: 30)
        let appts = try await apptsTask
        let recent = try await recentTask.data

        // One order per id; the orders endpoint has every appointment, so its copy wins.
        var byID: [String: Order] = [:]
        for a in appts {
            guard let o = a.order, (a.status ?? "").uppercased() != "CANCELED" else { continue }
            if let existing = byID[o.id] {
                // Same order, another appointment in the window: keep both appointments.
                byID[o.id] = existing.with(appointments: (existing.appointments ?? []) + [a.appointment])
            } else {
                byID[o.id] = o.with(appointments: [a.appointment])
            }
        }
        for o in recent { byID[o.id] = o }

        let jobs = JobBuilder.jobs(from: Array(byID.values), now: now)
        let results = await EveningCheck(weather: weather).run(jobs: jobs, customers: [], now: now)
        return make(from: results, at: now)
    }

    /// Turns the app's own check results into the widget's saved form.
    public static func make(from results: [CheckResult], at date: Date) -> WidgetCheck {
        let items = results.map(WidgetCheckItem.init(result:)).sorted { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            return (a.start ?? .distantFuture) < (b.start ?? .distantFuture)
        }
        return WidgetCheck(checkedAt: date, items: items)
    }

    /// A short fingerprint of what the widget would show, so the app only reloads it on a change.
    public static func signature(_ results: [CheckResult]) -> String {
        results.map { r in "\(r.job.id)|\(r.issues.map { $0.title }.joined(separator: ","))|\(r.suggestion?.date.timeIntervalSince1970 ?? 0)|\(r.weatherChecked)" }
            .sorted().joined(separator: ";")
    }
}

extension Order {
    /// The same order with a different appointment list.
    func with(appointments: [Appointment]) -> Order {
        Order(id: id, number: number, status: status, orderStatus: orderStatus, fulfillmentStatus: fulfillmentStatus,
              paymentStatus: paymentStatus, createdAt: createdAt, fulfilledAt: fulfilledAt, isGhost: isGhost,
              totalAmount: totalAmount, balanceAmount: balanceAmount, internalNotes: internalNotes,
              customer: customer, listing: listing, items: items, appointments: appointments)
    }
}
