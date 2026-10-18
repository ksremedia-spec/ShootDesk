import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum FieldError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let which): return "Add your \(which) key in Settings."
        case .http(let code, let body): return "Server said \(code). \(body.prefix(200))"
        case .badResponse(let why): return why
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        return URLSession(configuration: c)
    }()

    /// Per-request time limit override. The widget sets a short one so weak signal can't stall it.
    nonisolated(unsafe) static var timeout: TimeInterval?

    static func data(_ request: URLRequest) async throws -> Data {
        var req = request
        if let t = timeout { req.timeoutInterval = t }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FieldError.badResponse("No response") }
        guard (200..<300).contains(http.statusCode) else {
            throw FieldError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

// MARK: - Aryeo (read-only)

public final class AryeoClient {
    private let key: String
    private let base = URL(string: "https://api.aryeo.com/v1")!

    public init(key: String) { self.key = key }

    private func request(_ path: String, _ query: [URLQueryItem]) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        var r = URLRequest(url: comps.url!)
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// One page of orders, newest first, with everything the app shows embedded.
    public func ordersPage(_ page: Int, perPage: Int = 100) async throws -> AryeoPage<Order> {
        let req = request("orders", [
            URLQueryItem(name: "include", value: "customer,listing,appointments,items"),
            URLQueryItem(name: "sort", value: "-created_at"),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page)),
        ])
        let data = try await HTTP.data(req)
        return try AryeoJSON.decoder().decode(AryeoPage<Order>.self, from: data)
    }

    /// Every order on the account (about 9 requests for ~850 orders).
    public func allOrders(maxPages: Int = 60) async throws -> [Order] {
        var out: [Order] = []
        var page = 1
        while page <= maxPages {
            let p = try await ordersPage(page)
            out += p.data
            let last = p.meta?.lastPage ?? page
            if p.data.isEmpty || page >= last { break }
            page += 1
        }
        return out
    }

    /// Just the newest orders, for a quick refresh between full syncs.
    public func recentOrders(count: Int = 100) async throws -> [Order] {
        try await ordersPage(1, perPage: count).data
    }

    /// Photos, videos and floor plans for one listing (one request).
    public func listingMedia(listingID: String) async throws -> ListingMedia {
        let req = request("listings/\(listingID)", [
            URLQueryItem(name: "include", value: "images,videos,floor_plans"),
        ])
        struct DTO: Decodable {
            let images: [ListingImage]?
            let videos: [ListingVideo]?
            let floorPlans: [FloorPlan]?
        }
        let data = try await HTTP.data(req)
        let d = try AryeoJSON.decoder().decode(AryeoItem<DTO>.self, from: data).data
        return ListingMedia(images: d.images ?? [], videos: d.videos ?? [], floorPlans: d.floorPlans ?? [])
    }

    /// Appointments starting between two times, each with its order, agent, items and address.
    /// One small request (about 1 second); the widget uses this so it never needs the full order history.
    public func appointments(from: Date, to: Date, perPage: Int = 100) async throws -> [ScheduledAppointment] {
        let req = request("appointments", [
            URLQueryItem(name: "filter[start_at_gte]", value: FieldTime.iso(from)),
            URLQueryItem(name: "filter[start_at_lte]", value: FieldTime.iso(to)),
            URLQueryItem(name: "include", value: "order,order.customer,order.items,order.listing"),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ])
        let data = try await HTTP.data(req)
        return try AryeoJSON.decoder().decode(AryeoPage<ScheduledAppointment>.self, from: data).data
    }
}

/// An appointment as the appointments endpoint returns it: the time plus the order it belongs to.
public struct ScheduledAppointment: Codable, Hashable {
    public let id: String?
    public let title: String?
    public let startAt: String?
    public let endAt: String?
    public let duration: Int?
    public let status: String?
    public let order: Order?

    public var appointment: Appointment {
        Appointment(id: id, title: title, description: nil, startAt: startAt, endAt: endAt, duration: duration, status: status)
    }
}

// MARK: - Claude

public struct ClaudeBlock: Encodable {
    public let type: String
    public let text: String?
    public let source: ImageSource?

    public struct ImageSource: Encodable {
        public let type: String
        public let url: String
    }

    public static func text(_ s: String) -> ClaudeBlock { ClaudeBlock(type: "text", text: s, source: nil) }
    public static func image(url: String) -> ClaudeBlock {
        ClaudeBlock(type: "image", text: nil, source: ImageSource(type: "url", url: url))
    }

    enum CodingKeys: String, CodingKey { case type, text, source }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(source, forKey: .source)
    }
}

public struct ClaudeMessage: Encodable {
    public let role: String
    public let content: [ClaudeBlock]
    public init(role: String, content: [ClaudeBlock]) { self.role = role; self.content = content }
    public static func user(_ blocks: [ClaudeBlock]) -> ClaudeMessage { ClaudeMessage(role: "user", content: blocks) }
    public static func assistant(_ text: String) -> ClaudeMessage { ClaudeMessage(role: "assistant", content: [.text(text)]) }
}

public final class ClaudeClient {
    /// Model names verified on Anthropic's API reference, Oct 15, 2026.
    public static let smart = "claude-opus-5-5"
    public static let fast = "claude-opus-5-5"   // Kyle chose Opus 5.5 for everything

    /// The most Opus 5.5 can write in one answer (128K tokens, per Anthropic's model page, Oct 15 2026).
    /// You're only billed for what it actually writes.
    public static let maxOutput = 128_000

    private let key: String
    public init(key: String) { self.key = key }

    private struct Body: Encodable {
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [ClaudeMessage]
        var stream: Bool? = nil
    }

    /// Long answers stream in, so there's no overall time limit; it only gives up after 2 minutes of silence.
    private static let streamSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()
    private struct Reply: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
        let stop_reason: String?
    }

    public func send(model: String = ClaudeClient.smart, system: String?, messages: [ClaudeMessage],
                     maxTokens: Int = ClaudeClient.maxOutput,
                     onText: (@Sendable (String) -> Void)? = nil) async throws -> String {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONEncoder().encode(Body(model: model, max_tokens: maxTokens, system: system,
                                                   messages: messages, stream: true))
        let (bytes, resp) = try await Self.streamSession.bytes(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw FieldError.http(code, body)
        }
        var text = ""
        var stop: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = json.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    text += t
                    onText?(text)
                }
            case "message_delta":
                stop = (obj["delta"] as? [String: Any])?["stop_reason"] as? String
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Claude stopped with an error"
                throw FieldError.badResponse(msg)
            default:
                break
            }
        }
        if text.isEmpty { throw FieldError.badResponse("Claude returned no text (\(stop ?? "unknown"))") }
        return text
    }
}

// MARK: - Weather (National Weather Service, free, US only)

public struct HourForecast: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let temperatureF: Int?
    public let windMph: Int?
    public let rainChance: Int?
    public let summary: String
}

public struct DayForecast: Hashable, Sendable {
    public let name: String
    public let start: Date
    public let isDaytime: Bool
    public let rainChance: Int?
    public let summary: String
    public let detail: String
    /// Parsed from "gusts as high as 30 mph" in the written forecast.
    public let gustMph: Int?
}

public struct Forecast: Sendable {
    public let hours: [HourForecast]
    public let days: [DayForecast]

    public func hours(from a: Date, to b: Date) -> [HourForecast] {
        hours.filter { $0.end > a && $0.start < b }
    }
    public func daytime(on day: Date) -> DayForecast? {
        days.first { $0.isDaytime && FieldTime.isSameDay($0.start, day) }
    }
}

/// An actor so the evening check and a stop's forecast can run at the same time safely.
public actor WeatherClient {
    /// NWS asks every app to identify itself.
    private let userAgent = "ShootDesk/1.0 (Horizon Home Media personal app)"
    private var pointCache: [String: (hourly: URL, daily: URL)] = [:]

    public init() {}

    private func get(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        return try await HTTP.data(r)
    }

    private struct Points: Decodable {
        struct P: Decodable { let forecast: String; let forecastHourly: String }
        let properties: P
    }
    private struct Periods: Decodable {
        struct P: Decodable {
            struct Prob: Decodable { let value: Int? }
            let name: String?
            let startTime: String
            let endTime: String
            let isDaytime: Bool?
            let temperature: Int?
            let windSpeed: String?
            let shortForecast: String?
            let detailedForecast: String?
            let probabilityOfPrecipitation: Prob?
        }
        struct Props: Decodable { let periods: [P] }
        let properties: Props
    }

    public func forecast(lat: Double, lon: Double) async throws -> Forecast {
        let k = String(format: "%.3f,%.3f", lat, lon)
        let urls: (hourly: URL, daily: URL)
        if let cached = pointCache[k] { urls = cached } else {
            let pData = try await get(URL(string: "https://api.weather.gov/points/\(String(format: "%.4f", lat)),\(String(format: "%.4f", lon))")!)
            let p = try JSONDecoder().decode(Points.self, from: pData).properties
            guard let h = URL(string: p.forecastHourly), let d = URL(string: p.forecast) else {
                throw FieldError.badResponse("Weather service gave no forecast link")
            }
            urls = (h, d)
            pointCache[k] = urls
        }
        let hData = try await get(urls.hourly)
        let dData = try await get(urls.daily)
        let hp = try JSONDecoder().decode(Periods.self, from: hData).properties.periods
        let dp = try JSONDecoder().decode(Periods.self, from: dData).properties.periods
        let hours = hp.compactMap { p -> HourForecast? in
            guard let s = FieldTime.parse(p.startTime), let e = FieldTime.parse(p.endTime) else { return nil }
            return HourForecast(start: s, end: e, temperatureF: p.temperature, windMph: WeatherClient.mph(p.windSpeed),
                                rainChance: p.probabilityOfPrecipitation?.value, summary: p.shortForecast ?? "")
        }
        let days = dp.compactMap { p -> DayForecast? in
            guard let s = FieldTime.parse(p.startTime) else { return nil }
            return DayForecast(name: p.name ?? "", start: s, isDaytime: p.isDaytime ?? true,
                               rainChance: p.probabilityOfPrecipitation?.value, summary: p.shortForecast ?? "",
                               detail: p.detailedForecast ?? "", gustMph: WeatherClient.gust(p.detailedForecast))
        }
        return Forecast(hours: hours, days: days)
    }

    /// "8 to 17 mph" -> 17, "14 mph" -> 14
    static func mph(_ s: String?) -> Int? {
        guard let s = s else { return nil }
        return s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.max()
    }

    static func gust(_ s: String?) -> Int? {
        guard let s = s?.lowercased(), let r = s.range(of: "gusts as high as ") else { return nil }
        let tail = s[r.upperBound...]
        return Int(tail.prefix { $0.isNumber })
    }
}

// MARK: - Town property records (MassGIS statewide assessor parcels, Massachusetts only)

public struct PropertyFacts: Hashable {
    public let livingAreaSqFt: Int?
    public let yearBuilt: Int?
    public let lotSize: Double?
    public let lotUnits: String?
    public let style: String?
    public let rooms: Int?
    public let stories: String?
    public let use: String?
    public let fiscalYear: Int?

    public var lotLabel: String? {
        guard let lot = lotSize, lot > 0 else { return nil }
        let units = (lotUnits ?? "").lowercased()
        if units.contains("acre") { return String(format: "%.2f acres", lot) }
        if units.contains("sq") {
            let acres = lot / 43_560
            return acres >= 0.25 ? String(format: "%.2f acres", acres) : "\(Int(lot)) sq ft lot"
        }
        return String(format: "%.2f %@", lot, lotUnits ?? "")
    }
}

public final class PropertyRecordsClient {
    public init() {}

    private struct Reply: Decodable {
        struct F: Decodable { let attributes: A }
        struct A: Decodable {
            let RES_AREA: Double?
            let YEAR_BUILT: Double?
            let LOT_SIZE: Double?
            let LOT_UNITS: String?
            let STYLE: String?
            let NUM_ROOMS: Double?
            let STORIES: String?
            let USE_DESC: String?
            let FY: Double?
        }
        let features: [F]?
    }

    /// Looks up the parcel under a map point. Returns nil outside Massachusetts or when nothing matches.
    public func facts(lat: Double, lon: Double) async throws -> PropertyFacts? {
        var comps = URLComponents(string: "https://services1.arcgis.com/hGdibHYSPO59RG1h/ArcGIS/rest/services/Massachusetts_Property_Tax_Parcels/FeatureServer/0/query")!
        comps.queryItems = [
            URLQueryItem(name: "geometry", value: "\(lon),\(lat)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "RES_AREA,YEAR_BUILT,LOT_SIZE,LOT_UNITS,STYLE,NUM_ROOMS,STORIES,USE_DESC,FY"),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "f", value: "json"),
        ]
        let data = try await HTTP.data(URLRequest(url: comps.url!))
        guard let a = try JSONDecoder().decode(Reply.self, from: data).features?.first?.attributes else { return nil }
        func int(_ d: Double?) -> Int? { d.flatMap { $0 > 0 ? Int($0) : nil } }
        return PropertyFacts(livingAreaSqFt: int(a.RES_AREA), yearBuilt: int(a.YEAR_BUILT), lotSize: a.LOT_SIZE,
                             lotUnits: a.LOT_UNITS, style: a.STYLE, rooms: int(a.NUM_ROOMS), stories: a.STORIES,
                             use: a.USE_DESC, fiscalYear: int(a.FY))
    }
}

// MARK: - Sun (NOAA sunrise/sunset approximation, accurate to about a minute)

public enum Sun {
    /// Sunset for the given local day at a location. `zenith` 90.833 = sunset, 96 = end of civil dusk.
    public static func sunset(on day: Date, lat: Double, lon: Double, zenith: Double = 90.833) -> Date? {
        let cal = FieldTime.calendar
        guard let n = cal.ordinality(of: .day, in: .year, for: day) else { return nil }
        let lngHour = lon / 15
        let t = Double(n) + (18 - lngHour) / 24
        let M = 0.9856 * t - 3.289
        var L = M + 1.916 * sin(rad(M)) + 0.020 * sin(rad(2 * M)) + 282.634
        L = L.truncatingRemainder(dividingBy: 360); if L < 0 { L += 360 }
        var RA = deg(atan(0.91764 * tan(rad(L))))
        RA = RA.truncatingRemainder(dividingBy: 360); if RA < 0 { RA += 360 }
        RA = (RA + (floor(L / 90) * 90 - floor(RA / 90) * 90)) / 15
        let sinDec = 0.39782 * sin(rad(L))
        let cosDec = cos(asin(sinDec))
        let cosH = (cos(rad(zenith)) - sinDec * sin(rad(lat))) / (cosDec * cos(rad(lat)))
        if cosH < -1 || cosH > 1 { return nil }
        let H = deg(acos(cosH)) / 15
        let T = H + RA - 0.06571 * t - 6.622
        var UT = (T - lngHour).truncatingRemainder(dividingBy: 24); if UT < 0 { UT += 24 }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: day)
        guard let midnightUTC = utc.date(from: comps) else { return nil }
        var result = midnightUTC.addingTimeInterval(UT * 3600)
        // Evening sunsets in the US land after midnight UTC; keep the result on the requested local day.
        if !FieldTime.isSameDay(result, day) {
            result = result.addingTimeInterval(result < day ? 86_400 : -86_400)
        }
        // Round to the nearest minute.
        let rounded = (result.timeIntervalSinceReferenceDate / 60).rounded() * 60
        return Date(timeIntervalSinceReferenceDate: rounded)
    }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }
}

// MARK: - Distance

public enum Geo {
    public static func miles(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 3958.8
        let dLat = (lat2 - lat1) * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}
