import SwiftUI

/// One shoot, start to finish: a full-bleed hero, the quick actions, the details, then everything delivered.
/// Every card in the app opens this page. Open Duo: the details sit in two columns under a wider hero.
struct StopDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    let job: Job

    @State private var forecastLine: String?
    @State private var hours: [HourForecast] = []
    @State private var showKit = false
    /// The Duo sitting half-open like a laptop (iOS 27.1 reports it; otherwise always false).
    @State private var halfOpen = false

    private var stats: CustomerStats? { model.stats(for: job.agentName) }
    private var wide: Bool { size == .regular }
    private var gutter: CGFloat { Gutter.of(size) }
    private var heroHeight: CGFloat { wide ? 460 : 400 }

    var body: some View {
        Group {
            if halfOpen { laptop } else { page }
        }
        .foldWatch(halfOpen: $halfOpen)
        .background(Color(.systemBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Launcher.open(job.adminURL) } label: { Label("Open in Aryeo", systemImage: "arrow.up.right.square") }
                    if let url = job.adminURL { ShareLink(item: url) { Label("Share Aryeo link", systemImage: "square.and.arrow.up") } }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .sensoryFeedback(.success, trigger: model.flag(for: job) == nil) { was, now in !was && now }
        .adaptiveSheet(isPresented: $showKit) { ListingKitView(job: job) }
        .task(id: job.id) { await loadForecast() }
    }

    // MARK: Layouts

    /// The usual page: the hero on top, everything else scrolling under it.
    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                details
            }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
    }

    /// Duo half-open like a laptop: the photo (or map) fills the top half right down to the fold,
    /// and the actions and details scroll on the bottom half. Nothing sits across the hinge.
    private var laptop: some View {
        GeometryReader { geo in
            let band = geo.foldBand ?? (top: geo.size.height / 2, bottom: geo.size.height / 2)
            VStack(spacing: 0) {
                heroArt(width: geo.size.width, height: band.top)
                Color(.systemBackground)
                    .frame(height: max(0, band.bottom - band.top))
                ScrollView {
                    details
                }
                .scrollIndicators(.hidden)
                .frame(height: max(0, geo.size.height - band.bottom))
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    /// Everything under the hero: actions, the cards, the photos, earlier visits.
    private var details: some View {
        VStack(alignment: .leading, spacing: 22) {
            ShootActions(job: job)
            if let f = model.flag(for: job) { flagBanner(f) }
            if wide {
                HStack(alignment: .top, spacing: 18) {
                    // Balanced: the tall order card beside the agent and the light, notes under the order.
                    VStack(spacing: 18) { shootCard; headsUpCard; notesCard }.frame(maxWidth: .infinity)
                    VStack(spacing: 18) { agentCard; lightCard }.frame(maxWidth: .infinity)
                }
            } else {
                headsUpCard
                shootCard
                agentCard
                lightCard
                notesCard
            }
            PhotosCard(job: job, onKit: { showKit = true })
            if !earlierVisits.isEmpty { earlierSection }
        }
        .padding(.horizontal, gutter)
        .padding(.top, 18)
        .padding(.bottom, 32)
    }

    // MARK: Hero

    /// Full bleed to the top of the screen; stretches when you pull down.
    private var hero: some View {
        GeometryReader { geo in
            let pull = max(0, geo.frame(in: .scrollView).minY)
            heroArt(width: geo.size.width, height: heroHeight + pull)
                .offset(y: -pull)
        }
        .frame(height: heroHeight)
    }

    /// The picture (or the map, or the date art), its shade, and the address, at a given size.
    private func heroArt(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = job.heroURL {
                    RemotePhoto(url: url, cornerRadius: 0)
                } else if let lat = job.latitude, let lon = job.longitude {
                    ShootMap(pins: [MapPin(id: job.id, label: "", title: "", lat: lat, lon: lon, highlighted: true)])
                        .allowsHitTesting(false)
                } else {
                    DateArt(date: job.start)
                }
            }
            .frame(width: width, height: height)
            .clipped()

            // Photos get a shade for the type; a map gets a solid panel instead, so its labels stay readable.
            if job.heroURL != nil {
                LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                       .init(color: .clear, location: 0.25),
                                       .init(color: .clear, location: 0.45),
                                       .init(color: Color(.systemBackground).opacity(0.85), location: 0.88),
                                       .init(color: Color(.systemBackground), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }

            heroText
                .padding(.horizontal, gutter)
                .padding(.vertical, job.heroURL == nil ? 16 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(job.heroURL == nil ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear))
        }
        .frame(width: width, height: height)
    }

    private var heroText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(job.status == .delivered ? Color.green : Theme.accent)
            Text(job.street)
                .font(.address(wide ? 38 : 32))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(job.townState)
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        switch job.status {
        case .delivered:
            let n = job.images.count
            return n > 0 ? "Delivered, \(n) photos" : "Delivered"
        case .editing: return "Shot \(job.start.map { FieldTime.format($0, "EEEE, MMM d") } ?? "")"
        case .booked:
            guard let s = job.start else { return "Booked" }
            if FieldTime.isSameDay(s, Date()) { return "Today at \(FieldTime.clockAMPM(s))" }
            if FieldTime.isSameDay(s, FieldTime.addDays(1, to: Date())) { return "Tomorrow at \(FieldTime.clockAMPM(s))" }
            return "\(FieldTime.format(s, "EEEE, MMM d")) at \(FieldTime.clockAMPM(s))"
        case .unscheduled: return "Booked, date to be set"
        case .stale: return "Never closed out in Aryeo"
        }
    }

    // MARK: Sections

    /// Same house, other orders: a relist, a reshoot, or last year's listing.
    private var earlierVisits: [Job] {
        let key = Booker.normalize(job.street)
        guard !key.isEmpty, job.street != "Address missing" else { return [] }
        return model.visibleJobs.filter { j in
            j.id != job.id && Booker.normalize(j.street) == key &&
                j.town.caseInsensitiveCompare(job.town) == .orderedSame
        }
        .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    private var earlierSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "This house before", note: earlierVisits.count == 1 ? "1 other order" : "\(earlierVisits.count) other orders")
            SideSafeScroller {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(earlierVisits) { j in
                        NavigationLink(value: AppRoute.shoot(j.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                ShootCard(job: j, showsAgent: true)
                                Text(j.start.map { "Shot \(FieldTime.format($0, "MMMM yyyy"))" }
                                     ?? FieldTime.parse(j.order.createdAt).map { "Ordered \(FieldTime.format($0, "MMMM d, yyyy")), never scheduled" }
                                     ?? "")
                                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 2)
                            }
                        }
                        .buttonStyle(.pressable)
                        .frame(width: wide ? 280 : 230)
                    }
                }
            }
        }
    }

    private func flagBanner(_ f: DeliveryFlag) -> some View {
        HStack(spacing: 10) {
            Label("\(f.line). The order includes \(f.missing.joined(separator: " and ")).", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            Spacer(minLength: 4)
            Button("Not needed") { withAnimation { model.dismissFlag(job) } }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var shootCard: some View {
        Card(title: "The shoot") {
            InfoRow(label: "When", value: job.start.map { "\(FieldTime.format($0, "EEE, MMM d")), \(job.timeRange)" } ?? "Date to be set")
            if let m = job.durationMinutes { InfoRow(label: "Length", value: FieldTime.durationLabel(minutes: m)) }
            InfoRow(label: "Address", value: job.address?.unparsedAddress ?? job.street)
            Divider()
            ForEach(Array(job.items.enumerated()), id: \.offset) { _, item in
                InfoRow(label: item.title ?? "Item", value: Money.dollars(item.amount))
            }
            HStack {
                Text("Order \(String(job.number))").font(.subheadline.weight(.semibold))
                Spacer()
                Text(Money.dollars(job.order.totalAmount)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
        }
    }

    private var agentCard: some View {
        Card(title: "Agent") {
            HStack(spacing: 12) {
                Monogram(name: job.agentName, initials: stats?.initials ?? String(job.agentName.prefix(2)).uppercased(), size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.agentName).font(.address(.title3))
                    if let phone = Phone.pretty(job.agentPhone) {
                        Text(phone).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let email = job.agentEmail {
                        Text(email).font(.subheadline)
                            .foregroundStyle(EmailCheck.problem(email) == nil ? Color.secondary : Color.red)
                    }
                }
            }
            if !historyLine.isEmpty {
                Text(historyLine).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var historyLine: String {
        guard let s = stats else { return "" }
        if s.delivered == 0 { return "New client, first order with you." }
        var parts = ["\(s.delivered) delivered"]
        if let first = s.firstOrder { parts.append("working together since \(FieldTime.format(first, "MMMM yyyy"))") }
        parts.append(s.videoOrders == 0 ? "no video yet" : "video on \(s.videoOrders) of \(s.delivered)")
        let line = parts.joined(separator: ", ")
        return line + "."
    }

    private var lightCard: some View {
        Card(title: "Light and weather") {
            if let start = job.start, let lat = job.latitude, let lon = job.longitude,
               let sunset = Sun.sunset(on: start, lat: lat, lon: lon) {
                InfoRow(label: "Sunset", value: FieldTime.clockAMPM(sunset))
                // Sun about 6° up: warm, low light. Sunset to the end of civil dusk: twilight exteriors.
                if let golden = Sun.sunset(on: start, lat: lat, lon: lon, zenith: 84) {
                    InfoRow(label: "Golden light", value: "from \(FieldTime.clockAMPM(golden))")
                }
                if let dusk = Sun.sunset(on: start, lat: lat, lon: lon, zenith: 96) {
                    InfoRow(label: "Twilight", value: "\(FieldTime.clock(sunset)) – \(FieldTime.clockAMPM(dusk))")
                }
                if let end = job.end, job.status != .delivered {
                    let gap = Int(sunset.timeIntervalSince(end) / 60)
                    InfoRow(label: "Wraps", value: gap >= 0 ? "\(FieldTime.durationLabel(minutes: gap)) before sunset" : "after sunset",
                            valueColor: gap < 15 ? .orange : .primary)
                }
            } else {
                Text("Sunset shows once the shoot has a time and address.").font(.subheadline).foregroundStyle(.secondary)
            }
            if let f = forecastLine { InfoRow(label: "Forecast", value: f) }
            if !hours.isEmpty {
                SideSafeScroller {
                    HStack(spacing: 8) {
                        ForEach(hours, id: \.start) { h in
                            VStack(spacing: 4) {
                                Text(FieldTime.format(h.start, "h a")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                Image(systemName: ShootWeather.symbol(for: h.summary))
                                    .symbolRenderingMode(.multicolor).font(.title3)
                                    .frame(height: 24)
                                Text(h.temperatureF.map { "\($0)°" } ?? "–").font(.subheadline.weight(.semibold))
                                if let r = h.rainChance, r >= 20 {
                                    Text("\(r)%").font(.caption2.weight(.semibold)).foregroundStyle(.cyan)
                                }
                            }
                            .frame(minWidth: 48)
                            .padding(.vertical, 8)
                            .background(Color(.systemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    /// What the upcoming check found for this shoot: weather, airspace, the agent's email.
    @ViewBuilder private var headsUpCard: some View {
        if let r = model.checkResults.first(where: { $0.job.id == job.id }), !r.issues.isEmpty {
            Card(title: "Heads up") {
                ForEach(r.issues) { issue in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: Self.icon(issue.kind))
                            .foregroundStyle(Self.tint(issue.kind))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.title).font(.subheadline.weight(.semibold))
                            Text(issue.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let s = r.suggestion {
                    Divider()
                    NavigationLink(value: AppRoute.tonight) {
                        HStack {
                            Text("Better day: \(FieldTime.format(s.date, "EEEE, MMM d")) at \(FieldTime.clockAMPM(s.date))")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    private static func icon(_ k: CheckIssue.Kind) -> String {
        switch k {
        case .rain: return "cloud.rain.fill"
        case .wind: return "wind"
        case .airspace: return "airplane"
        case .email: return "envelope.badge.fill"
        case .unscheduled: return "calendar.badge.exclamationmark"
        case .sunset: return "sun.horizon.fill"
        }
    }

    private static func tint(_ k: CheckIssue.Kind) -> Color {
        switch k {
        case .rain, .wind: return .cyan
        case .airspace, .sunset: return .orange
        case .email, .unscheduled: return .red
        }
    }

    @ViewBuilder private var notesCard: some View {
        if let notes = job.order.internalNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Card(title: "Order notes") { Text(notes).font(.body) }
        }
    }

    private func loadForecast() async {
        guard let start = job.start, let end = job.end ?? job.start?.addingTimeInterval(3600),
              start > Date().addingTimeInterval(-3600), start < Date().addingTimeInterval(6 * 86_400),
              let lat = job.latitude, let lon = job.longitude else { return }
        guard let fc = try? await model.weather.forecast(lat: lat, lon: lon) else { return }
        let hrs = fc.hours(from: start, to: end)
        guard let first = hrs.first else { return }
        // An hour either side, so you can see what's coming in or clearing out.
        hours = Array(fc.hours(from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600)).prefix(8))
        let rain = hrs.compactMap { $0.rainChance }.max() ?? 0
        let wind = hrs.compactMap { $0.windMph }.max() ?? 0
        forecastLine = "\(first.temperatureF.map { "\($0)°, " } ?? "")\(first.summary.lowercased()), \(rain)% rain, wind \(wind) mph"
    }
}

/// Big, thumb-friendly actions under the hero.
struct ShootActions: View {
    let job: Job
    /// Counts "On my way" taps so each one gets a thump as Messages opens.
    @State private var onMyWayTaps = 0

    var body: some View {
        HStack(spacing: 10) {
            action("Directions", "location.fill", prominent: true) { Launcher.directions(to: job) }
            if job.agentPhone != nil {
                action("Call", "phone.fill") { Launcher.open(Phone.dialURL(job.agentPhone)) }
                action("On my way", "message.fill") {
                    onMyWayTaps += 1
                    Launcher.open(Phone.textURL(job.agentPhone, body: Drafts.onMyWay(job: job)))
                }
            }
            action("Aryeo", "arrow.up.right.square") { Launcher.open(job.adminURL) }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: onMyWayTaps)
    }

    private func action(_ title: String, _ icon: String, prominent: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.body.weight(.semibold))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(prominent ? Color.white : Theme.accent)
            .background(prominent ? Theme.accent : Theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.pressable)
    }
}
