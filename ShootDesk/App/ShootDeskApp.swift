import SwiftUI
import BackgroundTasks

@main
struct ShootDeskApp: App {
    @UIApplicationDelegateAdaptor(QuickActionDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Photos stay on the phone between launches, so listings open instantly (64 MB memory, 2 GB disk).
        // Kyle raised the disk cap to 2 GB on Oct 17 2026. iOS still clears this cache itself when space runs low.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 2 * 1024 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .preferredColorScheme(appearance.colorScheme)
                .task { await model.start() }
                .onOpenURL { model.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.appBecameActive() } }
                    if phase == .background {
                        QuickActions.refreshItems(next: model.nextUpcoming)
                        BackgroundRefresh.schedule()
                    }
                }
                .onAppear { QuickActions.deliverPending(to: model) }
                .onReceive(NotificationCenter.default.publisher(for: QuickActions.notification)) { _ in
                    QuickActions.deliverPending(to: model)
                }
        }
        // iOS wakes the app now and then (it learns when it's usually opened) so the first screen is already fresh.
        .backgroundTask(.appRefresh(BackgroundRefresh.id)) {
            await BackgroundRefresh.run(model)
        }
    }
}

// MARK: - Background refresh

/// Asks iOS to wake ShootDesk between uses and pull the newest orders. iOS decides the real timing:
/// usually fresh, never guaranteed. Needs "fetch" in UIBackgroundModes and the id in BGTaskSchedulerPermittedIdentifiers.
enum BackgroundRefresh {
    static let id = "com.horizonhomemedia.shootdesk.refresh"

    /// One request at a time; asking again just replaces the pending one.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func run(_ model: AppModel) async {
        schedule()   // line up the next one before doing this one
        await model.backgroundRefresh()
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Match iPhone"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Theme {
    /// Horizon azure (#3D9BEA). Adjust here if the brand blue changes.
    static let accent = Color(red: 61 / 255, green: 155 / 255, blue: 234 / 255)
    static let cardCorner: CGFloat = 18
    /// Panels that sit on a plain page: light grey in light mode, dark grey in dark mode.
    static let surface = Color(.secondarySystemBackground)
}


// MARK: - Home Screen quick actions

/// Press and hold the ShootDesk icon: Book a shoot, Open times, and your next shoot by name.
enum QuickActions {
    static let notification = Notification.Name("ShootDeskQuickAction")
    @MainActor static var pending: String?

    @MainActor
    static func receive(_ type: String) {
        pending = type
        NotificationCenter.default.post(name: notification, object: nil)
    }

    @MainActor
    static func deliverPending(to model: AppModel) {
        guard let type = pending else { return }
        pending = nil
        switch type {
        case "book": model.openBooking = true
        case "open": model.openAvailability = true
        default:
            if type.hasPrefix("shoot:") { model.openShootID = String(type.dropFirst(6)) }
        }
    }

    /// Keeps the "next shoot" action current; set each time the app goes to the background.
    @MainActor
    static func refreshItems(next: Job?) {
        var items = [
            UIApplicationShortcutItem(type: "book", localizedTitle: "Book a shoot", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "calendar.badge.plus")),
            UIApplicationShortcutItem(type: "open", localizedTitle: "Open times", localizedSubtitle: "Who to offer what",
                                      icon: UIApplicationShortcutIcon(systemImageName: "clock.badge.checkmark")),
        ]
        if let j = next, let s = j.start {
            let when = FieldTime.isSameDay(s, Date()) ? "Today" :
                (FieldTime.isSameDay(s, FieldTime.addDays(1, to: Date())) ? "Tomorrow" : FieldTime.format(s, "EEE"))
            items.insert(UIApplicationShortcutItem(type: "shoot:\(j.id)", localizedTitle: j.street,
                                                   localizedSubtitle: "\(when) at \(FieldTime.clockAMPM(s))",
                                                   icon: UIApplicationShortcutIcon(systemImageName: "car.fill")), at: 0)
        }
        UIApplication.shared.shortcutItems = items
    }
}

final class QuickActionDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // A quick action that launched the app from scratch.
        if let item = options.shortcutItem {
            Task { @MainActor in QuickActions.receive(item.type) }
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// A quick action while the app was already running in the background.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in QuickActions.receive(shortcutItem.type) }
        completionHandler(true)
    }
}
