import SwiftUI
import MapKit

/// Every shoot. Rows for what's missing and what's coming up, then your delivered work as a gallery.
/// Same screen closed and open; the gallery just gets more columns.
struct ListingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    @State private var path: [AppRoute] = []
    @State private var search = ""
    @State private var showCount = 24
    @AppStorage("listingsShowsMap") private var showMap = false
    @Namespace private var ns

    private var wide: Bool { size == .regular }
    private var gutter: CGFloat { Gutter.of(size) }
    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private func matches(_ j: Job) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        // Shorthand works here too ("radcliffe ln", "tiff"), plus package words like "video" or "lux".
        return j.street.lowercased().contains(q) || j.town.lowercased().contains(q) ||
            j.agentName.lowercased().contains(q) || "\(j.number)".contains(q) ||
            j.packageSummary.lowercased().contains(q) || Booker.loosely(q, matches: "\(j.street) \(j.town) \(j.agentName)")
    }

    private func placed(_ j: Job) -> Date { FieldTime.parse(j.order.createdAt) ?? .distantPast }

    private var upcoming: [Job] {
        let timed = model.visibleJobs.filter { $0.status == .booked }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        let tbd = model.visibleJobs.filter { $0.status == .unscheduled }.sorted { placed($0) > placed($1) }
        return timed + tbd
    }

    /// Shoots that have happened, newest first.
    private var shot: [Job] {
        model.visibleJobs.filter { $0.status == .delivered || $0.status == .editing }
            .sorted { ($0.start ?? placed($0)) > ($1.start ?? placed($1)) }
    }

    private var results: [Job] {
        (upcoming + shot).filter(matches)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: wide ? 250 : 160), spacing: 14, alignment: .top)]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !model.hasAryeoKey { MissingKeyView() }
                else if showMap && !searching { ShootsMapView(jobs: model.visibleJobs, compact: size != .regular) { id in if path.last != .shoot(id) { path.append(.shoot(id)) } } }
                else { page }
            }
            .slimBar("Listings")
            // Gallery or map, like Photos' Years / Months / All: a plain switch above the content.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                if model.hasAryeoKey {
                    SearchBox(text: $search, prompt: "Address, agent, package or order #")
                }
                if model.hasAryeoKey && !searching {
                    Picker("View", selection: $showMap) {
                        Label("Gallery", systemImage: "square.grid.2x2").tag(false)
                        Label("Map", systemImage: "map").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .padding(.horizontal, Gutter.of(size))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground))
                }
                }
            }
            .appDestinations(ns)
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if searching {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "Results", note: "\(results.count)")
                        if results.isEmpty {
                            Text("Nothing matches “\(search)”.").foregroundStyle(.secondary)
                        }
                        grid(Array(results.prefix(120)))
                    }
                    .padding(.horizontal, gutter)
                } else {
                    if !model.deliveryFlags.isEmpty {
                        Rail(title: "Missing", note: "\(model.deliveryFlags.count)", items: model.deliveryFlags,
                             cardWidth: wide ? 290 : 240) { f in
                            NavigationLink(value: AppRoute.shoot(f.job.id)) {
                                ShootCard(job: f.job, flag: f).zoomSource(f.job.id, in: ns)
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    if !upcoming.isEmpty {
                        Rail(title: "Upcoming", note: "\(upcoming.count)", items: upcoming, cardWidth: wide ? 290 : 220) { j in
                            NavigationLink(value: AppRoute.shoot(j.id)) {
                                ShootCard(job: j, showsTime: true).zoomSource(j.id, in: ns)
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "Past shoots", note: "\(shot.count)")
                        grid(Array(shot.prefix(showCount)))
                        if shot.count > showCount {
                            Button {
                                withAnimation(.snappy) { showCount += 48 }
                            } label: {
                                Text("Show more").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryActionStyle(prominent: false))
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, gutter)
                }
            }
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemBackground))
        .refreshable { await model.refresh() }
    }

    private func grid(_ list: [Job]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(list) { j in
                NavigationLink(value: AppRoute.shoot(j.id)) {
                    ShootCard(job: j, flag: model.flag(for: j), showsTime: j.status == .booked)
                        .zoomSource(j.id, in: ns)
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

// MARK: - Shoot map

/// Every shoot you've done, on one map. Zoomed out: a bubble per town, sized by how many shoots.
/// Zoomed in: a pin per house. Tap a town for its shoots, tap a house to open it.
struct ShootsMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    let open: (String) -> Void

    @State private var position: MapCameraPosition
    @State private var region: MKCoordinateRegion?

    /// Opens on a fixed region (never `.automatic`): an automatic camera re-fits whenever the
    /// bubbles change, which moves the camera, which changes the bubbles, and so on forever.
    init(jobs: [Job], compact: Bool = false, open: @escaping (String) -> Void) {
        self.open = open
        // Folded, the map is tall and narrow, so start closer in on the heart of it.
        let home = Self.homeRegion(for: jobs, reach: compact ? 0.45 : 1) ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.64, longitude: -70.95),
            span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.6))
        _position = State(initialValue: .region(home))
        _region = State(initialValue: home)
    }
    @State private var selectedTown: String?
    @State private var thisYearOnly = false

    struct Town: Identifiable {
        let id: String          // town name
        let lat: Double
        let lon: Double
        let jobs: [Job]          // newest first
    }

    private var mapped: [Job] {
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date())) ?? .distantPast
        return model.visibleJobs.filter { j in
            guard j.latitude != nil, j.longitude != nil, !j.town.isEmpty else { return false }
            guard j.status == .delivered || j.status == .editing || j.status == .booked else { return false }
            return !thisYearOnly || (j.start ?? .distantPast) >= start
        }
    }

    private var towns: [Town] {
        Dictionary(grouping: mapped, by: \.town).map { name, jobs in
            let lat = jobs.compactMap(\.latitude).reduce(0, +) / Double(jobs.count)
            let lon = jobs.compactMap(\.longitude).reduce(0, +) / Double(jobs.count)
            return Town(id: name, lat: lat, lon: lon,
                        jobs: jobs.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) })
        }
        .sorted { $0.jobs.count > $1.jobs.count }
    }

    /// Towns close together on screen merge into one bubble, like Photos does. Tap one to zoom in.
    struct Cluster: Identifiable {
        let towns: [Town]
        var id: String { towns.map(\.id).sorted().joined(separator: "|") }
        var count: Int { towns.reduce(0) { $0 + $1.jobs.count } }
        var lat: Double { towns.reduce(0) { $0 + $1.lat * Double($1.jobs.count) } / Double(count) }
        var lon: Double { towns.reduce(0) { $0 + $1.lon * Double($1.jobs.count) } / Double(count) }
        var title: String {
            guard let top = towns.max(by: { $0.jobs.count < $1.jobs.count }) else { return "" }
            return towns.count == 1 ? top.id : "\(top.id) and \(towns.count - 1) more"
        }
    }

    /// Bubble size in points for a count. Area grows with the count.
    /// `largest` is the biggest town's count; pass it in when calling in a loop, since working it out
    /// means grouping every shoot again.
    private func diameter(_ count: Int, largest: Int? = nil) -> Double {
        min(78, 28 + 46 * sqrt(Double(count) / Double(max(largest ?? self.largest, 1))))
    }

    /// Greedy merge: biggest towns first, anything whose bubble would overlap joins it.
    private func clusters(in mapSize: CGSize) -> [Cluster] {
        let all = towns
        let biggest = all.first?.jobs.count ?? 1
        guard let r = region, mapSize.width > 0, mapSize.height > 0 else { return all.map { Cluster(towns: [$0]) } }
        let ptPerLon = mapSize.width / r.span.longitudeDelta
        let ptPerLat = mapSize.height / r.span.latitudeDelta
        func touch(_ lat: Double, _ lon: Double, _ count: Int, _ c: Cluster) -> Bool {
            let dx = (c.lon - lon) * ptPerLon, dy = (c.lat - lat) * ptPerLat
            return (dx * dx + dy * dy).squareRoot() < (diameter(c.count, largest: biggest) + diameter(count, largest: biggest)) / 2
        }
        var out: [Cluster] = []
        for t in all {   // already sorted, most shoots first
            if let i = out.firstIndex(where: { touch(t.lat, t.lon, t.jobs.count, $0) }) {
                out[i] = Cluster(towns: out[i].towns + [t])
            } else {
                out.append(Cluster(towns: [t]))
            }
        }
        // A bubble grows and shifts as towns join it, so it can end up on top of one placed earlier.
        // Keep merging until no two bubbles touch.
        var merged = true
        while merged {
            merged = false
            search: for i in out.indices {
                for j in out.indices where j > i && touch(out[j].lat, out[j].lon, out[j].count, out[i]) {
                    out[i] = Cluster(towns: out[i].towns + out[j].towns)
                    out.remove(at: j)
                    merged = true
                    break search
                }
            }
        }
        return out.sorted { $0.count < $1.count }
    }

    /// Where most of the work is: the towns within about 60 km of the middle of it all.
    /// One-off jobs far away don't drag the opening view out to all of New England.
    private func homeRegion() -> MKCoordinateRegion? { Self.homeRegion(for: mapped, reach: size == .regular ? 1 : 0.45) }

    static func homeRegion(for jobs: [Job], reach: Double = 1) -> MKCoordinateRegion? {
        let pts = jobs.compactMap { j -> (Double, Double)? in
            guard let a = j.latitude, let b = j.longitude, a != 0, b != 0 else { return nil }
            return (a, b)
        }
        guard !pts.isEmpty else { return nil }
        let lats = pts.map(\.0).sorted(), lons = pts.map(\.1).sorted()
        let mLat = lats[lats.count / 2], mLon = lons[lons.count / 2]
        let near = pts.filter { abs($0.0 - mLat) < 0.55 * reach && abs($0.1 - mLon) < 0.75 * reach }
        guard let minLat = near.map(\.0).min(), let maxLat = near.map(\.0).max(),
              let minLon = near.map(\.1).min(), let maxLon = near.map(\.1).max() else { return nil }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                  span: MKCoordinateSpan(latitudeDelta: max(0.05, (maxLat - minLat) * 1.3),
                                                         longitudeDelta: max(0.05, (maxLon - minLon) * 1.3)))
    }

    /// Only take a new camera when it really moved, so tiny settles don't redraw every bubble.
    private func noteCamera(_ r: MKCoordinateRegion) {
        guard let old = region else { region = r; return }
        // Both directions: on the wide open Duo the map shows more east-west than the region it was
        // given, and the bubbles need the real width to space themselves.
        let latRatio = r.span.latitudeDelta / max(old.span.latitudeDelta, 0.000_001)
        let lonRatio = r.span.longitudeDelta / max(old.span.longitudeDelta, 0.000_001)
        let moved = max(abs(r.center.latitude - old.center.latitude) / max(old.span.latitudeDelta, 0.000_001),
                        abs(r.center.longitude - old.center.longitude) / max(old.span.longitudeDelta, 0.000_001))
        if latRatio > 1.1 || latRatio < 0.9 || lonRatio > 1.1 || lonRatio < 0.9 || moved > 0.15 { region = r }
    }

    private func zoom(to c: Cluster) {
        let minLat = c.towns.map(\.lat).min() ?? c.lat, maxLat = c.towns.map(\.lat).max() ?? c.lat
        let minLon = c.towns.map(\.lon).min() ?? c.lon, maxLon = c.towns.map(\.lon).max() ?? c.lon
        let r = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                   span: MKCoordinateSpan(latitudeDelta: max(0.03, (maxLat - minLat) * 1.4),
                                                          longitudeDelta: max(0.03, (maxLon - minLon) * 1.4)))
        withAnimation(.smooth(duration: 0.6)) { position = .region(r) }
    }

    /// Close enough to tell houses apart.
    private var showHouses: Bool { (region?.span.latitudeDelta ?? 1) < 0.07 }

    /// Only the houses on screen, so the map stays quick.
    private var houses: [Job] {
        guard let r = region else { return [] }
        let latR = (r.center.latitude - r.span.latitudeDelta)...(r.center.latitude + r.span.latitudeDelta)
        let lonR = (r.center.longitude - r.span.longitudeDelta)...(r.center.longitude + r.span.longitudeDelta)
        return Array(mapped.filter { latR.contains($0.latitude ?? 0) && lonR.contains($0.longitude ?? 0) }.prefix(250))
    }

    private var largest: Int { towns.first?.jobs.count ?? 1 }

    var body: some View {
        GeometryReader { geo in
            mapStack(geo.size)
        }
    }

    private func mapStack(_ mapSize: CGSize) -> some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                if showHouses {
                    ForEach(houses) { j in
                        Annotation(j.street, coordinate: CLLocationCoordinate2D(latitude: j.latitude ?? 0, longitude: j.longitude ?? 0),
                                   anchor: .center) {
                            Button { open(j.id) } label: {
                                Circle()
                                    .fill(j.status == .booked ? Theme.accent : Color(.darkGray))
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                                    .padding(8)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ForEach(clusters(in: mapSize)) { c in
                        Annotation(c.title, coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), anchor: .center) {
                            Button {
                                if c.towns.count == 1, let t = c.towns.first {
                                    withAnimation(.snappy) { selectedTown = selectedTown == t.id ? nil : t.id }
                                } else {
                                    zoom(to: c)
                                }
                            } label: { bubble(c) }
                            .buttonStyle(.pressable)
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .onEnd) { ctx in noteCamera(ctx.region) }
            .sensoryFeedback(.selection, trigger: selectedTown)

            header
                .padding(.horizontal, Gutter.of(size))
                .padding(.top, 10)
        }
        .overlay(alignment: .bottom) {
            if let name = selectedTown, let t = towns.first(where: { $0.id == name }) {
                townCard(t)
                    .padding(.horizontal, size == .regular ? 0 : Gutter.of(size))
                    .padding(.bottom, 10)
                    .frame(maxWidth: size == .regular ? 760 : .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: thisYearOnly) { _, _ in
            selectedTown = nil
            if let home = homeRegion() { withAnimation(.smooth) { position = .region(home) } }
        }
        // Opened before the shoots were read in: the camera started on a fallback view, so move it
        // to the usual opening view once they arrive.
        .onChange(of: model.jobs.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty, !isEmpty, let home = homeRegion() { position = .region(home) }
        }
    }

    private func bubble(_ c: Cluster) -> some View {
        // Area grows with the count, so a town with 4x the shoots looks 4x as big.
        let d = diameter(c.count)
        let selected = c.towns.count == 1 && selectedTown == c.towns.first?.id
        return Text("\(c.count)")
            .font(.system(size: max(12, d * 0.3), weight: .bold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .foregroundStyle(.white)
            .frame(width: d, height: d)
            .background(selected ? Color.orange : Theme.accent, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
            .scaleEffect(selected ? 1.12 : 1)
            .animation(.snappy, value: c.count)
    }

    private var header: some View {
        let title = VStack(alignment: .leading, spacing: 1) {
            // Right after launch the saved shoots are still being read in; say so instead of "0 shoots".
            Text(model.jobs.isEmpty ? "Loading your shoots…" : "\(mapped.count) shoots in \(towns.count) towns").font(.address(.headline))
            Text(showHouses ? "Tap a house to open it" : "Tap a town to see its shoots. Zoom in for houses.")
                .font(.caption).foregroundStyle(.secondary)
        }
        let range = Picker("Range", selection: $thisYearOnly) {
            Text("All time").tag(false)
            Text("This year").tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        return Group {
            if size == .regular {
                HStack(spacing: 10) { title; Spacer(minLength: 8); range }
            } else {
                VStack(alignment: .leading, spacing: 10) { title; range }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private func townCard(_ t: Town) -> some View {
        let agents = Dictionary(grouping: t.jobs, by: \.agentName).max { $0.value.count < $1.value.count }
        let first = t.jobs.compactMap(\.start).min()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.id).font(.address(28))
                    Text(townLine(t, first: first, agent: agents.map { ($0.key, $0.value.count) }))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { selectedTown = nil }
                } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18)

            SideSafeScroller(aligned: true) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(t.jobs.prefix(40)) { j in
                        Button { open(j.id) } label: {
                            ShootCard(job: j, showsTime: j.status == .booked).frame(width: size == .regular ? 230 : 190)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 18)
            }
        }
        .padding(.vertical, 18)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
    }

    private func townLine(_ t: Town, first: Date?, agent: (String, Int)?) -> String {
        var s = t.jobs.count == 1 ? "1 shoot" : "\(t.jobs.count) shoots"
        if let first { s += " since \(FieldTime.format(first, "MMMM yyyy"))" }
        if let agent, agent.1 > 1 { s += ". Most with \(agent.0) (\(agent.1))." } else { s += "." }
        return s
    }
}
