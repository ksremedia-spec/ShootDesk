import Foundation
import ShootDeskCore

// Runs the app's data core against the live Aryeo account and prints what the screens would show.
// Usage: ARYEO_KEY=... swift run CoreCheck

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  PASS  \(what)" : "  FAIL  \(what)")
    if !ok { failures += 1 }
}

let key = ProcessInfo.processInfo.environment["ARYEO_KEY"] ?? ""
guard !key.isEmpty else { print("Set ARYEO_KEY"); exit(2) }

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let aryeo = AryeoClient(key: key)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hf-check-\(UUID().uuidString)")
        let store = OrderStore(directory: dir)
        var t0 = Date()
        try await store.refresh(using: aryeo)
        print("Full sync: \(store.orders.count) orders in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        check(store.orders.count > 800, "full sync returns all orders")
        t0 = Date()
        let reopened = OrderStore(directory: dir)
        reopened.loadFromDisk()
        print("Reopen from disk: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        check(reopened.orders.count == store.orders.count && !reopened.needsFullSync, "app reopens instantly from the saved copy")
        t0 = Date()
        try await reopened.refresh(using: aryeo)
        print("Quick refresh (newest 100): \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        check(reopened.orders.count == store.orders.count, "quick refresh merges without duplicates")
        let orders = reopened.orders

        // Cache round trip (the app saves the sync to disk for instant launch).
        let data = try AryeoJSON.encoder().encode(orders)
        let back = try AryeoJSON.decoder().decode([Order].self, from: data)
        check(back.count == orders.count && back.first == orders.first, "disk cache round trip is lossless (\(data.count / 1024) KB)")

        // "Tonight" = Oct 14, 2026, 11:00 PM Eastern
        let tonight = FieldTime.parse("2026-10-15T03:00:00Z")!
        let jobs = JobBuilder.jobs(from: orders, now: tonight)
        let oct14 = FieldTime.parse("2026-10-14T16:00:00Z")!
        let day = JobBuilder.shoots(on: oct14, in: jobs)
        print("\nOct 14 shoots:")
        for j in day { print("  \(j.timeRange)  \(j.street), \(j.town)  ·  \(j.agentName)  ·  \(j.packageSummary)  ·  \(j.status.label)  ·  \(j.images.count) photos") }
        check(day.map { $0.street } == ["93 Washington St", "77 Summer St", "319 Rock O'Dundee Rd"], "Oct 14 has the three real shoots in order")
        check(day.first?.timeRange == "10:00 – 10:45 AM", "times show in Eastern")
        check(day.last?.status == .editing && day.first?.status == .delivered, "statuses: delivered vs editing")

        let customers = StatsBuilder.customers(from: orders)
        func stat(_ n: String) -> CustomerStats? { customers.first { $0.name == n } }
        print("\nCustomer stats (dashboard on Oct 8 said Kurtis 11, Monica 4, Tiffany 9, Jenna 8):")
        for n in ["Kurtis Amaral", "Monica Kavanaugh", "Tiffany Vieira", "Jenna Danielli", "Michael Ricardo", "Heidi Lecomte"] {
            if let s = stat(n) {
                print("  \(n): \(s.delivered) delivered · \(Money.dollars(s.revenueCents)) · video \(s.videoOrders) · group \(s.group(now: tonight).rawValue) · \(Phone.pretty(s.phone) ?? "-")")
            } else { print("  \(n): not found") }
        }
        check(stat("Monica Kavanaugh")?.delivered == 5, "Monica: 4 at Oct 8 + #1842 delivered Oct 14 = 5")
        check(stat("Kurtis Amaral")?.delivered == 12, "Kurtis: 11 at Oct 8 + #1845 delivered Oct 14 = 12")
        // #1854 (28 Erin Ct) was delivered Oct 15 at 5:12 PM, taking Tiffany from 9 to 10 (and video 5 to 6).
        let erinDone = orders.first { $0.number == 1854 }?.fulfillmentStatus?.uppercased() == "FULFILLED"
        check(stat("Tiffany Vieira")?.delivered == (erinDone ? 10 : 9), "Tiffany: 9 at Oct 8 + #1854 once delivered")
        check(stat("Heidi Lecomte")?.group(now: tonight) == .new, "Heidi is a new client")
        check(stat("Tiffany Vieira")?.videoOrders == (erinDone ? 6 : 5) && stat("Jenna Danielli")?.videoOrders == 5 && stat("Michael Ricardo")?.videoOrders == 27,
              "video counts match the dashboard (Tiffany 5, Jenna 5, Michael 27)")
        let stale = jobs.filter { $0.status == .stale }.count
        let open = jobs.filter { $0.status == .unscheduled }.map { "#\($0.number)" }
        print("  hidden never-closed orders: \(stale) · open orders needing a time: \(open.joined(separator: ", "))")

        let evening = EveningCheck(weather: WeatherClient())
        let results = await evening.run(jobs: jobs, customers: customers, now: tonight)
        print("\nEvening check for Oct 15–16 (+ unscheduled):")
        for r in results {
            print("  #\(r.job.number) \(r.job.start.map { FieldTime.dayLabel($0) } ?? "no time") \(r.job.timeRange) \(r.job.street) — \(r.job.agentName)")
            if let w = r.weatherLine { print("     weather: \(w)") }
            for i in r.issues { print("     ⚠︎ \(i.title) — \(i.detail)") }
            for n in r.notes { print("     • \(n.text)") }
            if let s = r.suggestion { print("     → move to \(FieldTime.format(s.date, "EEE MMM d h:mm a")) (\(s.reason))") }
        }
        let willow = results.first { $0.job.number == 1846 }
        swiftCheck(willow?.issues.contains { $0.kind == .email } == true, "catches the .con email on #1846")
        swiftCheck(willow?.issues.contains { $0.kind == .airspace } == true, "flags New Bedford airport for the Willow St drone shoot")
        let erin = results.first { $0.job.number == 1854 }
        if erinDone && erin == nil {
            print("  (skip) Tiffany's welcome-back note: #1854 is already delivered, so it's no longer upcoming")
        } else {
            if erinDone && erin == nil {
            print("  (skip) Tiffany's welcome-back note: #1854 is already delivered, so it's no longer upcoming")
        } else {
            swiftCheck(erin?.notes.contains { $0.text.hasPrefix("Back after") } == true, "Tiffany flagged as back after a long gap")
        }
        }

        let summer = day.first { $0.street == "77 Summer St" }!
        let facts = try await PropertyRecordsClient().facts(lat: summer.latitude!, lon: summer.longitude!)
        print("\n77 Summer St records: \(facts.map { "\($0.livingAreaSqFt ?? 0) sq ft, built \($0.yearBuilt ?? 0), \($0.lotLabel ?? "-"), \($0.style ?? "-")" } ?? "none")")
        swiftCheck(facts?.livingAreaSqFt == 2296 && facts?.yearBuilt == 1963, "town records match the Oct 15 lookup")

        let rock = day.last!
        let sunset = Sun.sunset(on: rock.start!, lat: rock.latitude!, lon: rock.longitude!)
        print("Sunset Dartmouth Oct 14: \(sunset.map { FieldTime.clockAMPM($0) } ?? "-")")
        swiftCheck(sunset.map { FieldTime.clockAMPM($0) } == "6:05 PM", "sunset 6:05 PM")

        swiftCheck(EmailCheck.problem("jennadrealty@gmail.con") != nil, "email check catches .con")
        swiftCheck(EmailCheck.problem("heidilecomte@kw.com") == nil, "email check passes a good address")
        swiftCheck(Phone.pretty("+15089895326") == "(508) 989-5326", "phone formatting")

        let ctx = AskContext.build(jobs: jobs, customers: customers, now: tonight)
        print("\nAsk context: \(ctx.count) characters (~\(ctx.count / 4) tokens)")
        let sample = ListingKitWriter.samplePhotos(summer.images)
        print("Listing kit would send \(sample.count) of \(summer.images.count) photos")
        swiftCheck(sample.count == 12, "listing kit samples 12 photos")

        // Home Screen widget: fetches on its own from the appointments endpoint.
        let now = Date()
        t0 = Date()
        let widgetShoots = try await NextShoots.fetch(aryeo: aryeo, weather: WeatherClient(), now: now)
        print("\nWidget fetch (appointments + weather): \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, \(widgetShoots.count) upcoming")
        for s in widgetShoots {
            let w = s.weather.map { " · \($0.line)\($0.warning.map { " ⚠︎ \($0)" } ?? "") [\($0.symbol)]" } ?? ""
            print("  #\(s.number) \(s.dayLabel(at: now)) \(s.timeRange) \(s.street), \(s.town) — \(s.agentFirstName)\(s.drone ? " · drone" : "")\(w)")
        }
        let fromApp = NextShoots.upcoming(from: JobBuilder.jobs(from: orders, now: now), now: now)
        print("  app's own list: " + fromApp.map { "#\($0.number)" }.joined(separator: ", "))
        swiftCheck(!widgetShoots.isEmpty, "widget finds upcoming shoots")
        swiftCheck(Set(widgetShoots.map { $0.orderID }).isSuperset(of: Set(fromApp.map { $0.orderID })),
                   "widget's list covers every upcoming shoot the app knows about")
        swiftCheck(widgetShoots.first?.weather != nil || (widgetShoots.first?.start ?? now) > now.addingTimeInterval(6 * 86_400),
                   "next shoot has its forecast")
        swiftCheck(zip(widgetShoots, widgetShoots.dropFirst()).allSatisfy { $0.start <= $1.start }, "soonest first")
        if let first = widgetShoots.first {
            let (next, later) = NextShoots.split(widgetShoots, at: first.end)
            swiftCheck(next?.id != first.id && later.count == max(0, widgetShoots.count - 2), "widget moves on when a shoot ends")
            swiftCheck(NextShoots.split(widgetShoots, at: first.start).next?.isUnderway(at: first.start) == true, "shoot in progress stays on the widget")
            if let u = NextShoots.shootURL(first) {
                swiftCheck(NextShoots.parse(u) == .shoot(orderID: first.orderID), "tapping the widget opens that shoot")
            }
            if let d = NextShoots.directionsURL(first), case .directions(let lat, let lon, _)? = NextShoots.parse(d) {
                swiftCheck(lat == first.latitude && lon == first.longitude, "Directions link carries the location")
            } else { swiftCheck(false, "Directions link parses") }
            let times = NextShoots.changeTimes(widgetShoots, after: now)
            print("  widget redraws on its own at: " + times.prefix(6).map { FieldTime.format($0, "EEE h:mm a") }.joined(separator: ", "))
            swiftCheck(times.contains(where: { FieldTime.format($0, "HH:mm") == "00:00" }), "redraws at midnight so Tomorrow becomes Today")
        }
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("hf-widget-\(UUID().uuidString)/cache.json")
        WidgetCache(fetchedAt: now, shoots: widgetShoots).save(to: cacheURL)
        swiftCheck(WidgetCache.load(from: cacheURL)?.shoots == widgetShoots, "widget's saved copy round-trips")
        print("  Tomorrow label test: " + (widgetShoots.first.map { $0.dayLabel(at: FieldTime.addDays(-1, to: $0.start)) } ?? "-"))

        // Evening Check widget: two small requests must give the same warnings as the app's full check.
        t0 = Date()
        let wc = try await CheckWidget.run(aryeo: aryeo, weather: WeatherClient(), now: now)
        print("\nEvening Check widget: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s · \(wc.headline) · \(wc.subline)")
        for i in wc.items {
            print("  \(i.whenLabel(at: now)) · \(i.street) — \(i.agent)")
            for x in i.issues { print("     ⚠︎ [\(x.symbol)] \(x.title) — \(x.detail)") }
            if let s = i.suggestionLine { print("     → \(s)") }
        }
        let appCheck = await EveningCheck(weather: WeatherClient()).run(jobs: JobBuilder.jobs(from: orders, now: now),
                                                                         customers: customers, now: now)
        let appView = CheckWidget.make(from: appCheck, at: now)
        func shape(_ c: WidgetCheck) -> [String] {
            c.items.map { "\($0.id)|\($0.issues.map { $0.title }.joined(separator: ","))|\($0.suggestedDate?.timeIntervalSince1970 ?? 0)" }.sorted()
        }
        print("  app's own check: \(appView.headline) · \(appView.subline)")
        swiftCheck(shape(wc) == shape(appView), "widget's evening check matches the app's (same shoots, warnings, suggested day)")
        let wcURL = FileManager.default.temporaryDirectory.appendingPathComponent("hf-check-\(UUID().uuidString)/check.json")
        wc.save(to: wcURL)
        swiftCheck(WidgetCheck.load(from: wcURL) == wc, "evening check widget's saved copy round-trips")
        swiftCheck(wc.items.allSatisfy { $0.start == nil || $0.weatherChecked }, "every timed shoot had its forecast checked")
        let blind = WidgetCheck(checkedAt: now, items: [WidgetCheckItem(id: "x", number: 1, start: now, street: "1 Test St",
                                town: "", agent: "", issues: [], suggestedDate: nil, suggestedReason: nil, weatherChecked: false)])
        swiftCheck(!blind.isAllClear && blind.headline == "Weather not checked", "no forecast never shows as All clear")
        if let u = URL(string: "shootdesk://tonight") { swiftCheck(NextShoots.parse(u) == .tonight, "tapping it opens Tonight") }
    } catch {
        print("ERROR: \(error)")
        failures += 1
    }
    sem.signal()
}
func swiftCheck(_ ok: Bool, _ what: String) { check(ok, what) }
sem.wait()
print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
