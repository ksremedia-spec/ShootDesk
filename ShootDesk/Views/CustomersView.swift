import SwiftUI
import Charts

/// Agents, with their history worked out from every order (same rules as the data dashboard).
/// Closed: a clean list. Open: a sortable table. Either way, tap an agent for their page.
struct CustomersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    @State private var path: [AppRoute] = []
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\AgentRow.last, order: .reverse)]
    @Namespace private var ns

    /// Most recently booked first.
    private var agents: [CustomerStats] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = q.filter(\.isNumber)
        return model.customers
            .filter { c in
                guard !q.isEmpty else { return true }
                if c.name.lowercased().contains(q) || (c.email ?? "").lowercased().contains(q) { return true }
                return !digits.isEmpty && (c.phone ?? "").filter(\.isNumber).contains(digits)
            }
            .sorted { ($0.lastOrder ?? .distantPast) > ($1.lastOrder ?? .distantPast) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !model.hasAryeoKey {
                    MissingKeyView()
                } else if size == .regular {
                    CustomersTable(rows: agents.map(AgentRow.init).sorted(using: sort), sort: $sort) { id in
                        path.append(.customer(id))
                    }
                    // The table rows have their own small inset, so this lands the names on the page margin.
                    .padding(.horizontal, Gutter.of(size) - 10)
                } else {
                    List(agents) { c in
                        NavigationLink(value: AppRoute.customer(c.id)) { CustomerRow(stats: c) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: Gutter.of(size), bottom: 8, trailing: Gutter.of(size)))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.hasAryeoKey { SearchBox(text: $search, prompt: "Name, phone or email") }
            }
            .slimBar("Customers")
            .foldedTitleHidden()
            .refreshable { await model.refresh() }
            .appDestinations(ns)
        }
    }
}

struct CustomerRow: View {
    let stats: CustomerStats

    var body: some View {
        HStack(spacing: 12) {
            Monogram(name: stats.name, initials: stats.initials, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(stats.name).font(.body.weight(.semibold))
                Text(subline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if stats.group() == .new { StatusChip(text: "New", color: .green) }
        }
    }

    private var subline: String {
        guard let last = stats.lastOrder else { return "No orders yet" }
        if stats.delivered == 0 { return "First order booked \(FieldTime.format(last, "MMM d"))" }
        let shoots = stats.delivered == 1 ? "1 shoot" : "\(stats.delivered) shoots"
        return "\(shoots), last booked \(FieldTime.format(last, "MMM d"))"
    }
}

/// One agent: who they are, what they're worth to you, and every shoot you've done for them.
struct CustomerDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    let stats: CustomerStats
    @State private var booking = false

    private var wide: Bool { size == .regular }
    private var gutter: CGFloat { Gutter.of(size) }

    /// Every shoot for this agent: upcoming first (soonest), then the rest newest first.
    private var shoots: [Job] {
        let mine = model.visibleJobs.filter { Rules.normalizedName($0.agentName) == stats.id }
        let upcoming = mine.filter { $0.status == .booked || $0.status == .unscheduled }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        let done = mine.filter { $0.status == .delivered || $0.status == .editing }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
        return upcoming + done
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header.padding(.horizontal, gutter)

                if let note = insight {
                    Label(note, systemImage: "sparkles")
                        .font(.subheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, gutter)
                }

                figures.padding(.horizontal, gutter)

                if monthly.contains(where: { $0.count > 0 }) {
                    activity.padding(.horizontal, gutter)
                }

                if !shoots.isEmpty {
                    Rail(title: "Shoots", note: "\(shoots.count)", items: shoots, cardWidth: wide ? 300 : 240) { j in
                        NavigationLink(value: AppRoute.shoot(j.id)) {
                            ShootCard(job: j, showsTime: j.status == .booked, showsAgent: false)
                        }
                        .buttonStyle(.pressable)
                    }
                }

                orders.padding(.horizontal, gutter)
            }
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground))
        .slimBar("")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { booking = true } label: { Label("Book a shoot", systemImage: "calendar.badge.plus") }
            }
        }
        .adaptiveSheet(isPresented: $booking) { BookShootView(agent: stats) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Monogram(name: stats.name, initials: stats.initials, size: wide ? 84 : 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(stats.name).font(.address(wide ? 34 : 28)).lineLimit(2).minimumScaleFactor(0.8)
                    if let since = stats.firstOrder {
                        Text("Working together since \(FieldTime.format(since, "MMMM yyyy"))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                if stats.phone != nil {
                    Button { Launcher.open(Phone.dialURL(stats.phone)) } label: { Label("Call", systemImage: "phone.fill") }
                        .buttonStyle(PrimaryActionStyle())
                    Button { Launcher.open(Phone.textURL(stats.phone)) } label: { Label("Text", systemImage: "message.fill") }
                        .buttonStyle(PrimaryActionStyle(prominent: false))
                }
                if let e = stats.email, let url = URL(string: "mailto:\(e)") {
                    Button { Launcher.open(url) } label: { Label("Email", systemImage: "envelope.fill") }
                        .buttonStyle(PrimaryActionStyle(prominent: false))
                }
            }
            .frame(maxWidth: wide ? 520 : .infinity)
        }
    }

    private struct MonthCount: Identifiable {
        let month: Date
        let count: Int
        var id: Date { month }
    }

    /// Paid orders per month over the last two years.
    private var monthly: [MonthCount] {
        let cal = FieldTime.calendar
        guard let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())) else { return [] }
        let dates = stats.orders.filter { ($0.totalAmount ?? 0) > 0 }.compactMap { FieldTime.parse($0.createdAt) }
        return (0..<24).reversed().compactMap { back -> MonthCount? in
            guard let m = cal.date(byAdding: .month, value: -back, to: thisMonth) else { return nil }
            return MonthCount(month: m, count: dates.filter { cal.isDate($0, equalTo: m, toGranularity: .month) }.count)
        }
    }

    /// Where this agent sends you most.
    private var topTowns: [(String, Int)] {
        Dictionary(grouping: shoots.filter { !$0.town.isEmpty }, by: \.town)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(5).map { $0 }
    }

    private var activity: some View {
        let data = monthly
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Orders by month", note: "last two years")
            Chart(data) { m in
                BarMark(x: .value("Month", m.month, unit: .month), y: .value("Orders", m.count))
                    .foregroundStyle(FieldTime.calendar.isDate(m.month, equalTo: Date(), toGranularity: .year)
                                     ? Theme.accent : Color.secondary.opacity(0.35))
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                }
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: wide ? 170 : 140)
            if !topTowns.isEmpty {
                FlowRow(spacing: 8) {
                    ForEach(topTowns, id: \.0) { t in
                        HStack(spacing: 6) {
                            Text(t.0)
                            Text("\(t.1)").foregroundStyle(.secondary).monospacedDigit()
                        }
                            .font(.subheadline)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.surface, in: Capsule())
                    }
                }
            }
        }
    }

    private var figures: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading), count: wide ? 4 : 2),
                  alignment: .leading, spacing: 20) {
            figure("Shoots", "\(stats.delivered)", "delivered")
            figure("Booked", Money.dollars((stats.revenueCents / 100) * 100), "all time")
            figure("Average", stats.delivered > 0 ? Money.dollars((stats.averageCents / 100) * 100) : "—", "per order")
            figure("Video", stats.delivered > 0 ? "\(stats.videoOrders) of \(stats.delivered)" : "—", "orders with video")
        }
    }

    private func figure(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.address(.title2)).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var orders: some View {
        let list = stats.orders.filter { ($0.totalAmount ?? 0) > 0 }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Orders", note: "\(list.count)").padding(.bottom, 8)
            ForEach(list.prefix(wide ? 60 : 25)) { o in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((o.items ?? []).compactMap { $0.title }.joined(separator: " + "))
                            .font(.subheadline).lineLimit(1)
                        Text("Order \(String(o.number ?? 0)), \(FieldTime.parse(o.createdAt).map { FieldTime.format($0, "MMM d, yyyy") } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Money.dollars(o.totalAmount)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
    }

    private var insight: String? {
        var parts: [String] = []
        if let next = shoots.first(where: { $0.status == .booked }), let s = next.start {
            parts.append("Next shoot \(FieldTime.format(s, "EEEE, MMM d")) at \(next.street).")
        }
        if let r = rhythm { parts.append(r) }
        else if parts.isEmpty, stats.group() == .lapsed, let last = stats.lastOrder {
            parts.append("Quiet since \(FieldTime.format(last, "MMMM d")), after \(stats.delivered) shoots together.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// How often this agent books, from the gaps between their paid orders (the middle gap, so one
    /// long holiday doesn't skew it). Says so when they're well past their usual gap.
    private var rhythm: String? {
        let dates = stats.orders.filter { ($0.totalAmount ?? 0) > 0 }
            .compactMap { FieldTime.parse($0.createdAt) }
            .sorted()
        guard dates.count >= 4 else { return nil }
        let gaps = zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) / 86_400 }.filter { $0 >= 1 }.sorted()
        guard !gaps.isEmpty else { return nil }
        let usual = gaps[gaps.count / 2]
        guard usual <= 90, let last = dates.last else { return nil }
        let since = Date().timeIntervalSince(last) / 86_400
        let every = usual < 10 ? "about every \(Int(usual.rounded())) days" : "about every \(max(1, Int((usual / 7).rounded()))) weeks"
        if since > usual * 2, since > 21 {
            let ago = since < 60 ? "\(Int((since / 7).rounded())) weeks" : "\(Int((since / 30).rounded())) months"
            return "Usually books \(every). It's been \(ago), worth a check-in."
        }
        return "Usually books \(every)."
    }
}
