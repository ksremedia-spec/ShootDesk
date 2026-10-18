import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif
import Observation
import SwiftUI
import WidgetKit
import CoreLocation
import MapKit
import UserNotifications

/// The app's live data. Everything comes straight from Aryeo (and weather / town records / Claude);
/// a saved copy on the phone makes launch instant, then it freshens in the background.
@Observable
@MainActor
final class AppModel {
    // Keys (kept in the keychain)
    var aryeoKey: String = Keychain.get(KeyName.aryeo)
    var claudeKey: String = Keychain.get(KeyName.claude)
    var stripeKey: String = Keychain.get(KeyName.stripe)

    /// Money from Stripe: what actually landed, after fees. Nil until a Stripe key is added.
    private(set) var money: MoneySummary?
    private(set) var moneyError: String?
    @ObservationIgnored private var moneyRanAt: Date?

    // Data
    private(set) var jobs: [Job] = []
    private(set) var customers: [CustomerStats] = []
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    var errorMessage: String?

    // Evening check
    private(set) var checkResults: [CheckResult] = []
    private(set) var checkRanAt: Date?

    // Videos and floor plans, loaded per listing when you open it (orders only carry photos).
    private(set) var media: [String: ListingMedia] = [:]
    private(set) var mediaLoading: Set<String> = []
    private(set) var isChecking = false

    // Shared services
    let weather = WeatherClient()
    let records = PropertyRecordsClient()
    private let store: OrderStore
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var widgetSignature = ""

    /// Set when a Home Screen widget tap asks to open a shoot; the Today tab picks it up.
    var openShootID: String?
    /// Set when the Evening Check widget is tapped; the Today tab opens Tonight.
    var openTonight = false
    /// Home Screen quick actions (press and hold the app icon).
    var openBooking = false
    var openAvailability = false
    @ObservationIgnored private var checkWidgetSignature = ""

    /// "Leave by" times for the next day and a half of shoots, keyed by order id.
    private(set) var leavePlans: [String: LeavePlan] = [:]
    @ObservationIgnored private let leavePlanner = LeavePlanner()
    @ObservationIgnored private var leaveRanAt: Date?
    @ObservationIgnored private var siriSignature = ""

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShootDesk", isDirectory: true)
        store = OrderStore(directory: dir)
        UNUserNotificationCenter.current().delegate = LeaveAlerts.shared
        SiriData.live = self
    }

    var hasAryeoKey: Bool { !aryeoKey.isEmpty }
    var claude: ClaudeClient? { claudeKey.isEmpty ? nil : ClaudeClient(key: claudeKey) }
    var needsAttentionCount: Int { checkResults.filter { $0.needsAttention }.count }

    /// Shoots 2+ days old whose order includes video or a floor plan that hasn't been delivered in Aryeo.
    private(set) var deliveryFlags: [DeliveryFlag] = []
    @ObservationIgnored private var flagsRanAt: Date?
    func flag(for job: Job) -> DeliveryFlag? { deliveryFlags.first { $0.id == job.id } }

    /// Shoots you've told it not to flag (delivered outside Aryeo, or not needed).
    @ObservationIgnored private var dismissedFlags = Set(UserDefaults.standard.stringArray(forKey: "dismissedFlags") ?? [])
    func dismissFlag(_ job: Job) {
        dismissedFlags.insert(job.id)
        UserDefaults.standard.set(Array(dismissedFlags), forKey: "dismissedFlags")
        deliveryFlags.removeAll { $0.id == job.id }
    }

    // MARK: - Lifecycle

    func start() async {
        let store = self.store
        await Task.detached(priority: .userInitiated) { store.loadFromDisk() }.value
        rebuild()
        started = true
        await refresh()
        startPolling()
    }

    func appBecameActive() async {
        // Launch is handled by start(); this only covers coming back to the app later.
        guard started else { return }
        // Where you are may have changed since last time, so redo the drive times.
        if leaveRanAt.map({ Date().timeIntervalSince($0) > 2 * 60 }) ?? true {
            Task { await updateLeaveTimes() }
        }
        guard lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        await refresh()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                await self?.refresh()
            }
        }
    }

    // MARK: - Data

    func refresh(full: Bool = false) async {
        guard hasAryeoKey, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let client = AryeoClient(key: aryeoKey)
            let store = self.store
            try await store.refresh(using: client, forceFull: full)
            rebuild()
            // A widget tap for an order that still isn't here after a fresh download: drop it,
            // so it can't jump to that shoot later out of nowhere.
            if let id = openShootID, !jobs.contains(where: { $0.id == id }) { openShootID = nil }
            lastUpdated = Date()
            errorMessage = nil
            if flagsRanAt.map({ Date().timeIntervalSince($0) > 30 * 60 }) ?? true {
                Task { await checkDeliveries() }
            }
            if moneyRanAt.map({ Date().timeIntervalSince($0) > 10 * 60 }) ?? true {
                Task { await refreshMoney() }
            }
            if leaveRanAt.map({ Date().timeIntervalSince($0) > 10 * 60 }) ?? true {
                Task { await updateLeaveTimes() }
            }
            if checkRanAt.map({ Date().timeIntervalSince($0) > 30 * 60 }) ?? true {
                // Runs on its own so the refresh spinner doesn't wait on the weather calls.
                Task { await runCheck() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A quiet update while the app is in the background: the newest orders, then the widgets.
    /// Kept small (no weather, money or drive times) so it finishes inside the half minute iOS allows.
    func backgroundRefresh() async {
        guard hasAryeoKey, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if !started {
            // Woken from scratch: load the saved copy first so the merge has something to merge into.
            let store = self.store
            await Task.detached(priority: .userInitiated) { store.loadFromDisk() }.value
        }
        do {
            let client = AryeoClient(key: aryeoKey)
            let store = self.store
            try await store.quickRefresh(using: client)
            rebuild()
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            // Background runs fail quietly; the next open refreshes as usual.
        }
    }

    /// Makes a photo the cover for a shoot: its card, the top of its page and Present mode's opening card.
    /// Pass nil to go back to Aryeo's first photo.
    func setCover(_ image: ListingImage?, for job: Job) {
        CoverChoice.set(image?.stableID, for: job.id)
        // Cards read the cover off the job, so hand out fresh jobs to make every card redraw.
        jobs = JobBuilder.jobs(from: store.orders)
    }

    private func rebuild() {
        let orders = store.orders
        jobs = JobBuilder.jobs(from: orders)
        customers = StatsBuilder.customers(from: orders)
        indexForSiriIfNeeded()
        if lastUpdated == nil, let quick = store.lastQuick { lastUpdated = quick }
        reloadWidgetIfNeeded()
    }

    /// Tells Spotlight/Siri about shoots and agents, but only when the set has changed.
    private func indexForSiriIfNeeded() {
        let sig = "\(jobs.count)|\(customers.count)|" + (jobs.map { $0.id + $0.status.rawValue }.joined().hashValue.description)
        guard sig != siriSignature else { return }
        siriSignature = sig
        SiriData.index(jobs: jobs, customers: customers)
    }

    /// Asks the Home Screen widget to redraw, but only when something it shows has changed
    /// (iOS limits how often a widget can reload).
    private func reloadWidgetIfNeeded() {
        let sig = NextShoots.signature(NextShoots.upcoming(from: jobs))
        guard sig != widgetSignature else { return }
        widgetSignature = sig
        WidgetCenter.shared.reloadTimelines(ofKind: NextShoots.widgetKind)
    }

    // MARK: - Leave by

    /// Works out when to leave for each shoot in the next 36 hours and schedules a reminder for each.
    /// The first shoot of a day is timed from where the phone is now; a back-to-back shoot from the one before it.
    func updateLeaveTimes() async {
        leaveRanAt = Date()
        let now = Date()
        let upcoming = jobs.filter { j in
            guard j.status != .delivered, let s = j.start, j.latitude != nil, j.longitude != nil else { return false }
            return s > now && s < now.addingTimeInterval(36 * 3600)
        }
        .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        guard !upcoming.isEmpty else {
            leavePlans = [:]
            await LeaveAlerts.schedule([])
            #if canImport(ActivityKit)
            await ShootLiveActivity.sync(job: nil, plan: nil)
            #endif
            return
        }
        let here = await leavePlanner.currentLocation()
        var plans: [String: LeavePlan] = [:]
        var alerts: [(Job, LeavePlan)] = []
        for (i, job) in upcoming.enumerated() {
            guard let start = job.start, let lat = job.latitude, let lon = job.longitude else { continue }
            let prev = upcoming[..<i].last { p in p.start.map { FieldTime.isSameDay($0, start) } ?? false }
            let origin: CLLocationCoordinate2D
            if let p = prev, let plat = p.latitude, let plon = p.longitude {
                origin = CLLocationCoordinate2D(latitude: plat, longitude: plon)
            } else if let here {
                origin = here.coordinate
            } else { continue }
            let arriveBy = start.addingTimeInterval(-LeavePlanner.arriveEarly)
            guard let travel = await LeavePlanner.driveTime(from: origin,
                                                            to: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                                            arriveBy: arriveBy),
                  travel < 3 * 3600 else { continue }   // hours away means you're not nearby; don't guess
            let plan = LeavePlan(travel: travel, leaveAt: arriveBy.addingTimeInterval(-travel),
                                 afterShoot: prev.map { $0.end ?? $0.start?.addingTimeInterval(3600) ?? start })
            plans[job.id] = plan
            alerts.append((job, plan))
        }
        leavePlans = plans
        await LeaveAlerts.schedule(alerts)
        #if canImport(ActivityKit)
        if let next = upcoming.first(where: { plans[$0.id] != nil }) {
            await ShootLiveActivity.sync(job: next, plan: plans[next.id])
        } else {
            await ShootLiveActivity.sync(job: nil, plan: nil)
        }
        #endif
    }

    // MARK: - Widget links

    func handle(_ url: URL) {
        switch NextShoots.parse(url) {
        case .shoot(let id)?:
            openShootID = id
        case .directions(let lat, let lon, let address)?:
            Launcher.directions(lat: lat, lon: lon, address: address)
        case .tonight?:
            openTonight = true
        case nil:
            break
        }
    }

    func runCheck() async {
        guard !jobs.isEmpty, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let check = EveningCheck(weather: weather)
        checkResults = await check.run(jobs: jobs, customers: customers)
        checkRanAt = Date()
        await MorningBriefing.schedule(jobs: visibleJobs, checks: checkResults)
        // Keep the Evening Check widget in step with what Tonight shows.
        let sig = CheckWidget.signature(checkResults)
        if sig != checkWidgetSignature {
            checkWidgetSignature = sig
            WidgetCenter.shared.reloadTimelines(ofKind: CheckWidget.widgetKind)
        }
    }

    // MARK: - Lookups

    func stats(for name: String) -> CustomerStats? {
        let key = Rules.normalizedName(name)
        return customers.first { $0.id == key }
    }

    func shoots(on day: Date) -> [Job] { JobBuilder.shoots(on: day, in: visibleJobs) }

    var visibleJobs: [Job] { jobs.filter { $0.status != .stale } }

    /// What Stripe knows, written out for Ask: monthly totals, payouts, and recent payments by order.
    func moneyContext() -> String? {
        guard let m = money else { return nil }
        let cal = FieldTime.calendar
        var lines = ["STRIPE (money actually received, US dollars, after Stripe fees)"]
        lines.append("Available now: \(m.available / 100). On the way: \(m.pending / 100).")
        var months: [String: (net: Int, fees: Int, count: Int)] = [:]
        for t in m.transactions {
            let k = FieldTime.format(t.created, "yyyy-MM")
            var v = months[k] ?? (0, 0, 0)
            v.net += t.net; v.fees += t.fee; if t.isPayment { v.count += 1 }
            months[k] = v
        }
        lines.append("\nSTRIPE MONTHS (month | received | fees | payments)")
        for k in months.keys.sorted() { let v = months[k]!; lines.append("\(k) | \(v.net / 100) | \(v.fees / 100) | \(v.count)") }
        lines.append("\nPAYOUTS TO BANK (arrival | amount | status)")
        for p in m.payouts.prefix(30) { lines.append("\(FieldTime.format(p.arrival, "yyyy-MM-dd")) | \(p.amount / 100) | \(p.status)") }
        lines.append("\nRECENT PAYMENTS (date | received | fee | description)")
        let cutoff = cal.date(byAdding: .day, value: -120, to: Date()) ?? Date()
        for t in m.transactions where (t.isPayment || t.isRefund) && t.created > cutoff {
            lines.append("\(FieldTime.format(t.created, "yyyy-MM-dd")) | \(Double(t.net) / 100) | \(Double(t.fee) / 100) | \(t.description)")
        }
        return lines.joined(separator: "\n")
    }

    /// The next shoot that hasn't finished yet.
    var nextUpcoming: Job? {
        let now = Date()
        return jobs.filter { j in
            guard j.status == .booked, let s = j.start else { return false }
            return (j.end ?? s.addingTimeInterval(3600)) > now
        }
        .min { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    // MARK: - Listing media

    func loadMedia(for job: Job) async {
        guard hasAryeoKey, let id = job.order.listing?.id, media[id] == nil, !mediaLoading.contains(id) else { return }
        mediaLoading.insert(id)
        defer { mediaLoading.remove(id) }
        if let m = try? await AryeoClient(key: aryeoKey).listingMedia(listingID: id) { media[id] = m }
    }

    // MARK: - Missing video / floor plans

    /// Looks at shoots from 2 to 30 days ago. If the order has video or a floor plan and Aryeo has none
    /// delivered on the listing, it's flagged (and you get one notification for it).
    func checkDeliveries() async {
        flagsRanAt = Date()
        guard hasAryeoKey else { return }
        let now = Date()
        let candidates = jobs.filter { j in
            guard j.status != .stale, j.order.listing?.id != nil, j.hasVideo || j.hasFloorPlan,
                  let end = j.end ?? j.start?.addingTimeInterval(3600) else { return false }
            return end < now.addingTimeInterval(-2 * 86_400) && end > now.addingTimeInterval(-30 * 86_400)
        }
        let client = AryeoClient(key: aryeoKey)
        var out: [DeliveryFlag] = []
        for j in candidates {
            guard let id = j.order.listing?.id,
                  let m = try? await client.listingMedia(listingID: id) else { continue }
            media[id] = m   // fresh copy, so the listing screen shows what's really there
            // Only shoots that really happened: the photos are delivered in Aryeo. Orders that were never shot
            // or never properly canceled have no photos, so they're left alone.
            guard !m.images.isEmpty, !dismissedFlags.contains(j.id) else { continue }
            var missing: [String] = []
            if j.hasVideo && m.videos.isEmpty { missing.append("video") }
            if j.hasFloorPlan && m.floorPlans.isEmpty { missing.append("floor plan") }
            if !missing.isEmpty { out.append(DeliveryFlag(job: j, missing: missing)) }
        }
        deliveryFlags = out.sorted { ($0.job.start ?? .distantPast) < ($1.job.start ?? .distantPast) }
        await DeliveryAlerts.notify(deliveryFlags)
    }

    // MARK: - Keys

    func refreshMoney() async {
        moneyRanAt = Date()
        guard !stripeKey.isEmpty else { money = nil; moneyError = nil; return }
        do {
            money = try await StripeClient.summary(key: stripeKey)
            moneyError = nil
        } catch {
            moneyError = error.localizedDescription
        }
    }

    func saveKeys(aryeo: String, claude: String, stripe: String) async {
        Keychain.set(aryeo, for: KeyName.aryeo)
        Keychain.set(claude, for: KeyName.claude)
        Keychain.set(stripe, for: KeyName.stripe)
        let stripeChanged = stripe.trimmingCharacters(in: .whitespacesAndNewlines) != stripeKey
        stripeKey = Keychain.get(KeyName.stripe)
        if stripeChanged { await refreshMoney() }
        let aryeoChanged = aryeo.trimmingCharacters(in: .whitespacesAndNewlines) != aryeoKey
        aryeoKey = Keychain.get(KeyName.aryeo)
        claudeKey = Keychain.get(KeyName.claude)
        if aryeoChanged {
            // The widgets share this key; let them pick up the new one right away.
            WidgetCenter.shared.reloadAllTimelines()
            await refresh(full: true)
        }
    }
}


// MARK: - Leave by

struct LeavePlan: Hashable {
    /// Drive time in seconds (Apple Maps, with expected traffic).
    let travel: TimeInterval
    /// When to leave to arrive `LeavePlanner.arriveEarly` before the start.
    let leaveAt: Date
    /// For a back-to-back shoot: when the shoot before it ends.
    let afterShoot: Date?

    var driveLabel: String {
        let m = Int((travel / 60).rounded())
        return m < 60 ? "\(m) min drive" : "\(m / 60) hr \(m % 60) min drive"
    }
}

/// Finds where the phone is (once, when asked) and asks Apple Maps for drive times.
@MainActor
final class LeavePlanner: NSObject, CLLocationManagerDelegate {
    /// How early you want to get there.
    static let arriveEarly: TimeInterval = 10 * 60

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// The phone's location, or nil if location is off or it takes longer than 15 seconds.
    func currentLocation() async -> CLLocation? {
        guard waiting == nil else { return manager.location }
        return await withCheckedContinuation { c in
            waiting = c
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            default: finish(nil)
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.finish(self?.manager.location)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        waiting?.resume(returning: location)
        waiting = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.waiting != nil else { return }
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .notDetermined: break
            default: self.finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(self.manager.location) }
    }

    static func driveTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, arriveBy: Date) async -> TimeInterval? {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType = .automobile
        if arriveBy > Date() { req.arrivalDate = arriveBy }
        return try? await MKDirections(request: req).calculateETA().expectedTravelTime
    }
}

/// The "time to leave" notifications. Each run replaces the ones from the run before.
final class LeaveAlerts: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = LeaveAlerts()
    private static let prefix = "leave-"

    @MainActor
    static func schedule(_ items: [(Job, LeavePlan)]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard !items.isEmpty else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let now = Date()
        for (job, plan) in items {
            guard let start = job.start else { continue }
            // Back-to-back: never nag before the shoot you're on has ended.
            let fire = max(plan.leaveAt, plan.afterShoot ?? plan.leaveAt)
            guard fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Leave now for \(job.street)"
            content.body = "\(plan.driveLabel) to \(job.town). Starts at \(FieldTime.clockAMPM(start))."
            content.sound = .default
            content.userInfo = ["url": NextShoots.shootURL(orderID: job.id)?.absoluteString ?? ""]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + job.id, content: content, trigger: trigger))
        }
    }

    // Show it even when ShootDesk is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Tapping it opens that shoot.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        completionHandler()
    }
}


// MARK: - Morning briefing

/// A 7 AM notification on shoot days: what's on, where, and anything the upcoming check flagged.
/// Rewritten every time the app checks, so it's as fresh as the last time ShootDesk ran.
enum MorningBriefing {
    static let id = "morning-briefing"

    @MainActor
    static func schedule(jobs: [Job], checks: [CheckResult]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard UserDefaults.standard.object(forKey: "morningBriefing") as? Bool ?? true else { return }
        let now = Date()
        let cal = Calendar.current
        guard var fire = cal.date(bySettingHour: 7, minute: 0, second: 0, of: now) else { return }
        if fire <= now, let next = cal.date(byAdding: .day, value: 1, to: fire) { fire = next }
        let shoots = jobs.filter { j in
            guard j.status == .booked, let s = j.start else { return false }
            return cal.isDate(s, inSameDayAs: fire)
        }
        .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        guard !shoots.isEmpty else { return }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = shoots.count == 1 ? "1 shoot today" : "\(shoots.count) shoots today"
        var lines = shoots.prefix(4).map { j in
            "\(j.start.map { FieldTime.clockAMPM($0) } ?? "")  \(j.street)\(j.town.isEmpty ? "" : ", \(j.town)")"
        }
        if shoots.count > 4 { lines.append("and \(shoots.count - 4) more") }
        let ids = Set(shoots.map(\.id))
        let issues = checks.filter { ids.contains($0.job.id) }.flatMap(\.issues).map(\.title)
        if let first = issues.first {
            lines.append("Heads up: \(first.prefix(1).lowercased() + first.dropFirst())\(issues.count > 1 ? ", and \(issues.count - 1) more" : "").")
        }
        content.body = lines.joined(separator: "\n")
        content.sound = .default
        content.userInfo = ["url": NextShoots.shootURL(orderID: shoots[0].id)?.absoluteString ?? ""]
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }
}

// MARK: - Stripe (read-only)

struct StripeTxn: Identifiable, Hashable {
    let id: String
    let type: String          // charge, payment, refund, payment_refund, adjustment
    let amount: Int           // cents, before fees (negative for refunds)
    let fee: Int
    let net: Int
    let created: Date
    let description: String
    var isPayment: Bool { type == "charge" || type == "payment" }
    var isRefund: Bool { type == "refund" || type == "payment_refund" }
}

struct StripePayout: Identifiable, Hashable {
    let id: String
    let amount: Int        // cents
    let arrival: Date
    let status: String     // paid, pending, in_transit, canceled, failed
}

/// What actually reached your Stripe account. All amounts in cents.
struct MoneySummary: Hashable {
    var available = 0
    var pending = 0
    var monthNet = 0, monthFees = 0, monthPayments = 0
    var yearNet = 0, yearFees = 0, yearPayments = 0
    var payouts: [StripePayout] = []
    /// Payments, refunds and adjustments since January 1 of last year, newest first.
    var transactions: [StripeTxn] = []
    var checkedAt = Date()

    /// The next payout still on its way to the bank, if any.
    var nextPayout: StripePayout? {
        payouts.filter { $0.status == "pending" || $0.status == "in_transit" }.min { $0.arrival < $1.arrival }
    }
    var lastPayout: StripePayout? {
        payouts.filter { $0.status == "paid" }.max { $0.arrival < $1.arrival }
    }
}

/// Reads balance, payouts and payments from Stripe with a restricted, read-only key. Never moves money.
enum StripeClient {
    enum Failure: LocalizedError {
        case rejected(Int, String)
        case wrongKind(String)
        var errorDescription: String? {
            switch self {
            case .wrongKind(let why): return why
            case .rejected(401, let msg): return "Stripe didn't accept the key: \(msg)"
            case .rejected(403, let msg): return "The key needs Read access to Balance, Balance transactions and Payouts. Stripe said: \(msg)"
            case .rejected(let code, let msg): return "Stripe error \(code): \(msg)"
            }
        }
    }

    /// Catches the common mix-ups before asking Stripe (only looks at the key's prefix).
    static func checkKind(_ key: String) throws {
        if key.hasPrefix("pk_") {
            throw Failure.wrongKind("That's a publishable key (starts with pk_). ShootDesk needs a restricted key, which starts with rk_live_.")
        }
        if key.hasPrefix("rk_test_") || key.hasPrefix("sk_test_") {
            throw Failure.wrongKind("That's a test-mode key, so it can't see real payments. Make the restricted key with Test mode switched off (it starts with rk_live_).")
        }
        if !(key.hasPrefix("rk_") || key.hasPrefix("sk_")) {
            throw Failure.wrongKind("That doesn't look like a Stripe secret or restricted key (they start with rk_live_ or sk_live_). Copy it again from Developers › API keys.")
        }
    }

    static func summary(key: String) async throws -> MoneySummary {
        try checkKind(key)
        var out = MoneySummary()

        let balance = try await get("balance", [], key: key)
        func sum(_ k: String) -> Int {
            (balance[k] as? [[String: Any]] ?? []).filter { ($0["currency"] as? String) == "usd" }
                .reduce(0) { $0 + ($1["amount"] as? Int ?? 0) }
        }
        out.available = sum("available")
        out.pending = sum("pending")

        let payouts = try await get("payouts", [URLQueryItem(name: "limit", value: "100")], key: key)
        out.payouts = (payouts["data"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? String, let amount = p["amount"] as? Int,
                  let arrival = p["arrival_date"] as? Int else { return nil }
            return StripePayout(id: id, amount: amount, arrival: Date(timeIntervalSince1970: TimeInterval(arrival)),
                                status: p["status"] as? String ?? "")
        }

        // Every payment, refund and fee since January 1 of last year (so this year can be compared).
        let cal = FieldTime.calendar
        let now = Date()
        let yearStart = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
        let fetchFrom = cal.date(byAdding: .year, value: -1, to: yearStart) ?? yearStart
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        var after: String?
        for _ in 0..<60 {
            var q = [URLQueryItem(name: "limit", value: "100"),
                     URLQueryItem(name: "created[gte]", value: String(Int(fetchFrom.timeIntervalSince1970)))]
            if let after { q.append(URLQueryItem(name: "starting_after", value: after)) }
            let page = try await get("balance_transactions", q, key: key)
            let rows = page["data"] as? [[String: Any]] ?? []
            for t in rows {
                let type = t["type"] as? String ?? ""
                // Money in and money given back; payouts and transfers are just money moving to the bank.
                guard ["charge", "payment", "refund", "payment_refund", "adjustment"].contains(type) else { continue }
                let net = t["net"] as? Int ?? 0
                let fee = t["fee"] as? Int ?? 0
                let created = Date(timeIntervalSince1970: TimeInterval(t["created"] as? Int ?? 0))
                let isPayment = type == "charge" || type == "payment"
                out.transactions.append(StripeTxn(id: t["id"] as? String ?? UUID().uuidString, type: type,
                                                  amount: t["amount"] as? Int ?? 0, fee: fee, net: net, created: created,
                                                  description: t["description"] as? String ?? ""))
                guard created >= yearStart else { continue }
                out.yearNet += net; out.yearFees += fee; if isPayment { out.yearPayments += 1 }
                if created >= monthStart {
                    out.monthNet += net; out.monthFees += fee; if isPayment { out.monthPayments += 1 }
                }
            }
            guard page["has_more"] as? Bool == true, let last = rows.last?["id"] as? String else { break }
            after = last
        }
        out.checkedAt = Date()
        return out
    }

    private static func get(_ path: String, _ query: [URLQueryItem], key: String) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://api.stripe.com/v1/" + path)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.timeoutInterval = 30
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown"
            throw Failure.rejected(code, msg)
        }
        return json
    }
}


// MARK: - Missing deliverables

struct DeliveryFlag: Identifiable, Hashable {
    let job: Job
    let missing: [String]   // "video", "floor plan"
    var id: String { job.id }
    /// "No video yet", "No video or floor plan yet"
    var line: String { "No " + missing.joined(separator: " or ") + " yet" }
    var shotLine: String { job.start.map { "Shot \(FieldTime.format($0, "EEE MMM d"))" } ?? "" }
}

/// One notification per shoot per missing thing, the first time it's found.
enum DeliveryAlerts {
    private static let key = "notifiedMissing"

    @MainActor
    static func notify(_ flags: [DeliveryFlag]) async {
        var done = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let fresh = flags.filter { !done.contains($0.id + $0.missing.joined()) }
        guard !fresh.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        for f in fresh {
            let content = UNMutableNotificationContent()
            content.title = "\(f.job.street): \(f.line.lowercased())"
            content.body = "\(f.shotLine) for \(f.job.agentName). The order includes \(f.missing.joined(separator: " and ")), but nothing's delivered in Aryeo."
            content.sound = .default
            content.userInfo = ["url": NextShoots.shootURL(orderID: f.job.id)?.absoluteString ?? ""]
            try? await center.add(UNNotificationRequest(identifier: "missing-" + f.id, content: content, trigger: nil))
            done.insert(f.id + f.missing.joined())
        }
        UserDefaults.standard.set(Array(done), forKey: key)
    }
}

// MARK: - Live Activity

#if canImport(ActivityKit)

/// Puts the next shoot on the Lock Screen from a few hours before you need to leave until it starts.
enum ShootLiveActivity {
    /// How long before the leave-by time the Lock Screen card appears.
    static let showBefore: TimeInterval = 3 * 3600

    @MainActor
    static func sync(job: Job?, plan: LeavePlan?) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let running = Activity<ShootActivityAttributes>.activities
        let now = Date()
        guard let job, let plan, let start = job.start,
              now >= plan.leaveAt.addingTimeInterval(-showBefore), now < start else {
            for a in running { await a.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let state = ShootActivityAttributes.ContentState(leaveAt: plan.leaveAt, start: start, drive: plan.driveLabel)
        let content = ActivityContent(state: state, staleDate: start.addingTimeInterval(30 * 60))
        if let mine = running.first(where: { $0.attributes.orderID == job.id }) {
            await mine.update(content)
            for a in running where a.id != mine.id { await a.end(nil, dismissalPolicy: .immediate) }
        } else {
            for a in running { await a.end(nil, dismissalPolicy: .immediate) }
            let attributes = ShootActivityAttributes(orderID: job.id, street: job.street, town: job.town, agent: job.agentName)
            _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        }
    }
}
#endif
