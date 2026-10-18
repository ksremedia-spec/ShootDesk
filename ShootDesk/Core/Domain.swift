import Foundation

// MARK: - Time helpers (everything shows in Eastern time)

public enum FieldTime {
    public static let zone = TimeZone(identifier: "America/New_York") ?? .current

    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func parse(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        return isoPlain.date(from: s) ?? isoFrac.date(from: s)
    }

    public static func iso(_ d: Date) -> String { isoPlain.string(from: d) }

    public static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = pattern
        return f.string(from: d)
    }

    /// "10:00", "12:15", "3:30"
    public static func clock(_ d: Date) -> String { format(d, "h:mm") }
    /// "10:00 AM"
    public static func clockAMPM(_ d: Date) -> String { format(d, "h:mm a") }
    /// "Wed, Oct 14"
    public static func dayLabel(_ d: Date) -> String { format(d, "EEE, MMM d") }

    public static func durationLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }

    public static func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }
    public static func addDays(_ n: Int, to d: Date) -> Date { calendar.date(byAdding: .day, value: n, to: d) ?? d }
    public static func isSameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }
}

public enum Money {
    /// Aryeo amounts are in cents.
    public static func dollars(_ cents: Int?) -> String {
        let c = cents ?? 0
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = c % 100 == 0 ? 0 : 2
        f.minimumFractionDigits = c % 100 == 0 ? 0 : 2
        return f.string(from: NSNumber(value: Double(c) / 100.0)) ?? "$\(c / 100)"
    }
}

// MARK: - Business rules (same rules as the Oct 8 dashboard run)

public enum Rules {
    /// Accounts that never count toward business numbers.
    /// "Jordan Rebello" is the App Review test account; Philip Rebello is a real client.
    public static let excludedCustomerNames: Set<String> = ["kyle silva", "jordan rebello"]

    public static func normalizedName(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "  ", with: " ")
    }

    public static func isExcluded(_ o: Order) -> Bool {
        if o.isGhost == true { return true }
        if [o.status, o.orderStatus].contains(where: { ($0 ?? "").uppercased() == "CANCELED" }) { return true }
        return excludedCustomerNames.contains(normalizedName(o.customer?.name))
    }

    /// Packages that include video. "Essentials Plus" (old and new names), "All In Lux" and anything
    /// with "video" or "cinematic" in the name. Matches the Oct 8 dashboard's video counts exactly.
    public static func hasVideo(_ o: Order) -> Bool {
        (o.items ?? []).contains { item in
            guard item.isCanceled != true else { return false }
            let t = (item.title ?? "").lowercased()
            return t.contains("video") || t.hasPrefix("essentials plus") || t.contains("all in lux") || t.contains("cinematic")
        }
    }

    /// Orders that include a floor plan (2D or 3D).
    public static func hasFloorPlan(_ o: Order) -> Bool {
        (o.items ?? []).contains { $0.isCanceled != true && ($0.title ?? "").lowercased().contains("floor plan") }
    }

    public static func hasDrone(_ o: Order) -> Bool {
        (o.items ?? []).contains { ($0.title ?? "").lowercased().contains("drone") && $0.isCanceled != true }
    }
}

// MARK: - Job: one shoot (an order and its appointment)

public enum JobStatus: String, Codable, CaseIterable {
    case booked, editing, delivered, unscheduled
    /// Older than 60 days and never delivered or canceled in Aryeo. Hidden from the main lists.
    case stale

    public var label: String {
        switch self {
        case .booked: return "Booked"
        case .editing: return "Shot"
        case .delivered: return "Delivered"
        case .unscheduled: return "Booked"
        case .stale: return "Never closed out"
        }
    }
}

public struct Job: Identifiable, Hashable {
    public let order: Order
    public let start: Date?
    public let end: Date?
    public let status: JobStatus

    public var id: String { order.id }
    public var number: Int { order.number ?? 0 }
    public var agentName: String { order.customer?.name ?? "Unknown agent" }
    public var agentPhone: String? { order.customer?.phone }
    public var agentEmail: String? { order.customer?.email }
    public var address: Address? { order.listing?.address }
    public var street: String {
        address?.unparsedAddressPartOne ?? address?.unparsedAddress?.components(separatedBy: ",").first ?? "Address missing"
    }
    public var town: String { address?.city ?? "" }
    public var townState: String {
        [address?.city, address?.stateOrProvince].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    public var latitude: Double? { address?.latitude }
    public var longitude: Double? { address?.longitude }
    public var items: [OrderItem] { (order.items ?? []).filter { $0.isCanceled != true } }
    public var images: [ListingImage] {
        (order.listing?.images ?? []).sorted { ($0.index ?? 0) < ($1.index ?? 0) }
    }
    /// The photo that fronts this shoot (its card, the top of its page, Present mode's opening card):
    /// the one Kyle picked, otherwise the first one Aryeo lists.
    public var coverImage: ListingImage? {
        let all = images
        if let pick = CoverChoice.imageID(for: id), let img = all.first(where: { $0.stableID == pick }) { return img }
        return all.first
    }
    public var heroURL: URL? {
        if let s = coverImage?.largeUrl ?? order.listing?.largeThumbnailUrl { return URL(string: s) }
        return nil
    }
    public var thumbURL: URL? {
        if let s = coverImage?.thumbnailUrl ?? order.listing?.thumbnailUrl { return URL(string: s) }
        return nil
    }
    public var durationMinutes: Int? {
        guard let s = start, let e = end else { return nil }
        return Int(e.timeIntervalSince(s) / 60)
    }
    public var timeRange: String {
        guard let s = start else { return "Not scheduled" }
        if let e = end { return "\(FieldTime.clock(s)) – \(FieldTime.clockAMPM(e))" }
        return FieldTime.clockAMPM(s)
    }
    /// Short human summary of what's being shot: "Photos, drone, 2D floor plan"
    public var packageSummary: String {
        let names = items.compactMap { $0.title }
        if names.isEmpty { return "No items" }
        return names.joined(separator: " + ")
    }
    public var adminURL: URL? { URL(string: "https://app.aryeo.com/admin/orders/\(order.id)/edit") }
    public var hasDrone: Bool { Rules.hasDrone(order) }
    public var hasVideo: Bool { Rules.hasVideo(order) }
    public var hasFloorPlan: Bool { Rules.hasFloorPlan(order) }
}

/// Which photo fronts each shoot, when Kyle has picked one. Order id → image id, kept on the phone.
/// Read on every card, so the list is held in memory and only written through when it changes.
public enum CoverChoice {
    private static let key = "coverChoices"
    private static var loaded: [String: String]?

    private static var all: [String: String] {
        if let loaded { return loaded }
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        loaded = saved
        return saved
    }

    public static func imageID(for orderID: String) -> String? { all[orderID] }

    /// Pass nil to go back to Aryeo's first photo.
    public static func set(_ imageID: String?, for orderID: String) {
        var next = all
        next[orderID] = imageID
        loaded = next
        UserDefaults.standard.set(next, forKey: key)
    }
}

public enum JobBuilder {
    /// Turns raw orders into shoots, applying the dashboard rules.
    public static func jobs(from orders: [Order], now: Date = Date()) -> [Job] {
        orders.compactMap { o -> Job? in
            if Rules.isExcluded(o) { return nil }
            let appt = (o.appointments ?? [])
                .filter { ($0.status ?? "").uppercased() != "CANCELED" }
                .sorted { ($0.startAt ?? "") < ($1.startAt ?? "") }
                .first
            let start = FieldTime.parse(appt?.startAt)
            let end = FieldTime.parse(appt?.endAt)
            // $0 orders with no shoot are placeholders; leave them out.
            if (o.totalAmount ?? 0) == 0 && start == nil { return nil }
            let status: JobStatus
            let staleBefore = now.addingTimeInterval(-60 * 86_400)
            if (o.fulfillmentStatus ?? "").uppercased() == "FULFILLED" {
                status = .delivered
            } else if let s = start {
                status = s > now ? .booked : (s < staleBefore ? .stale : .editing)
            } else {
                let created = FieldTime.parse(o.createdAt) ?? now
                status = created < staleBefore ? .stale : .unscheduled
            }
            return Job(order: o, start: start, end: end, status: status)
        }
    }

    public static func shoots(on day: Date, in jobs: [Job]) -> [Job] {
        jobs.filter { j in j.start.map { FieldTime.isSameDay($0, day) } ?? false }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }
}

// MARK: - Customer stats (computed live from orders)

public struct CustomerStats: Identifiable, Hashable {
    public let name: String
    public let phone: String?
    public let email: String?
    public let delivered: Int
    public let revenueCents: Int
    public let videoOrders: Int
    public let firstOrder: Date?
    public let lastOrder: Date?
    public let lastDelivered: Date?
    public let orders: [Order]

    public var id: String { Rules.normalizedName(name) }
    public var averageCents: Int { delivered == 0 ? 0 : revenueCents / delivered }
    public var initials: String {
        let parts = name.split(separator: " ")
        return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    public func daysSinceLastOrder(now: Date = Date()) -> Int? {
        guard let l = lastOrder else { return nil }
        return Int(now.timeIntervalSince(l) / 86_400)
    }

    public enum Group: String { case active, lapsed, occasional, new }

    /// Same buckets as the dashboard: active = ordered in the last 90 days,
    /// lapsed = 3+ delivered orders and quiet 90+ days, new = nothing delivered yet.
    public func group(now: Date = Date()) -> Group {
        if delivered == 0 { return .new }
        let days = daysSinceLastOrder(now: now) ?? 9_999
        if days < 90 { return .active }
        return delivered >= 3 ? .lapsed : .occasional
    }
}

public enum StatsBuilder {
    public static func customers(from orders: [Order]) -> [CustomerStats] {
        var groups: [String: [Order]] = [:]
        for o in orders where !Rules.isExcluded(o) {
            let key = Rules.normalizedName(o.customer?.name)
            if key.isEmpty { continue }
            groups[key, default: []].append(o)
        }
        return groups.values.map { list in
            let counted = list.filter { ($0.totalAmount ?? 0) > 0 }
            let delivered = counted.filter { ($0.fulfillmentStatus ?? "").uppercased() == "FULFILLED" }
            let created = counted.compactMap { FieldTime.parse($0.createdAt) }
            let deliveredDates = delivered.compactMap { FieldTime.parse($0.createdAt) }
            let newestFirst = list.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            let withContact = newestFirst.first { $0.customer?.phone != nil } ?? newestFirst.first
            return CustomerStats(
                name: newestFirst.first?.customer?.name ?? "Unknown",
                phone: withContact?.customer?.phone,
                email: newestFirst.first?.customer?.email,
                delivered: delivered.count,
                revenueCents: delivered.reduce(0) { $0 + ($1.totalAmount ?? 0) },
                videoOrders: delivered.filter { Rules.hasVideo($0) }.count,
                firstOrder: created.min(),
                lastOrder: created.max(),
                lastDelivered: deliveredDates.max(),
                orders: newestFirst
            )
        }
        .sorted { ($0.lastOrder ?? .distantPast) > ($1.lastOrder ?? .distantPast) }
    }
}

public enum Phone {
    /// "+15089895326" -> "(508) 989-5326"
    public static func pretty(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        var digits = raw.filter { $0.isNumber }
        if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst() }
        guard digits.count == 10 else { return raw }
        let a = digits.prefix(3), b = digits.dropFirst(3).prefix(3), c = digits.suffix(4)
        return "(\(a)) \(b)-\(c)"
    }

    public static func dialURL(_ raw: String?) -> URL? {
        guard let raw = raw else { return nil }
        let digits = raw.filter { $0.isNumber || $0 == "+" }
        return URL(string: "tel:\(digits)")
    }

    public static func textURL(_ raw: String?, body: String? = nil) -> URL? {
        guard let raw = raw else { return nil }
        let digits = raw.filter { $0.isNumber || $0 == "+" }
        var s = "sms:\(digits)"
        if let body = body, let enc = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            s += "&body=\(enc)"
        }
        return URL(string: s)
    }
}

public enum Directions {
    /// Opens the Google Maps app if installed (comgooglemaps://), otherwise Google Maps on the web.
    public static func googleMapsAppURL(lat: Double?, lon: Double?, address: String?) -> URL? {
        if let lat = lat, let lon = lon {
            return URL(string: "comgooglemaps://?daddr=\(lat),\(lon)&directionsmode=driving")
        }
        guard let a = address?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "comgooglemaps://?daddr=\(a)&directionsmode=driving")
    }

    public static func googleMapsWebURL(lat: Double?, lon: Double?, address: String?) -> URL? {
        let dest: String
        if let lat = lat, let lon = lon { dest = "\(lat),\(lon)" }
        else if let a = address?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { dest = a }
        else { return nil }
        return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(dest)&travelmode=driving")
    }
}
