import AppIntents
import CoreLocation
import Foundation
import MapKit
import SwiftUI

// Booking a shoot from Siri. This is the one part of ShootDesk that WRITES to Aryeo:
// it saves the address, creates the order with the package, then books the appointment.
// Siri always reads the whole booking back and waits for a yes before any of that happens.

enum BookingError: LocalizedError {
    case noKey, notFound(String), clash(String), aryeo(Int, String), partial(Int, String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Aryeo key in ShootDesk's Settings first."
        case .notFound(let s): return s
        case .clash(let s): return s
        case .aryeo(let code, let msg): return "Aryeo said no (\(code)): \(msg)"
        case .partial(let n, let msg):
            return "Order #\(n) was created, but booking the time failed: \(msg). Open it in Aryeo to schedule it."
        }
    }
}

/// A place Apple Maps found, broken into the parts Aryeo wants.
struct FoundPlace: Hashable {
    let number: String
    let street: String
    let city: String
    let state: String
    let zip: String
    let country: String
    let lat: Double
    let lon: Double
    var line: String { "\(number) \(street), \(city)" }
}

struct Package: Hashable {
    let variantID: String
    let product: String
    let variant: String
    let priceCents: Int
    let minutes: Int
    var title: String {
        variant.isEmpty || variant.caseInsensitiveCompare(product) == .orderedSame ? product : "\(product) (\(variant))"
    }
}

struct BookedShoot {
    let orderID: String
    let number: Int
    let start: Date
    let end: Date
}

enum Booker {
    // MARK: Shorthand

    /// "9 Radcliffe Ln." → "9 radcliffe lane": lowercase, no punctuation, street words spelled out.
    static func normalize(_ s: String) -> String {
        let spelled = ["ln": "lane", "st": "street", "rd": "road", "ave": "avenue", "av": "avenue", "dr": "drive",
                       "cir": "circle", "ct": "court", "blvd": "boulevard", "pl": "place", "ter": "terrace",
                       "hwy": "highway", "pt": "point", "pkwy": "parkway", "sq": "square", "tpke": "turnpike",
                       "n": "north", "s": "south", "e": "east", "w": "west", "mt": "mount", "ext": "extension"]
        let cleaned = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").map { spelled[String($0)] ?? String($0) }.joined(separator: " ")
    }

    /// True when every word typed (or its start, for 3+ letters) is found in the text: "tiff" ↔ "Tiffany Smith".
    static func loosely(_ query: String, matches text: String) -> Bool {
        let words = normalize(text).split(separator: " ")
        return normalize(query).split(separator: " ").allSatisfy { q in
            words.contains { w in w == q || (q.count >= 3 && w.hasPrefix(q)) }
        }
    }

    /// Package shorthand: "EP" → Essentials Plus (initials), "essentials" → Essentials Plus.
    static func packageMatches(_ query: String, _ p: Package) -> Bool {
        let q = normalize(query).replacingOccurrences(of: " ", with: "")
        let initials = normalize(p.product).split(separator: " ").compactMap(\.first).map(String.init).joined()
        return loosely(query, matches: p.title) || (q.count >= 2 && q == initials)
    }

    // MARK: Finding the address

    /// Where you work: Apple Maps prefers matches near here when a town is left out.
    static let home = CLLocationCoordinate2D(latitude: 41.64, longitude: -70.95)

    /// Every distinct place the shorthand could mean, best first, from Apple Maps around the
    /// South Coast (within about 60 miles). These are new listings, so past shoots aren't checked.
    static func places(for text: String) async -> [FoundPlace] {
        var out: [FoundPlace] = []
        for p in await mapsSearch(text) where !out.contains(where: { $0.line == p.line }) { out.append(p) }
        return out
    }

    private static func mapsSearch(_ query: String) async -> [FoundPlace] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.resultTypes = .address
        req.region = MKCoordinateRegion(center: home, span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2))
        guard let items = try? await MKLocalSearch(request: req).start().mapItems else { return [] }
        let base = CLLocation(latitude: home.latitude, longitude: home.longitude)
        return items.compactMap { item -> FoundPlace? in
            let pm = item.placemark
            guard let number = pm.subThoroughfare, let street = pm.thoroughfare, let city = pm.locality else { return nil }
            let c = pm.coordinate
            guard CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: base) < 100_000 else { return nil }
            return FoundPlace(number: number, street: street, city: city, state: pm.administrativeArea ?? "MA",
                              zip: pm.postalCode ?? "", country: pm.isoCountryCode ?? "US", lat: c.latitude, lon: c.longitude)
        }
    }

    // MARK: Agents

    /// Agents your shorthand could mean ("Tiff", "Tiffany", "Smith").
    static func agents(matching text: String, in all: [CustomerStats]) -> [CustomerStats] {
        all.filter { loosely(text, matches: $0.name) }.sorted { $0.delivered > $1.delivered }
    }

    /// The agent's Aryeo customer ID, from their newest order.
    static func customerID(for agent: CustomerStats) -> String? {
        agent.orders.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }.compactMap { $0.customer?.id }.first
    }

    // MARK: Packages

    @MainActor private static var packageCache: (at: Date, list: [Package])?

    /// Your bookable packages (main products only), one entry per size/variant.
    @MainActor
    static func packages(key: String) async throws -> [Package] {
        if let c = packageCache, Date().timeIntervalSince(c.at) < 600 { return c.list }
        var list: [Package] = []
        for page in 1...4 {
            let json = try await send("GET", "products", query: [
                URLQueryItem(name: "filter[type]", value: "MAIN"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
            ], key: key)
            let data = json["data"] as? [[String: Any]] ?? []
            for p in data where (p["active"] as? Bool) != false {
                let title = p["title"] as? String ?? ""
                for v in p["variants"] as? [[String: Any]] ?? [] {
                    guard let id = v["id"] as? String else { continue }
                    list.append(Package(variantID: id, product: title, variant: v["title"] as? String ?? "",
                                        priceCents: v["price_amount"] as? Int ?? v["price"] as? Int ?? 0,
                                        minutes: v["duration"] as? Int ?? 0))
                }
            }
            if data.count < 100 { break }
        }
        packageCache = (Date(), list)
        return list
    }

    // MARK: Clash check

    /// Anything already booked within 30 minutes either side of the proposed time.
    static func clash(start: Date, end: Date, key: String) async -> String? {
        let cal = FieldTime.calendar
        let from = cal.startOfDay(for: start), to = FieldTime.addDays(1, to: from)
        guard let list = try? await AryeoClient(key: key).appointments(from: from, to: to) else { return nil }
        let pad: TimeInterval = 30 * 60
        for a in list where (a.status ?? "").uppercased() != "CANCELED" {
            guard let s = FieldTime.parse(a.startAt) else { continue }
            let e = FieldTime.parse(a.endAt) ?? s.addingTimeInterval(3600)
            if s < end.addingTimeInterval(pad) && e > start.addingTimeInterval(-pad) {
                let street = a.order?.listing?.address?.unparsedAddressPartOne ?? a.title ?? "another shoot"
                return "That's too close to \(street) at \(FieldTime.clockAMPM(s)). I left 30 minutes either side for driving."
            }
        }
        return nil
    }

    // MARK: Booking

    /// Creates the address, the order (with the package) and the appointment. `notify` sends Aryeo's
    /// normal confirmation email to the agent.
    static func book(customerID: String, place: FoundPlace, package: Package, start: Date,
                     notify: Bool, key: String) async throws -> BookedShoot {
        let minutes = package.minutes > 0 ? package.minutes : 90
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))

        let address = try await send("POST", "addresses", body: [
            "latitude": place.lat, "longitude": place.lon,
            "street_number": place.number, "street_name": place.street,
            "city": place.city, "state_or_province": place.state,
            "postal_code": place.zip, "country": place.country,
        ], key: key)
        guard let addressID = (address["data"] as? [String: Any])?["id"] as? String else {
            throw BookingError.aryeo(0, "no address ID came back")
        }

        let order = try await send("POST", "orders", body: [
            "customer_id": customerID, "address_id": addressID,
            "product_items": [["variant_id": package.variantID, "quantity": 1]],
            "notify": notify,
        ], key: key)
        guard let o = order["data"] as? [String: Any], let orderID = o["id"] as? String else {
            throw BookingError.aryeo(0, "no order ID came back")
        }
        let number = o["number"] as? Int ?? 0

        do {
            let full = try await send("GET", "orders/\(orderID)", query: [URLQueryItem(name: "include", value: "items")], key: key)
            let items = ((full["data"] as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            _ = try await send("POST", "appointments/store", body: [
                "order_id": orderID,
                "start_at": FieldTime.iso(start), "end_at": FieldTime.iso(end),
                "item_ids": items,
                "notify": notify,
            ], key: key)
        } catch {
            throw BookingError.partial(number, error.localizedDescription)
        }
        return BookedShoot(orderID: orderID, number: number, start: start, end: end)
    }

    /// Finds an Aryeo customer by name through the API (used for the test booking, since your own
    /// name is left out of the agent list).
    static func customerID(named name: String, key: String) async throws -> String? {
        let json = try await send("GET", "customers", query: [URLQueryItem(name: "filter[name]", value: name)], key: key)
        return (json["data"] as? [[String: Any]])?.first?["id"] as? String
    }

    private static func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                             body: [String: Any]? = nil, key: String) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://api.aryeo.com/v1/" + path)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            var msg = json["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            if let errs = json["errors"] as? [String: [String]] {
                msg += " " + errs.map { "\($0.key): \($0.value.joined(separator: ", "))" }.joined(separator: "; ")
            }
            throw BookingError.aryeo(code, msg)
        }
        return json
    }
}

// MARK: - Siri

struct PackageEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Package"
    static let defaultQuery = PackageQuery()

    let id: String
    let package: Package

    init(_ p: Package) { id = p.variantID; package = p }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(package.title)", subtitle: "\(Money.dollars(package.priceCents))")
    }
}

struct PackageQuery: EntityStringQuery {
    @MainActor private func all() async throws -> [Package] {
        let key = Keychain.get(KeyName.aryeo)
        guard !key.isEmpty else { return [] }
        return try await Booker.packages(key: key)
    }
    func entities(for identifiers: [String]) async throws -> [PackageEntity] {
        try await all().filter { identifiers.contains($0.variantID) }.map(PackageEntity.init)
    }
    func entities(matching string: String) async throws -> [PackageEntity] {
        try await all().filter { Booker.packageMatches(string, $0) }.map(PackageEntity.init)
    }
    func suggestedEntities() async throws -> [PackageEntity] {
        try await all().map(PackageEntity.init)
    }
}

struct BookShootIntent: AppIntent {
    static let title: LocalizedStringResource = "Book a Shoot"
    static let description = IntentDescription(
        "Books a shoot in Aryeo for an agent: the address, the package and the time. Reads it all back and waits for your yes first, and Aryeo emails the agent its usual confirmation.")

    @Parameter(title: "Agent") var agent: AgentEntity
    @Parameter(title: "Day and time") var start: Date
    @Parameter(title: "Package") var package: PackageEntity
    @Parameter(title: "Address", requestValueDialog: "What's the property address?") var address: String

    static var parameterSummary: some ParameterSummary {
        Summary("Book \(\.$agent) for \(\.$package) at \(\.$address) on \(\.$start)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let key = Keychain.get(KeyName.aryeo)
        guard !key.isEmpty else { throw BookingError.noKey }
        guard start > Date() else { throw BookingError.notFound("That time has already passed.") }

        guard let stats = await SiriData.customers().first(where: { $0.id == agent.id }),
              let customerID = Booker.customerID(for: stats) else {
            throw BookingError.notFound("I couldn't find \(agent.name) in Aryeo.")
        }

        // Shorthand address → a real one. More than one town? Ask.
        let matches = await Booker.places(for: address)
        guard !matches.isEmpty else {
            throw BookingError.notFound("I couldn't find \(address) near the South Coast. Try adding the town.")
        }
        var place = matches[0]
        if matches.count > 1 {
            let picked = try await $address.requestDisambiguation(among: matches.prefix(4).map(\.line),
                                                                  dialog: "Which one?")
            place = matches.first { $0.line == picked } ?? place
        }

        let p = package.package
        let end = start.addingTimeInterval(TimeInterval((p.minutes > 0 ? p.minutes : 90) * 60))
        if let clash = await Booker.clash(start: start, end: end, key: key) { throw BookingError.clash(clash) }

        let when = "\(FieldTime.format(start, "EEEE MMM d")) at \(FieldTime.clockAMPM(start))"
        let first = stats.name.split(separator: " ").first.map(String.init) ?? stats.name
        try await requestConfirmation(result: .result(dialog:
            "Book \(stats.name) for \(p.title), \(Money.dollars(p.priceCents)), at \(place.line), \(when)? Aryeo will email \(first) a confirmation."))

        let booked = try await Booker.book(customerID: customerID, place: place, package: p, start: start, notify: true, key: key)
        Task { await SiriData.live?.refresh() }
        return .result(dialog: "Booked. Order \(booked.number), \(place.line), \(when). \(first) is getting the confirmation.")
    }
}

// MARK: - Booking from the app

/// Book a shoot without leaving ShootDesk: agent, address, package, then a time that's actually open.
/// Nothing is sent to Aryeo until you confirm the summary.
struct BookShootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var size

    @State private var agentQuery = ""
    @State private var agent: CustomerStats?
    @State private var addressQuery = ""
    @State private var places: [FoundPlace] = []
    @State private var searching = false
    @State private var place: FoundPlace?
    @State private var packages: [Package] = []
    @State private var packageError: String?
    @State private var package: Package?
    @State private var day = FieldTime.startOfDay(Date())
    @State private var time: Date?
    @State private var confirming = false
    @State private var working = false
    @State private var problem: String?
    @State private var booked: BookedShoot?

    init(agent: CustomerStats? = nil) {
        _agent = State(initialValue: agent)
    }

    private var minutes: Int { package.map { $0.minutes > 0 ? $0.minutes : 90 } ?? 90 }
    private var ready: Bool { agent != nil && place != nil && package != nil && time != nil }

    var body: some View {
        NavigationStack {
            Group {
                if let booked { doneView(booked) } else { form }
            }
            .background(Color(.systemBackground))
            .slimBar("Book a shoot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(booked == nil ? "Cancel" : "Done") { dismiss() } }
            }
            .task { await loadPackages() }
            .confirmationDialog(confirmText, isPresented: $confirming, titleVisibility: .visible) {
                Button("Book it") { Task { await book() } }
                Button("Not yet", role: .cancel) {}
            }
            // A thump the moment "Book it" is pressed, then the success tap when Aryeo confirms.
            .sensoryFeedback(.impact(weight: .medium), trigger: working) { was, now in !was && now }
            .sensoryFeedback(.success, trigger: booked != nil) { _, done in done }
        }
    }

    // MARK: Steps

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if size == .regular {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 30) { agentStep; addressStep }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 30) { packageStep; timeStep }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    agentStep; addressStep; packageStep; timeStep
                }
                summary
            }
            .padding(.horizontal, Gutter.of(size))
            .padding(.vertical, 18)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func stepTitle(_ n: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(done ? Theme.accent : Theme.surface).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
            }
            Text(title).font(.address(.title3))
        }
    }

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(1, "Agent", done: agent != nil)
            if let a = agent {
                HStack(spacing: 12) {
                    Monogram(name: a.name, initials: a.initials, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.headline)
                        Text(a.delivered == 0 ? "New client" : "\(a.delivered) shoots together").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") { withAnimation(.snappy) { agent = nil } }.font(.subheadline.weight(.semibold))
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                field("Name, or just part of it", text: $agentQuery, icon: "person")
                let list = agentQuery.trimmingCharacters(in: .whitespaces).isEmpty
                    ? Array(model.customers.sorted { ($0.lastOrder ?? .distantPast) > ($1.lastOrder ?? .distantPast) }.prefix(8))
                    : Array(Booker.agents(matching: agentQuery, in: model.customers).prefix(8))
                FlowRow(spacing: 8) {
                    ForEach(list) { c in
                        Button { withAnimation(.snappy) { agent = c; agentQuery = "" } } label: {
                            HStack(spacing: 8) {
                                Monogram(name: c.name, initials: c.initials, size: 24)
                                Text(c.name).font(.subheadline.weight(.medium))
                            }
                            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                            .background(Theme.surface, in: Capsule())
                        }
                        .buttonStyle(.pressable)
                    }
                }
                if list.isEmpty { Text("No agent matches “\(agentQuery)”.").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(2, "Address", done: place != nil)
            if let p = place {
                VStack(alignment: .leading, spacing: 0) {
                    ShootMap(pins: [MapPin(id: p.line, label: "", title: "", lat: p.lat, lon: p.lon, highlighted: true)])
                        .allowsHitTesting(false)
                        .frame(height: 140)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(p.number) \(p.street)").font(.address(.headline))
                            Text("\(p.city), \(p.state) \(p.zip)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change") { withAnimation(.snappy) { place = nil } }.font(.subheadline.weight(.semibold))
                    }
                    .padding(14)
                    .background(Theme.surface)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                field("Shorthand is fine: 9 Radcliffe Ln Dartmouth", text: $addressQuery, icon: "mappin.and.ellipse")
                    .task(id: addressQuery) {
                        let q = addressQuery.trimmingCharacters(in: .whitespaces)
                        guard q.count >= 4 else { places = []; return }
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        guard !Task.isCancelled else { return }
                        searching = true
                        let found = await Booker.places(for: q)
                        guard !Task.isCancelled else { return }
                        places = Array(found.prefix(5))
                        searching = false
                    }
                if searching { ProgressView().padding(.leading, 4) }
                ForEach(places, id: \.self) { p in
                    Button { withAnimation(.snappy) { place = p; addressQuery = "" } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(p.number) \(p.street)").font(.subheadline.weight(.semibold))
                                Text("\(p.city), \(p.state)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private var packageStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(3, "Package", done: package != nil)
            if let e = packageError {
                Text(e).font(.subheadline).foregroundStyle(.orange)
            } else if packages.isEmpty {
                HStack(spacing: 8) { ProgressView(); Text("Loading your packages from Aryeo…").font(.subheadline).foregroundStyle(.secondary) }
            } else {
                VStack(spacing: 0) {
                    ForEach(packages, id: \.self) { p in
                        let on = package == p
                        Button { withAnimation(.snappy) { package = p; if let t = time, !fits(t) { self.time = nil } } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(on ? Theme.accent : Color(.tertiaryLabel))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.title).font(.subheadline.weight(on ? .semibold : .regular)).multilineTextAlignment(.leading)
                                    if p.minutes > 0 {
                                        Text(FieldTime.durationLabel(minutes: p.minutes)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(Money.dollars(p.priceCents)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if p != packages.last { Divider().padding(.leading, 36) }
                    }
                }
            }
        }
    }

    private var timeStep: some View {
        let open = Availability.day(day, jobs: model.visibleJobs)
        let slots = slots(in: open)
        return VStack(alignment: .leading, spacing: 12) {
            stepTitle(4, "When", done: time != nil)
            SideSafeScroller {
                HStack(spacing: 8) {
                    ForEach(0..<14, id: \.self) { i in
                        let d = FieldTime.addDays(i, to: FieldTime.startOfDay(Date()))
                        let on = FieldTime.isSameDay(d, day)
                        Button { withAnimation(.snappy) { day = d; time = nil } } label: {
                            VStack(spacing: 2) {
                                Text(FieldTime.format(d, "EEE")).font(.caption.weight(.semibold))
                                Text(FieldTime.format(d, "d")).font(.system(.title3, design: .serif, weight: .semibold))
                            }
                            .frame(width: 50, height: 60)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(on ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            DayTimeline(day: open, minutes: minutes).frame(height: 30)
            if slots.isEmpty {
                Text("No open \(FieldTime.durationLabel(minutes: minutes)) slot that day. Try another day.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: 8) {
                    ForEach(slots, id: \.self) { t in
                        let on = time == t
                        Button { withAnimation(.snappy) { time = t } } label: {
                            Text(Availability.short(t))
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .foregroundStyle(on ? Color.white : Theme.accent)
                                .background(on ? Theme.accent : Theme.accent.opacity(0.13), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
    }

    /// Start times every 30 minutes where the whole shoot fits in an opening.
    private func slots(in open: OpenDay) -> [Date] {
        var out: [Date] = []
        let length = TimeInterval(minutes * 60)
        for g in open.gaps where g.duration >= length {
            var t = Date(timeIntervalSinceReferenceDate: (g.start.timeIntervalSinceReferenceDate / 1800).rounded(.up) * 1800)
            while t.addingTimeInterval(length) <= g.end {
                out.append(t)
                t = t.addingTimeInterval(1800)
            }
        }
        return out
    }

    private func fits(_ t: Date) -> Bool { slots(in: Availability.day(t, jobs: model.visibleJobs)).contains(t) }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange)
            }
            Button {
                Task { await check() }
            } label: {
                HStack(spacing: 8) {
                    if working { ProgressView().tint(.white) }
                    Text(working ? "Checking Aryeo…" : (ready ? "Review and book" : "Pick all four to book"))
                }
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(!ready || working)
            Text("Aryeo emails the agent its usual confirmation once it's booked.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: size == .regular ? 520 : .infinity, alignment: .leading)
    }

    private var confirmText: String {
        guard let a = agent, let p = place, let k = package, let t = time else { return "" }
        return "Book \(a.name) for \(k.title) (\(Money.dollars(k.priceCents))) at \(p.line), \(FieldTime.format(t, "EEEE MMM d")) at \(FieldTime.clockAMPM(t))?"
    }

    private func doneView(_ b: BookedShoot) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                .symbolEffect(.bounce, value: b.number)
            Text("Booked").font(.address(34))
            Text("Order \(String(b.number)), \(place?.line ?? ""), \(FieldTime.format(b.start, "EEEE MMM d")) at \(FieldTime.clockAMPM(b.start)).")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.horizontal, 30)
            if let first = agent?.name.split(separator: " ").first {
                Text("\(first) is getting Aryeo's confirmation email.").font(.subheadline).foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryActionStyle())
                .frame(maxWidth: 320)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func field(_ prompt: String, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            TextField(prompt, text: text).autocorrectionDisabled()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Actions

    private func loadPackages() async {
        guard packages.isEmpty else { return }
        guard model.hasAryeoKey else { packageError = "Add your Aryeo key in Settings first."; return }
        do {
            packages = try await Booker.packages(key: model.aryeoKey).sorted { $0.priceCents < $1.priceCents }
            if packages.isEmpty { packageError = "No bookable packages came back from Aryeo." }
        } catch {
            packageError = error.localizedDescription
        }
    }

    /// Checks Aryeo for anything booked too close, then asks for the final yes.
    private func check() async {
        guard let t = time else { return }
        problem = nil
        working = true
        defer { working = false }
        if let clash = await Booker.clash(start: t, end: t.addingTimeInterval(TimeInterval(minutes * 60)), key: model.aryeoKey) {
            problem = clash
            return
        }
        confirming = true
    }

    private func book() async {
        guard let a = agent, let p = place, let k = package, let t = time else { return }
        guard let customerID = Booker.customerID(for: a) else { problem = "Couldn't find \(a.name)'s Aryeo account."; return }
        working = true
        defer { working = false }
        do {
            let b = try await Booker.book(customerID: customerID, place: p, package: k, start: t, notify: true, key: model.aryeoKey)
            withAnimation(.snappy) { booked = b }
            Task { await model.refresh() }
        } catch {
            problem = error.localizedDescription
        }
    }
}
