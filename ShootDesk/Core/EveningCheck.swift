import Foundation

// The "evening check": looks at upcoming shoots and flags what would bite tomorrow.
// Runs whenever the app opens (and on the "Check again" button). No server needed.

public struct CheckIssue: Hashable, Identifiable {
    public enum Kind: String { case rain, wind, airspace, email, unscheduled, sunset }
    public let kind: Kind
    public let title: String
    public let detail: String
    public var id: String { kind.rawValue + title }
}

public struct CheckNote: Hashable, Identifiable {
    public let text: String
    public var id: String { text }
}

public struct CheckSuggestion: Hashable {
    public let date: Date
    public let reason: String
}

public struct CheckResult: Identifiable, Hashable {
    public let job: Job
    public let issues: [CheckIssue]
    public let notes: [CheckNote]
    public let suggestion: CheckSuggestion?
    public let weatherLine: String?
    /// False when a timed shoot's forecast couldn't be fetched (no signal, weather service down),
    /// so "no warnings" must not be read as "all clear".
    public var weatherChecked: Bool = true
    public var id: String { job.id }
    public var needsAttention: Bool { !issues.isEmpty }
}

/// Towered airports near the South Coast. Drone flights inside their controlled airspace need FAA approval.
/// New Bedford (EWB) position verified Oct 15, 2026; add others here as needed.
public struct Airport: Hashable {
    public let code: String
    public let name: String
    public let lat: Double
    public let lon: Double
    public let warnWithinMiles: Double

    public static let nearby: [Airport] = [
        Airport(code: "EWB", name: "New Bedford airport", lat: 41.67611, lon: -70.95694, warnWithinMiles: 5),
    ]
}

public enum EmailCheck {
    private static let badEndings = [".con", ".cmo", ".ocm", ".vom", ".xom", ".cpm", ".comm", ".coom", ".nett", ".ent"]
    private static let badDomains = ["gmial.", "gmai.", "gamil.", "gnail.", "gmal.", "hotmial.", "hotmal.", "yaho.", "yahooo.", "outlok.", "iclod.", "icoud."]

    /// Returns a plain-English problem, or nil if the address looks fine.
    public static func problem(_ email: String?) -> String? {
        guard let e = email?.trimmingCharacters(in: .whitespaces).lowercased(), !e.isEmpty else { return nil }
        if !e.contains("@") || e.hasPrefix("@") || e.hasSuffix("@") { return "isn't a complete email address" }
        if e.contains(" ") { return "has a space in it" }
        if let end = badEndings.first(where: { e.hasSuffix($0) }) { return "ends in “\(end)”" }
        if let d = badDomains.first(where: { e.contains("@" + $0) }) { return "looks misspelled (“\(d.dropLast())”)" }
        return nil
    }
}

public final class EveningCheck {
    public struct Settings {
        public var rainChanceLimit = 50
        public var droneWindLimitMph = 15
        public var droneGustLimitMph = 25
        public var workDays: Set<Int> = [2, 3, 4, 5, 6] // Mon–Fri (Calendar weekday numbers)
        public var lookAheadDays = 2
        public var quietDaysForWelcomeBack = 120
        public init() {}
    }

    private let weather: WeatherClient
    public var settings = Settings()

    public init(weather: WeatherClient) { self.weather = weather }

    /// Shoots that haven't started yet: the rest of today, then the look-ahead days after it
    /// (in Eastern time). Today counts so a morning shoot's warnings don't vanish at midnight.
    public func upcoming(_ jobs: [Job], now: Date = Date()) -> [Job] {
        let from = now
        let to = FieldTime.addDays(settings.lookAheadDays + 1, to: FieldTime.startOfDay(now))
        let timed = jobs.filter { j in
            guard let s = j.start, j.status == .booked else { return false }
            return s >= from && s < to
        }.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        return timed
    }

    public func run(jobs: [Job], customers: [CustomerStats], now: Date = Date()) async -> [CheckResult] {
        let targets = upcoming(jobs, now: now)
        var results: [CheckResult] = []
        var forecastCache: [String: Forecast] = [:]

        for job in targets {
            var issues: [CheckIssue] = []
            var notes: [CheckNote] = []
            var suggestion: CheckSuggestion?
            var weatherLine: String?
            // Only a forecast request that failed counts as "not checked"; an order with no time yet or
            // no map location has nothing to look up.
            var weatherChecked = job.start == nil || job.latitude == nil || job.longitude == nil

            if let problem = EmailCheck.problem(job.agentEmail) {
                issues.append(CheckIssue(kind: .email, title: "Agent email \(problem)",
                                         detail: "\(job.agentEmail ?? ""). The delivery email would bounce."))
            }

            if job.hasDrone, let lat = job.latitude, let lon = job.longitude {
                for a in Airport.nearby {
                    let d = Geo.miles(lat, lon, a.lat, a.lon)
                    if d <= a.warnWithinMiles {
                        issues.append(CheckIssue(kind: .airspace, title: String(format: "%.0f mi from %@", max(1, d.rounded()), a.name),
                                                 detail: "Controlled airspace. The drone needs FAA approval."))
                    }
                }
            }

            if let start = job.start, let end = job.end ?? job.start?.addingTimeInterval(3600),
               let lat = job.latitude, let lon = job.longitude {
                let key = String(format: "%.2f,%.2f", lat, lon)
                var fc = forecastCache[key]
                if fc == nil { fc = try? await weather.forecast(lat: lat, lon: lon); forecastCache[key] = fc }
                if let fc = fc {
                    weatherChecked = true
                    let hrs = fc.hours(from: start, to: end)
                    let rain = hrs.compactMap { $0.rainChance }.max() ?? 0
                    let wind = hrs.compactMap { $0.windMph }.max() ?? 0
                    let gust = fc.daytime(on: start)?.gustMph ?? 0
                    let temp = hrs.compactMap { $0.temperatureF }.max()
                    let summary = hrs.first?.summary ?? fc.daytime(on: start)?.summary ?? ""
                    weatherLine = [summary.isEmpty ? nil : summary.lowercased(), temp.map { "\($0)°" },
                                   wind > 0 ? "wind \(wind) mph" : nil].compactMap { $0 }.joined(separator: ", ")
                    if rain >= settings.rainChanceLimit {
                        let gustText = gust >= settings.droneGustLimitMph ? ", gusts to \(gust) mph" : ""
                        issues.append(CheckIssue(kind: .rain, title: "Rain during the shoot\(gustText)",
                                                 detail: "\(rain)% chance \(FieldTime.clockAMPM(start))–\(FieldTime.clockAMPM(end))"))
                    }
                    if job.hasDrone && (wind >= settings.droneWindLimitMph || gust >= settings.droneGustLimitMph)
                        && rain < settings.rainChanceLimit {
                        issues.append(CheckIssue(kind: .wind, title: "Too windy to fly",
                                                 detail: "Wind \(wind) mph\(gust > 0 ? ", gusts \(gust)" : "")"))
                    }
                    if rain >= settings.rainChanceLimit || (job.hasDrone && wind >= settings.droneWindLimitMph) {
                        suggestion = bestMove(for: job, jobs: jobs, forecast: fc, now: now)
                    }
                }
                if let sunset = Sun.sunset(on: start, lat: lat, lon: lon), end > sunset.addingTimeInterval(-15 * 60) {
                    issues.append(CheckIssue(kind: .sunset, title: "Runs into sunset",
                                             detail: "Sunset is \(FieldTime.clockAMPM(sunset)), the shoot ends \(FieldTime.clockAMPM(end))"))
                }
            }

            if let stats = customers.first(where: { $0.id == Rules.normalizedName(job.agentName) }) {
                let thisCreated = FieldTime.parse(job.order.createdAt) ?? now
                let previous = stats.orders
                    .filter { $0.id != job.order.id && ($0.totalAmount ?? 0) > 0 }
                    .compactMap { FieldTime.parse($0.createdAt) }
                    .filter { $0 < thisCreated }
                    .max()
                if stats.delivered == 0 {
                    notes.append(CheckNote(text: "New client, first order with you"))
                } else if let prev = previous {
                    let days = Int(thisCreated.timeIntervalSince(prev) / 86_400)
                    if days >= settings.quietDaysForWelcomeBack {
                        notes.append(CheckNote(text: "Back after \(days / 30) months, first order since \(FieldTime.format(prev, "MMM d"))"))
                    }
                }
                if !job.hasVideo, stats.delivered >= 4, stats.videoOrders * 2 >= stats.delivered {
                    notes.append(CheckNote(text: "Usually adds video (\(stats.videoOrders) of \(stats.delivered) orders), not on this one"))
                }
            }

            results.append(CheckResult(job: job, issues: issues, notes: notes, suggestion: suggestion,
                                       weatherLine: weatherLine, weatherChecked: weatherChecked))
        }
        return results
    }

    /// First work day in the forecast window with nothing booked and a dry daytime forecast.
    func bestMove(for job: Job, jobs: [Job], forecast: Forecast, now: Date) -> CheckSuggestion? {
        guard let start = job.start else { return nil }
        let cal = FieldTime.calendar
        let time = cal.dateComponents([.hour, .minute], from: start)
        for offset in 1...7 {
            let day = FieldTime.addDays(offset, to: FieldTime.startOfDay(start))
            guard settings.workDays.contains(cal.component(.weekday, from: day)) else { continue }
            guard let f = forecast.daytime(on: day) else { continue }
            let rain = f.rainChance ?? 0
            let gust = f.gustMph ?? 0
            if rain > 20 { continue }
            if job.hasDrone && gust >= settings.droneGustLimitMph { continue }
            if !JobBuilder.shoots(on: day, in: jobs).isEmpty { continue }
            guard let when = cal.date(bySettingHour: time.hour ?? 10, minute: time.minute ?? 0, second: 0, of: day) else { continue }
            var reason = "\(f.summary), \(rain)% rain"
            if gust > 0 { reason += ", gusts \(gust) mph" }
            reason += ", nothing else booked"
            return CheckSuggestion(date: when, reason: reason)
        }
        return nil
    }
}
