import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

// Everything the Home Screen widget shows: your next shoot and the ones after it.
// Lives in Core so it's shared by the app and the widget and can be tested against live Aryeo data.

/// Weather for the shoot window, from the National Weather Service hourly forecast.
public struct ShootWeather: Codable, Hashable, Sendable {
    public let summary: String
    public let temperatureF: Int?
    public let windMph: Int?
    public let rainChance: Int?
    public let gustMph: Int?
    /// Set when the evening check would flag it ("Rain likely", "Too windy to fly").
    public let warning: String?

    /// SF Symbol for the forecast wording.
    public var symbol: String { Self.symbol(for: summary) }

    public static func symbol(for summary: String) -> String {
        let s = summary.lowercased()
        if s.contains("thunder") { return "cloud.bolt.rain.fill" }
        if s.contains("snow") || s.contains("sleet") { return "cloud.snow.fill" }
        if s.contains("rain") || s.contains("shower") || s.contains("drizzle") { return "cloud.rain.fill" }
        if s.contains("fog") || s.contains("haze") { return "cloud.fog.fill" }
        if s.contains("partly") || s.contains("mostly sunny") || s.contains("mostly clear") { return "cloud.sun.fill" }
        if s.contains("cloudy") || s.contains("overcast") { return "cloud.fill" }
        if s.contains("wind") || s.contains("breezy") { return "wind" }
        if s.contains("sunny") || s.contains("clear") { return "sun.max.fill" }
        return "cloud.sun.fill"
    }

    /// "Sunny, 61°, 8 mph"
    public var line: String {
        [summary.isEmpty ? nil : summary, temperatureF.map { "\($0)°" }, windMph.map { "\($0) mph" }]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Same thresholds as the evening check, so the widget and Tonight never disagree.
    public static func make(from forecast: Forecast, start: Date, end: Date, drone: Bool,
                            settings: EveningCheck.Settings = .init()) -> ShootWeather? {
        let hrs = forecast.hours(from: start, to: end)
        guard !hrs.isEmpty else { return nil }
        let rain = hrs.compactMap { $0.rainChance }.max()
        let wind = hrs.compactMap { $0.windMph }.max()
        let gust = forecast.daytime(on: start)?.gustMph
        let temp = hrs.compactMap { $0.temperatureF }.max()
        var warning: String?
        if (rain ?? 0) >= settings.rainChanceLimit {
            warning = "Rain likely, \(rain ?? 0)%"
        } else if drone && ((wind ?? 0) >= settings.droneWindLimitMph || (gust ?? 0) >= settings.droneGustLimitMph) {
            warning = "Too windy to fly"
        }
        return ShootWeather(summary: hrs.first?.summary ?? "", temperatureF: temp, windMph: wind,
                            rainChance: rain, gustMph: gust, warning: warning)
    }
}

/// One upcoming shoot, trimmed to what the widget needs (small enough to save on the phone).
public struct WidgetShoot: Codable, Hashable, Identifiable, Sendable {
    public let id: String          // order id + start time (an order can have two appointments)
    public let orderID: String
    public let number: Int
    public let start: Date
    public let end: Date
    public let street: String
    public let town: String
    public let agent: String
    public let package: String
    public let drone: Bool
    public let video: Bool
    public let latitude: Double?
    public let longitude: Double?
    public let address: String?
    public var weather: ShootWeather?

    public init(job: Job, start: Date, end: Date) {
        id = "\(job.order.id)-\(Int(start.timeIntervalSince1970))"
        orderID = job.order.id
        number = job.number
        self.start = start
        self.end = end
        street = job.street
        town = job.town
        agent = job.agentName
        package = job.packageSummary
        drone = job.hasDrone
        video = job.hasVideo
        latitude = job.latitude
        longitude = job.longitude
        address = job.address?.unparsedAddress
        weather = nil
    }

    public init(id: String, orderID: String, number: Int, start: Date, end: Date, street: String, town: String,
                agent: String, package: String, drone: Bool, video: Bool, latitude: Double?, longitude: Double?,
                address: String?, weather: ShootWeather?) {
        self.id = id; self.orderID = orderID; self.number = number; self.start = start; self.end = end
        self.street = street; self.town = town; self.agent = agent; self.package = package
        self.drone = drone; self.video = video; self.latitude = latitude; self.longitude = longitude
        self.address = address; self.weather = weather
    }

    public var agentFirstName: String { agent.split(separator: " ").first.map(String.init) ?? agent }

    /// "Today", "Tomorrow", "Friday" (this week) or "Mon, Oct 26", as seen at `now`.
    public func dayLabel(at now: Date) -> String {
        let cal = FieldTime.calendar
        if cal.isDate(start, inSameDayAs: now) { return "Today" }
        if cal.isDate(start, inSameDayAs: FieldTime.addDays(1, to: now)) { return "Tomorrow" }
        let days = cal.dateComponents([.day], from: FieldTime.startOfDay(now), to: FieldTime.startOfDay(start)).day ?? 99
        return days < 7 ? FieldTime.format(start, "EEEE") : FieldTime.dayLabel(start)
    }

    public func isUnderway(at now: Date) -> Bool { start <= now && now < end }

    /// "Mon, Oct 26 · 10:30 AM" style time for lists.
    public var startClock: String { FieldTime.clockAMPM(start) }
    public var timeRange: String { "\(FieldTime.clock(start)) – \(FieldTime.clockAMPM(end))" }
}

public enum NextShoots {
    public static let lookAheadDays = 14
    public static let urlScheme = "shootdesk"
    /// Must match the widget's `kind`, so the app can ask it to reload.
    public static let widgetKind = "NextShoot"

    /// Upcoming shoots (including one happening right now), soonest first, from the app's own data.
    public static func upcoming(from jobs: [Job], now: Date = Date(), limit: Int = 12) -> [WidgetShoot] {
        let horizon = FieldTime.addDays(lookAheadDays, to: now)
        return jobs.compactMap { j -> WidgetShoot? in
            guard j.status != .delivered, let s = j.start else { return nil }
            let e = j.end ?? s.addingTimeInterval(3600)
            guard e > now, s < horizon else { return nil }
            return WidgetShoot(job: j, start: s, end: e)
        }
        .sorted { $0.start < $1.start }
        .prefix(limit)
        .map { $0 }
    }

    /// Fetches upcoming shoots straight from Aryeo (one request), plus weather for the next couple.
    /// Uses the same rules as the rest of the app (canceled, ghost and test orders left out).
    public static func fetch(aryeo: AryeoClient, weather: WeatherClient?, now: Date = Date()) async throws -> [WidgetShoot] {
        // Start a few hours back so a shoot that's underway still shows.
        let from = now.addingTimeInterval(-6 * 3600)
        let to = FieldTime.addDays(lookAheadDays, to: now)
        let appts = try await aryeo.appointments(from: from, to: to)
        let orders: [Order] = appts.compactMap { a in
            guard let o = a.order, (a.status ?? "").uppercased() != "CANCELED" else { return nil }
            return Order(id: o.id, number: o.number, status: o.status, orderStatus: o.orderStatus,
                         fulfillmentStatus: o.fulfillmentStatus, paymentStatus: o.paymentStatus,
                         createdAt: o.createdAt, fulfilledAt: o.fulfilledAt, isGhost: o.isGhost,
                         totalAmount: o.totalAmount, balanceAmount: o.balanceAmount, internalNotes: o.internalNotes,
                         customer: o.customer, listing: o.listing, items: o.items, appointments: [a.appointment])
        }
        var shoots = upcoming(from: JobBuilder.jobs(from: orders, now: now), now: now)
        if let weather = weather {
            await addWeather(to: &shoots, using: weather, now: now)
        }
        return shoots
    }

    /// Adds the forecast to the next two shoots (the NWS hourly forecast reaches about 6 days out).
    public static func addWeather(to shoots: inout [WidgetShoot], using weather: WeatherClient, now: Date = Date(), count: Int = 2) async {
        let reach = now.addingTimeInterval(6 * 86_400)
        for i in shoots.indices.prefix(count) {
            let s = shoots[i]
            guard s.start < reach, let lat = s.latitude, let lon = s.longitude,
                  let fc = try? await weather.forecast(lat: lat, lon: lon) else { continue }
            shoots[i].weather = ShootWeather.make(from: fc, start: max(s.start, now), end: s.end, drone: s.drone)
        }
    }

    /// The shoot to feature at a given moment, and the ones after it.
    public static func split(_ shoots: [WidgetShoot], at date: Date) -> (next: WidgetShoot?, later: [WidgetShoot]) {
        let live = shoots.filter { $0.end > date }.sorted { $0.start < $1.start }
        return (live.first, Array(live.dropFirst()))
    }

    /// Moments the widget's content changes on its own: each shoot starting and ending, and midnight
    /// (when "Tomorrow" becomes "Today").
    public static func changeTimes(_ shoots: [WidgetShoot], after now: Date, within hours: Double = 36) -> [Date] {
        let limit = now.addingTimeInterval(hours * 3600)
        var times = Set<Date>()
        for s in shoots { times.insert(s.start); times.insert(s.end) }
        var midnight = FieldTime.addDays(1, to: FieldTime.startOfDay(now))
        while midnight < limit { times.insert(midnight); midnight = FieldTime.addDays(1, to: midnight) }
        return times.filter { $0 > now && $0 < limit }.sorted()
    }

    /// A short fingerprint, so the app only asks the widget to reload when something it shows changed.
    public static func signature(_ shoots: [WidgetShoot]) -> String {
        shoots.prefix(10).map { "\($0.id)|\($0.end.timeIntervalSince1970)|\($0.street)|\($0.agent)|\($0.package)" }
            .joined(separator: ";")
    }

    // MARK: Links the widget opens

    public static func shootURL(_ s: WidgetShoot) -> URL? { shootURL(orderID: s.orderID) }

    public static func shootURL(orderID: String) -> URL? {
        URL(string: "\(urlScheme)://shoot/\(orderID)")
    }

    public static func directionsURL(_ s: WidgetShoot) -> URL? {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = "directions"
        var q: [URLQueryItem] = []
        if let lat = s.latitude, let lon = s.longitude {
            q.append(URLQueryItem(name: "lat", value: String(lat)))
            q.append(URLQueryItem(name: "lon", value: String(lon)))
        }
        if let a = s.address, !a.isEmpty { q.append(URLQueryItem(name: "address", value: a)) }
        guard !q.isEmpty else { return nil }   // nowhere to send Google Maps, so no button
        c.queryItems = q
        return c.url
    }

    /// What a tapped widget link asks the app to do.
    public enum Link: Equatable {
        case shoot(orderID: String)
        case directions(lat: Double?, lon: Double?, address: String?)
        case tonight
    }

    /// Opens the evening check (the Evening Check widget's tap).
    public static var tonightURL: URL? { URL(string: "\(urlScheme)://tonight") }

    public static func parse(_ url: URL) -> Link? {
        guard url.scheme == urlScheme, let host = url.host else { return nil }
        switch host {
        case "shoot":
            guard let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return nil }
            return .shoot(orderID: id)
        case "directions":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
            return .directions(lat: value("lat").flatMap(Double.init), lon: value("lon").flatMap(Double.init),
                               address: value("address"))
        case "tonight":
            return .tonight
        default:
            return nil
        }
    }
}

/// The widget's own saved copy of the last good fetch, so it still shows something without signal.
public struct WidgetCache: Codable {
    public let fetchedAt: Date
    public let shoots: [WidgetShoot]

    public init(fetchedAt: Date, shoots: [WidgetShoot]) {
        self.fetchedAt = fetchedAt
        self.shoots = shoots
    }

    public static func load(from url: URL) -> WidgetCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetCache.self, from: data)
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Live Activity (Lock Screen and Dynamic Island)

#if canImport(ActivityKit) && os(iOS)

/// The next shoot on the Lock Screen: where, and a countdown to when you need to leave.
/// The app starts it a few hours before you leave and keeps the drive time fresh while it's open.
public struct ShootActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// When to leave to be there 10 minutes early (Apple Maps drive time).
        public var leaveAt: Date
        public var start: Date
        /// "14 min drive"
        public var drive: String

        public init(leaveAt: Date, start: Date, drive: String) {
            self.leaveAt = leaveAt
            self.start = start
            self.drive = drive
        }
    }

    public var orderID: String
    public var street: String
    public var town: String
    public var agent: String

    public init(orderID: String, street: String, town: String, agent: String) {
        self.orderID = orderID
        self.street = street
        self.town = town
        self.agent = agent
    }
}
#endif
