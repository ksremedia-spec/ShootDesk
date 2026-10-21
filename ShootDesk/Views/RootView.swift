import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .today

    enum AppTab: String, Hashable { case today, listings, customers, money, ask, settings }

    var body: some View {
        TabView(selection: $tab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.horizon") }
                .tag(AppTab.today)
                .transferPill()
                .badge(model.needsAttentionCount + model.deliveryFlags.count)
            ListingsView()
                .tabItem { Label("Listings", systemImage: "photo.stack") }
                .tag(AppTab.listings)
                .transferPill()
            CustomersView()
                .tabItem { Label("Customers", systemImage: "person.2") }
                .tag(AppTab.customers)
                .transferPill()
            MoneyView()
                .tabItem { Label("Money", systemImage: "dollarsign.circle") }
                .tag(AppTab.money)
                .transferPill()
            AskView()
                .tabItem { Label("Ask", systemImage: "sparkles") }
                .tag(AppTab.ask)
                .transferPill()
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
                .transferPill()
        }
        .onAppear {
            if !model.hasAryeoKey { tab = .settings }
            if model.openShootID != nil || model.openTonight || model.openBooking || model.openAvailability { tab = .today }
            // The cloud build's screenshot tour launches the app once per tab with "-startTab listings" and so on.
            // Nothing in normal use passes this, so it changes nothing on the phone.
            if let wanted = UserDefaults.standard.string(forKey: "startTab"), let start = AppTab(rawValue: wanted) {
                tab = start
            }
        }
        // A tap on the Home Screen widget opens that shoot on the Today tab.
        .onChange(of: model.openShootID) { _, id in
            if id != nil { tab = .today }
        }
        .onChange(of: model.openTonight) { _, open in
            if open { tab = .today }
        }
        .onChange(of: model.openBooking) { _, open in if open { tab = .today } }
        .onChange(of: model.openAvailability) { _, open in if open { tab = .today } }
    }
}
