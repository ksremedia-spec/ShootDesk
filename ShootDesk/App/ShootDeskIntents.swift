import AppIntents
import CoreSpotlight
import Foundation
import UIKit

// Everything Siri (and Shortcuts, and Spotlight) can ask ShootDesk.
// Read-only: nothing here changes anything in Aryeo.

// MARK: - Data

/// Where Siri's answers come from: the open app's live data, or the copy saved on the phone
/// (freshened from Aryeo first) when the app isn't running.
@MainActor
enum SiriData {
    static weak var live: AppModel?

    static func jobs() async -> [Job] {
        if let m = live, !m.jobs.isEmpty { return m.jobs }
        return await load().jobs
    }

    static func customers() async -> [CustomerStats] {
        if let m = live, !m.customers.isEmpty { return m.customers }
        return await load().customers
    }

    private static func load() async -> (jobs: [Job], customers: [CustomerStats]) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShootDesk", isDirectory: true)
        let store = OrderStore(directory: dir)
        await Task.detached(priority: .userInitiated) { store.loadFromDisk() }.value
        let key = Keychain.get(KeyName.aryeo)
        if !key.isEmpty { _ = try? await store.refresh(using: AryeoClient(key: key)) }
        let orders = store.orders
        return (JobBuilder.jobs(from: orders), StatsBuilder.customers(from: orders))
    }

    static func shoots(on day: Date) async -> [Job] {
        await jobs()
            .filter { j in j.start.map { FieldTime.isSameDay($0, day) } ?? false }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    static func nextShoot() async -> Job? {
        let now = Date()
        return await jobs()
            .filter { j in
                guard j.status != .delivered, let s = j.start else { return false }
                return (j.end ?? s.addingTimeInterval(3600)) > now
            }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            .first
    }

    static func job(id: String) async -> Job? { await jobs().first { $0.id == id } }

    /// "10:30 AM at 27-29 Willow St in New Bedford for Jenna Danielli"
    static func spoken(_ j: Job) -> String {
        let time = j.start.map { FieldTime.clockAMPM($0) } ?? "No time yet"
        let town = j.town.isEmpty ? "" : " in \(j.town)"
        return "\(time) at \(j.street)\(town) for \(j.agentName)"
    }

    static func dayName(_ d: Date) -> String {
        let now = Date()
        if FieldTime.isSameDay(d, now) { return "today" }
        if FieldTime.isSameDay(d, FieldTime.addDays(1, to: now)) { return "tomorrow" }
        return FieldTime.format(d, "EEEE, MMMM d")
    }

    /// Keeps Spotlight's index (which Siri searches by meaning) in step with the app's shoots and agents.
    static func index(jobs: [Job], customers: [CustomerStats]) {
        guard #available(iOS 18, *) else { return }
        let shoots = jobs.filter { $0.status != .stale }.map(ShootEntity.init(job:))
        let agents = customers.map(AgentEntity.init(stats:))
        Task.detached(priority: .utility) {
            try? await CSSearchableIndex.default().indexAppEntities(shoots)
            try? await CSSearchableIndex.default().indexAppEntities(agents)
        }
    }
}

// MARK: - Days

enum ShootDay: String, AppEnum {
    case today, tomorrow, monday, tuesday, wednesday, thursday, friday, saturday, sunday

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Day"
    static let caseDisplayRepresentations: [ShootDay: DisplayRepresentation] = [
        .today: "today", .tomorrow: "tomorrow", .monday: "Monday", .tuesday: "Tuesday",
        .wednesday: "Wednesday", .thursday: "Thursday", .friday: "Friday", .saturday: "Saturday", .sunday: "Sunday",
    ]

    /// The date this means: weekdays are the next one coming up (today counts).
    var date: Date {
        let now = Date()
        switch self {
        case .today: return now
        case .tomorrow: return FieldTime.addDays(1, to: now)
        default:
            let order: [ShootDay] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
            let target = (order.firstIndex(of: self) ?? 0) + 1
            let current = FieldTime.calendar.component(.weekday, from: now)
            return FieldTime.addDays((target - current + 7) % 7, to: now)
        }
    }
}

// MARK: - Entities

struct ShootEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Shoot"
    static let defaultQuery = ShootQuery()

    let id: String
    @Property(title: "Address") var street: String
    @Property(title: "Town") var town: String
    @Property(title: "Agent") var agent: String
    @Property(title: "Start") var start: Date?
    @Property(title: "Package") var package: String
    @Property(title: "Status") var status: String

    init(job: Job) {
        id = job.id
        street = job.street
        town = job.town
        agent = job.agentName
        start = job.start
        package = job.packageSummary
        status = job.status.label
    }

    var displayRepresentation: DisplayRepresentation {
        let when = start.map { "\(FieldTime.format($0, "EEE MMM d")), \(FieldTime.clockAMPM($0))" } ?? "No time yet"
        return DisplayRepresentation(title: "\(street)", subtitle: "\(when), \(town), \(agent)")
    }
}

struct ShootQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShootEntity] {
        let jobs = await SiriData.jobs()
        return identifiers.compactMap { id in jobs.first { $0.id == id }.map(ShootEntity.init(job:)) }
    }

    func entities(matching string: String) async throws -> [ShootEntity] {
        let words = string.lowercased().split(separator: " ").map(String.init)
        return await SiriData.jobs()
            .filter { j in
                let text = "\(j.street) \(j.town) \(j.agentName) \(j.number)".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
            .prefix(20)
            .map(ShootEntity.init(job:))
    }

    /// Upcoming shoots first.
    func suggestedEntities() async throws -> [ShootEntity] {
        let now = Date()
        return await SiriData.jobs()
            .filter { ($0.start ?? .distantPast) > now.addingTimeInterval(-12 * 3600) }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            .prefix(20)
            .map(ShootEntity.init(job:))
    }
}

struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentQuery()

    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Delivered shoots") var delivered: Int
    @Property(title: "Last booked") var lastOrder: Date?

    init(stats: CustomerStats) {
        id = stats.id
        name = stats.name
        delivered = stats.delivered
        lastOrder = stats.lastOrder
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(delivered) delivered")
    }
}

struct AgentQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        let all = await SiriData.customers()
        return identifiers.compactMap { id in all.first { $0.id == id }.map(AgentEntity.init(stats:)) }
    }

    func entities(matching string: String) async throws -> [AgentEntity] {
        // Shorthand works: "Tiff", "tiffany", "Smith".
        Booker.agents(matching: string, in: await SiriData.customers())
            .prefix(20)
            .map(AgentEntity.init(stats:))
    }

    /// Busiest agents first.
    func suggestedEntities() async throws -> [AgentEntity] {
        await SiriData.customers()
            .sorted { $0.delivered > $1.delivered }
            .prefix(40)
            .map(AgentEntity.init(stats:))
    }
}

@available(iOS 18, *)
extension ShootEntity: IndexedEntity {}

@available(iOS 18, *)
extension AgentEntity: IndexedEntity {}

// MARK: - Questions

struct ShootsOnDayIntent: AppIntent {
    static let title: LocalizedStringResource = "Shoots on a Day"
    static let description = IntentDescription("Lists your shoots for a day: time, address and agent.")

    @Parameter(title: "Day", default: .tomorrow) var day: ShootDay

    static var parameterSummary: some ParameterSummary { Summary("Shoots \(\.$day)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ShootEntity]> & ProvidesDialog {
        let date = day.date
        let list = await SiriData.shoots(on: date)
        let name = SiriData.dayName(date)
        let text: String
        switch list.count {
        case 0: text = "Nothing booked \(name)."
        case 1: text = "One shoot \(name): \(SiriData.spoken(list[0]))."
        default: text = "\(list.count) shoots \(name). " + list.map { SiriData.spoken($0) + "." }.joined(separator: " ")
        }
        return .result(value: list.map(ShootEntity.init(job:)), dialog: "\(text)")
    }
}

struct OpenTimesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Times on a Day"
    static let description = IntentDescription(
        "Finds the free gaps in a day between 8 AM and sunset, leaving 30 minutes before and after each booked shoot for driving.")

    @Parameter(title: "Day", default: .tomorrow) var day: ShootDay
    @Parameter(title: "Minutes needed", default: 90) var minutes: Int

    static var parameterSummary: some ParameterSummary { Summary("Open times \(\.$day) for \(\.$minutes) minutes") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let date = day.date
        let open = Availability.day(date, jobs: await SiriData.jobs())
        let fits = open.fitting(max(minutes, 15))
        let name = SiriData.dayName(date)
        let bookedText = open.busy.isEmpty ? "Nothing booked yet." :
            "Booked: " + open.busy.map { "\(FieldTime.clockAMPM($0.from)) \($0.job.street)" }.joined(separator: ", ") + "."
        let text: String
        if fits.isEmpty {
            text = "No \(minutes)-minute openings \(name) between 8 AM and sunset. \(bookedText)"
        } else {
            let list = fits.map { "\(FieldTime.clockAMPM($0.start)) to \(FieldTime.clockAMPM($0.end))" }.joined(separator: ", and ")
            text = "\(name.prefix(1).uppercased() + name.dropFirst()) you're open \(list). \(bookedText)"
        }
        return .result(dialog: "\(text)")
    }
}

struct NextShootIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Shoot"
    static let description = IntentDescription("Tells you your next shoot and when to leave for it.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let j = await SiriData.nextShoot(), let s = j.start else {
            return .result(dialog: "Nothing booked coming up.")
        }
        var text = "Your next shoot is \(SiriData.dayName(s)) at \(SiriData.spoken(j))."
        if let plan = SiriData.live?.leavePlans[j.id], plan.leaveAt > Date() {
            text += " Leave by \(FieldTime.clockAMPM(plan.leaveAt)), it's a \(plan.driveLabel)."
        }
        return .result(dialog: "\(text)")
    }
}

struct CheckShootsIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Upcoming Shoots"
    static let description = IntentDescription(
        "Runs the evening check on the next shoots: weather, wind for drone, airspace, agent emails, sunset and missing times.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let check: WidgetCheck
        if let m = SiriData.live, !m.checkResults.isEmpty {
            check = CheckWidget.make(from: m.checkResults, at: Date())
        } else {
            let key = Keychain.get(KeyName.aryeo)
            guard !key.isEmpty else { return .result(dialog: "Add your Aryeo key in ShootDesk first.") }
            check = try await CheckWidget.run(aryeo: AryeoClient(key: key), weather: WeatherClient())
        }
        if check.items.isEmpty { return .result(dialog: "Nothing booked in the next couple of days.") }
        var text = "\(check.headline). \(check.subline)."
        let now = Date()
        for item in check.needsYou {
            text += " \(item.whenLabel(at: now)), \(item.street): " + item.issues.map(\.title).joined(separator: "; ") + "."
            if let move = item.suggestionLine { text += " \(move)." }
        }
        if check.needsYou.isEmpty && !check.weatherUnknown.isEmpty { text += " I couldn't get the forecast." }
        return .result(dialog: "\(text)")
    }
}

struct AgentStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Agent History"
    static let description = IntentDescription("How much an agent books with you: shoots, spend, video and when they last booked.")

    @Parameter(title: "Agent") var agent: AgentEntity

    static var parameterSummary: some ParameterSummary { Summary("History for \(\.$agent)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let c = await SiriData.customers().first(where: { $0.id == agent.id }) else {
            return .result(dialog: "I couldn't find \(agent.name).")
        }
        var text = "\(c.name): \(c.delivered) delivered shoot\(c.delivered == 1 ? "" : "s"), "
        text += "\(Money.dollars(c.revenueCents)) total, about \(Money.dollars(c.averageCents)) each."
        if c.videoOrders > 0 { text += " Added video \(c.videoOrders) time\(c.videoOrders == 1 ? "" : "s")." }
        if let d = c.daysSinceLastOrder() { text += d == 0 ? " Booked today." : " Last booked \(d) day\(d == 1 ? "" : "s") ago." }
        switch c.group() {
        case .active: text += " Active."
        case .lapsed: text += " Lapsed, so worth a check-in."
        case .new: text += " New, nothing delivered yet."
        case .occasional: text += " Occasional."
        }
        return .result(dialog: "\(text)")
    }
}

struct AskShootDeskIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask ShootDesk"
    static let description = IntentDescription(
        "Ask anything about your business in plain English. Claude answers from your Aryeo data.")

    @Parameter(title: "Question", requestValueDialog: "What do you want to know?") var question: String

    static var parameterSummary: some ParameterSummary { Summary("Ask \(\.$question)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let key = Keychain.get(KeyName.claude)
        guard !key.isEmpty else { return .result(dialog: "Add your Claude key in ShootDesk's Settings first.") }
        let answer = try await AskContext.ask(question, history: [],
                                              jobs: await SiriData.jobs().filter { $0.status != .stale },
                                              customers: await SiriData.customers(),
                                              claude: ClaudeClient(key: key))
        // Siri reads it out, so drop markdown symbols.
        let plain = answer.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
        return .result(dialog: "\(plain)")
    }
}

// MARK: - Actions

struct OpenShootIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Shoot"
    static let description = IntentDescription("Opens a shoot's order sheet in ShootDesk.")

    @Parameter(title: "Shoot") var target: ShootEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = NextShoots.shootURL(orderID: target.id) { await UIApplication.shared.open(url) }
        return .result()
    }
}

struct DirectionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Directions to Shoot"
    static let description = IntentDescription("Starts directions to a shoot (your next one if you don't pick).")
    static let openAppWhenRun = true

    @Parameter(title: "Shoot") var shoot: ShootEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var found: Job? = nil
        if let shoot { found = await SiriData.job(id: shoot.id) }
        if found == nil { found = await SiriData.nextShoot() }
        guard let job = found else { return .result(dialog: "Nothing booked coming up.") }
        Launcher.directions(to: job)
        return .result(dialog: "Directions to \(job.street).")
    }
}

struct TextAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Text the Agent"
    static let description = IntentDescription(
        "Opens a text to a shoot's agent (your next shoot if you don't pick). On the day of the shoot it starts with your on-my-way message.")
    static let openAppWhenRun = true

    @Parameter(title: "Shoot") var shoot: ShootEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var found: Job? = nil
        if let shoot { found = await SiriData.job(id: shoot.id) }
        if found == nil { found = await SiriData.nextShoot() }
        guard let job = found else { return .result(dialog: "Nothing booked coming up.") }
        guard job.agentPhone != nil else { return .result(dialog: "There's no phone number for \(job.agentName).") }
        let body = job.start.map { FieldTime.isSameDay($0, Date()) } == true ? Drafts.onMyWay(job: job) : nil
        Launcher.open(Phone.textURL(job.agentPhone, body: body))
        return .result(dialog: "Texting \(job.agentName).")
    }
}

// MARK: - Phrases (also work with the older Siri; the new Siri understands plain requests without them)

struct ShootDeskShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShootsOnDayIntent(), phrases: [
            "What shoots do I have \(\.$day) in \(.applicationName)",
            "\(.applicationName) shoots \(\.$day)",
            "What's on \(.applicationName) \(\.$day)",
        ], shortTitle: "Shoots on a Day", systemImageName: "calendar")
        AppShortcut(intent: OpenTimesIntent(), phrases: [
            "When am I free \(\.$day) in \(.applicationName)",
            "What do I have open \(\.$day) in \(.applicationName)",
            "\(.applicationName) openings \(\.$day)",
        ], shortTitle: "Open Times", systemImageName: "clock.badge.checkmark")
        AppShortcut(intent: NextShootIntent(), phrases: [
            "What's my next shoot in \(.applicationName)",
            "When's my next \(.applicationName) shoot",
            "\(.applicationName) next shoot",
        ], shortTitle: "Next Shoot", systemImageName: "camera")
        AppShortcut(intent: CheckShootsIntent(), phrases: [
            "Check my \(.applicationName) shoots",
            "Anything wrong with my \(.applicationName) shoots",
        ], shortTitle: "Check Shoots", systemImageName: "checkmark.shield")
        AppShortcut(intent: AgentStatsIntent(), phrases: [
            "How's \(\.$agent) doing in \(.applicationName)",
            "Look up an agent in \(.applicationName)",
        ], shortTitle: "Agent History", systemImageName: "person.crop.circle")
        AppShortcut(intent: AskShootDeskIntent(), phrases: [
            "Ask \(.applicationName)",
            "Ask \(.applicationName) a question",
        ], shortTitle: "Ask ShootDesk", systemImageName: "sparkles")
        AppShortcut(intent: DirectionsIntent(), phrases: [
            "Directions to my next \(.applicationName) shoot",
            "Take me to my \(.applicationName) shoot",
        ], shortTitle: "Directions", systemImageName: "location.fill")
        AppShortcut(intent: TextAgentIntent(), phrases: [
            "Text the agent in \(.applicationName)",
            "Text my \(.applicationName) agent",
        ], shortTitle: "Text the Agent", systemImageName: "message.fill")
        AppShortcut(intent: BookShootIntent(), phrases: [
            "Book a shoot in \(.applicationName)",
            "Book \(\.$agent) in \(.applicationName)",
        ], shortTitle: "Book a Shoot", systemImageName: "calendar.badge.plus")
        AppShortcut(intent: OpenShootIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Open a shoot in \(.applicationName)",
        ], shortTitle: "Open Shoot", systemImageName: "doc.text")
    }
}

// MARK: - Availability (shared by Siri and the Open times page)

/// One day's free time: 8 AM to sunset, with 30 minutes kept clear before and after each shoot for driving.
struct OpenDay: Identifiable {
    struct Busy: Identifiable { let job: Job; let from: Date; let to: Date; var id: String { job.id } }

    let day: Date
    let opens: Date
    let closes: Date
    let busy: [Busy]
    /// Every free stretch, rounded to the quarter hour.
    let gaps: [DateInterval]
    var id: Date { day }

    func fitting(_ minutes: Int) -> [DateInterval] {
        gaps.filter { $0.duration >= TimeInterval(minutes * 60) }
    }
}

enum Availability {
    static let pad: TimeInterval = 30 * 60

    static func day(_ date: Date, jobs: [Job], now: Date = Date()) -> OpenDay {
        let cal = FieldTime.calendar
        let dayStart = FieldTime.startOfDay(date)
        let opens = cal.date(bySettingHour: 8, minute: 0, second: 0, of: dayStart) ?? dayStart
        let todays = jobs.filter { j in
            guard j.status != .stale, let s = j.start else { return false }
            return FieldTime.isSameDay(s, date)
        }
        .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        let lat = todays.first?.latitude ?? 41.64, lon = todays.first?.longitude ?? -70.93
        let closes = Sun.sunset(on: dayStart, lat: lat, lon: lon)
            ?? cal.date(bySettingHour: 18, minute: 0, second: 0, of: dayStart) ?? dayStart
        let busy = todays.compactMap { j -> OpenDay.Busy? in
            guard let s = j.start else { return nil }
            return OpenDay.Busy(job: j, from: s, to: j.end ?? s.addingTimeInterval(3600))
        }
        var cursor = opens
        if FieldTime.isSameDay(date, now) { cursor = max(cursor, roundUp(now)) }
        var gaps: [DateInterval] = []
        for b in busy {
            let from = roundDown(b.from.addingTimeInterval(-pad))
            let gapEnd = min(from, closes)
            if gapEnd > cursor { gaps.append(DateInterval(start: cursor, end: gapEnd)) }
            cursor = max(cursor, roundUp(b.to.addingTimeInterval(pad)))
        }
        let end = roundDown(closes)
        if cursor < end { gaps.append(DateInterval(start: cursor, end: end)) }
        return OpenDay(day: dayStart, opens: opens, closes: closes, busy: busy,
                       gaps: gaps.filter { $0.duration >= 15 * 60 })
    }

    static func week(from date: Date = Date(), days: Int = 7, jobs: [Job]) -> [OpenDay] {
        (0..<days).map { day(FieldTime.addDays($0, to: date), jobs: jobs) }
    }

    private static func roundUp(_ d: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 900).rounded(.up) * 900)
    }
    private static func roundDown(_ d: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 900).rounded(.down) * 900)
    }

    /// "8 AM", "12:30 PM"
    static func short(_ d: Date) -> String {
        FieldTime.calendar.component(.minute, from: d) == 0 ? FieldTime.format(d, "h a") : FieldTime.format(d, "h:mm a")
    }

    /// "8 AM to 12:30 PM", "after 1 PM", "until 11 AM", "all day"
    static func phrase(_ gap: DateInterval, in day: OpenDay) -> String {
        let fromStart = gap.start <= day.opens.addingTimeInterval(60)
        let toEnd = gap.end >= day.closes.addingTimeInterval(-15 * 60)
        if fromStart && toEnd { return "all day" }
        if toEnd { return "after \(short(gap.start))" }
        if fromStart { return "until \(short(gap.end))" }
        return "\(short(gap.start)) to \(short(gap.end))"
    }
}
