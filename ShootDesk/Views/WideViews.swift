import SwiftUI

// Navigation shared by every tab, plus the Customers table used when the Duo is open.

/// Everywhere you can go from a tab.
enum AppRoute: Hashable {
    case shoot(String), customer(String), tonight, schedule, availability
}

/// Where each route lands. `ns` lets cards zoom into the page they open (iOS 18+).
struct AppDestination: View {
    @Environment(AppModel.self) private var model
    let route: AppRoute
    var ns: Namespace.ID? = nil

    var body: some View {
        switch route {
        case .shoot(let id):
            if let job = model.jobs.first(where: { $0.id == id }) {
                StopDetailView(job: job).id(job.id).zoomDestination(id, in: ns)
            } else {
                ContentUnavailableView("Shoot not found", systemImage: "questionmark")
            }
        case .customer(let id):
            if let c = model.customers.first(where: { $0.id == id }) { CustomerDetailView(stats: c) }
            else { ContentUnavailableView("Agent not found", systemImage: "questionmark") }
        case .tonight:
            TonightView()
        case .schedule:
            ScheduleView()
        case .availability:
            AvailabilityView()
        }
    }
}

extension View {
    /// The standard destination hookup for a tab's NavigationStack.
    func appDestinations(_ ns: Namespace.ID) -> some View {
        navigationDestination(for: AppRoute.self) { AppDestination(route: $0, ns: ns) }
    }

    /// Folded Duo: no title row on a tab's front page. The tab bar already says where you are, and on the narrow
    /// front screen that row is a strip of space with a single word in it (Kyle, Oct 21). Only for pages with no
    /// title-bar buttons; pages you open from it keep their bar and back button.
    func foldedTitleHidden() -> some View { modifier(FoldedTitleHidden()) }

    /// Small solid header bar (no big title, nothing showing through it).
    /// A small, solid title bar. `grouped` matches the grey of a Settings-style list in light mode.
    func slimBar(_ title: String, grouped: Bool = false) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(grouped ? Color(.systemGroupedBackground) : Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - Customers table (open Duo)

struct AgentRow: Identifiable {
    let id: String
    let name: String
    let delivered: Int
    let revenue: Int
    let average: Int
    let last: Date
    let videoPercent: Int

    init(_ c: CustomerStats) {
        id = c.id
        name = c.name
        delivered = c.delivered
        revenue = c.revenueCents
        average = c.averageCents
        last = c.lastOrder ?? .distantPast
        videoPercent = c.delivered > 0 ? Int((Double(c.videoOrders) / Double(c.delivered) * 100).rounded()) : 0
    }
}

struct CustomersTable: View {
    let rows: [AgentRow]
    @Binding var sort: [KeyPathComparator<AgentRow>]
    let open: (String) -> Void
    @State private var selection: AgentRow.ID?

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("Agent", value: \.name) { r in
                HStack(spacing: 10) {
                    Monogram(name: r.name, initials: initials(r.name), size: 30)
                    Text(r.name).font(.body.weight(.medium)).lineLimit(1)
                }
            }
            TableColumn("Shoots", value: \.delivered) { Text("\($0.delivered)").monospacedDigit() }
                .width(70)
            TableColumn("Booked", value: \.revenue) { Text(whole($0.revenue)).monospacedDigit() }
                .width(90)
            TableColumn("Average", value: \.average) { Text($0.delivered > 0 ? whole($0.average) : "—").monospacedDigit() }
                .width(80)
            TableColumn("Last booked", value: \.last) { r in
                Text(r.last == .distantPast ? "—" : FieldTime.format(r.last, "MMM d, yyyy")).monospacedDigit()
            }
            .width(110)
            TableColumn("Video", value: \.videoPercent) { Text($0.delivered > 0 ? "\($0.videoPercent)%" : "—").monospacedDigit() }
                .width(60)
        }
        .onChange(of: selection) { _, id in
            guard let id else { return }
            open(id)
            selection = nil
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// Whole dollars: $19,565, not $19,565.40.
    private func whole(_ cents: Int) -> String { Money.dollars((cents / 100) * 100) }
}

struct FoldedTitleHidden: ViewModifier {
    @Environment(\.horizontalSizeClass) private var size
    func body(content: Content) -> some View {
        content.toolbar(size == .compact ? .hidden : .automatic, for: .navigationBar)
    }
}
