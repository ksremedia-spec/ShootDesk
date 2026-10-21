import SwiftUI

/// The home screen. Closed: the next shoot, then swipeable rows. Open: the same screen, bigger.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    @State private var path: [AppRoute] = []
    @State private var booking = false
    @Namespace private var ns

    private var wide: Bool { size == .regular }
    private var gutter: CGFloat { Gutter.of(size) }

    /// Not finished yet, soonest first (includes a shoot happening right now).
    private var upcoming: [Job] {
        let now = Date()
        let horizon = FieldTime.addDays(8, to: FieldTime.calendar.startOfDay(for: now))
        return model.visibleJobs.filter { j in
            guard j.status != .delivered, let s = j.start else { return false }
            return (j.end ?? s.addingTimeInterval(3600)) > now && s < horizon
        }
        .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    /// Delivered in the last three weeks, newest first: the work worth showing off.
    private var recentlyDelivered: [Job] {
        let cutoff = Date().addingTimeInterval(-21 * 86_400)
        return model.visibleJobs
            .filter { $0.status == .delivered && $0.heroURL != nil && ($0.start ?? .distantPast) > cutoff }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !model.hasAryeoKey { MissingKeyView() } else { page }
            }
            .toolbar(.hidden, for: .navigationBar)
            .appDestinations(ns)
        }
        .adaptiveSheet(isPresented: $booking) { BookShootView() }
        .onAppear { openRequested() }
        .onChange(of: model.openShootID) { _, _ in openRequested() }
        .onChange(of: model.openTonight) { _, _ in openRequested() }
        .onChange(of: model.openBooking) { _, _ in openRequested() }
        .onChange(of: model.openAvailability) { _, _ in openRequested() }
        .onChange(of: model.jobs.count) { _, _ in openRequested() }
    }

    /// Widget, notification and Siri taps.
    private func openRequested() {
        if model.openTonight { path = [.tonight]; model.openTonight = false }
        if model.openAvailability { path = [.availability]; model.openAvailability = false }
        if model.openBooking { path = []; booking = true; model.openBooking = false }
        guard let id = model.openShootID, model.jobs.contains(where: { $0.id == id }) else { return }
        path = [.shoot(id)]
        model.openShootID = nil
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header.padding(.horizontal, gutter)

                if let job = upcoming.first {
                    VStack(alignment: .leading, spacing: 14) {
                        NavigationLink(value: AppRoute.shoot(job.id)) {
                            UpNextHero(job: job, leave: model.leavePlans[job.id], height: wide ? 440 : 360)
                                .zoomSource(job.id, in: ns)
                        }
                        .buttonStyle(.pressable)

                        HStack(spacing: 12) {
                            Button { Launcher.directions(to: job) } label: {
                                Label("Directions", systemImage: "location.fill")
                            }
                            .buttonStyle(PrimaryActionStyle())
                            Button {
                                Launcher.open(Phone.textURL(job.agentPhone, body: textBody(for: job)))
                            } label: {
                                Label("Text \(firstName(job))", systemImage: "message.fill")
                            }
                            .buttonStyle(PrimaryActionStyle(prominent: false))
                            .disabled(job.agentPhone == nil)
                        }

                        if let issues = model.checkResults.first(where: { $0.job.id == job.id })?.issues, let first = issues.first {
                            NavigationLink(value: AppRoute.tonight) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text(issues.count > 1 ? "\(first.title), and \(issues.count - 1) more" : first.title).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).opacity(0.6)
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    .padding(.horizontal, gutter)
                } else {
                    emptyHero.padding(.horizontal, gutter)
                }

                if !model.deliveryFlags.isEmpty {
                    Rail(title: "Missing", note: "video or floor plan not delivered",
                         items: model.deliveryFlags, cardWidth: wide ? 300 : 250) { f in
                        NavigationLink(value: AppRoute.shoot(f.job.id)) {
                            ShootCard(job: f.job, flag: f).zoomSource(f.job.id, in: ns)
                        }
                        .buttonStyle(.pressable)
                    }
                }

                if upcoming.count > 1 {
                    Rail(title: "This week", items: Array(upcoming.dropFirst()), cardWidth: wide ? 300 : 240) { j in
                        NavigationLink(value: AppRoute.shoot(j.id)) {
                            ShootCard(job: j, showsTime: true).zoomSource(j.id, in: ns)
                        }
                        .buttonStyle(.pressable)
                    }
                }

                if !recentlyDelivered.isEmpty {
                    Rail(title: "Recently delivered", items: recentlyDelivered, cardWidth: wide ? 340 : 270) { j in
                        NavigationLink(value: AppRoute.shoot(j.id)) {
                            ShootCard(job: j).zoomSource(j.id, in: ns)
                        }
                        .buttonStyle(.pressable)
                    }
                }

                footer.padding(.horizontal, gutter)
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground))
        .refreshable { await model.refresh() }
    }

    private var header: some View {
        // Folded: the buttons share the date's line so the headline gets the full width.
        // Open: one line, headline left, buttons right.
        Group {
            if wide {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        dateLine
                        Text(headline).font(.address(30))
                    }
                    Spacer()
                    headerButtons
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center) {
                        dateLine
                        Spacer()
                        headerButtons
                    }
                    Text(headline).font(.address(28)).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
    }

    private var dateLine: some View {
        Text(FieldTime.format(Date(), "EEEE, MMMM d"))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var headerButtons: some View {
        HStack(spacing: 10) {
            Button { booking = true } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Book a shoot")
            .disabled(!model.hasAryeoKey)
            NavigationLink(value: AppRoute.availability) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemFill), in: Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Open times")
            NavigationLink(value: AppRoute.schedule) {
                Image(systemName: "calendar")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemFill), in: Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Schedule")
        }
    }

    /// "2 shoots today", "Next shoot tomorrow", "Nothing booked this week"
    private var headline: String {
        let now = Date()
        let today = upcoming.filter { $0.start.map { FieldTime.isSameDay($0, now) } ?? false }.count
        if today > 0 { return today == 1 ? "1 shoot today" : "\(today) shoots today" }
        guard let next = upcoming.first?.start else { return "Nothing booked this week" }
        if FieldTime.isSameDay(next, FieldTime.addDays(1, to: now)) { return "Next shoot tomorrow" }
        return "Next shoot \(FieldTime.format(next, "EEEE"))"
    }

    private var emptyHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "camera.aperture").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
            Text(model.isRefreshing ? "Loading your schedule…" : "A clear week")
                .font(.address(24))
            Text("New bookings from Aryeo show up here on their own.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder private var footer: some View {
        if let err = model.errorMessage {
            Label(err, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.secondary)
        } else if model.isRefreshing, let updated = model.lastUpdated, Date().timeIntervalSince(updated) > 5 * 60 {
            // Only while what's on screen is old; the quiet full download after a fresh quick one doesn't count.
            Text("Updating… (last updated \(updated.formatted(.relative(presentation: .named))))")
                .font(.footnote).foregroundStyle(.tertiary)
        } else if let updated = model.lastUpdated {
            Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                .font(.footnote).foregroundStyle(.tertiary)
        }
    }

    private func firstName(_ job: Job) -> String {
        job.agentName.split(separator: " ").first.map(String.init) ?? "agent"
    }

    /// Same-day shoots get the "on my way" text; later ones a blank message.
    private func textBody(for job: Job) -> String? {
        guard let s = job.start, FieldTime.isSameDay(s, Date()) else { return nil }
        return Drafts.onMyWay(job: job)
    }
}

// MARK: - Schedule (week strip, the day's stops, map)

struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    @State private var day = Date()

    private var shoots: [Job] { model.shoots(on: day) }
    private var isToday: Bool { FieldTime.isSameDay(day, Date()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WeekStrip(selected: $day) { model.shoots(on: $0).count }
                    .padding(.horizontal, 6)
                    .sensoryFeedback(.selection, trigger: day)

                HStack(alignment: .firstTextBaseline) {
                    Text(FieldTime.format(day, "EEEE, MMMM d")).font(.address(22))
                    Spacer()
                    if !shoots.isEmpty {
                        Text(shoots.count == 1 ? "1 shoot" : "\(shoots.count) shoots")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Gutter.of(size))

                // The day at a glance: shoots in grey, room for a 90-minute shoot in green.
                DayTimeline(day: Availability.day(day, jobs: model.visibleJobs), minutes: 90)
                    .frame(height: 30)
                    .padding(.horizontal, Gutter.of(size))

                if shoots.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.isRefreshing ? "Loading…" : "Nothing booked.")
                            .foregroundStyle(.secondary)
                        NavigationLink(value: AppRoute.availability) {
                            Label("Offer open times to an agent", systemImage: "clock.badge.checkmark")
                        }
                        .buttonStyle(PrimaryActionStyle(prominent: false))
                        .frame(maxWidth: 420)
                    }
                    .padding(.horizontal, Gutter.of(size))
                } else if size == .regular {
                    // Open Duo: the day's stops on the left, the map beside them.
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 16) {
                            stopList
                            sunsetLabel
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !pins.isEmpty {
                            ShootMap(pins: pins)
                                .frame(height: 420)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Gutter.of(size))
                } else {
                    stopList.padding(.horizontal, Gutter.of(size))
                    if !pins.isEmpty {
                        ShootMap(pins: pins)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .padding(.horizontal, Gutter.of(size))
                    }
                    sunsetLabel.padding(.horizontal, Gutter.of(size))
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemBackground))
        .refreshable { await model.refresh() }
        .slimBar("Schedule")
        .toolbar {
            if !isToday {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Today") { withAnimation(.snappy) { day = Date() } }
                }
            }
        }
    }

    private var pins: [MapPin] {
        shoots.enumerated().compactMap { i, j in
            guard let lat = j.latitude, let lon = j.longitude else { return nil }
            return MapPin(id: j.id, label: "\(i + 1)", title: j.street, lat: lat, lon: lon, highlighted: j.status == .booked)
        }
    }

    private var stopList: some View {
        VStack(spacing: 0) {
            ForEach(shoots) { job in
                NavigationLink(value: AppRoute.shoot(job.id)) {
                    StopRow(job: job).padding(.vertical, 10).contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                if job.id != shoots.last?.id { Divider().padding(.leading, 58) }
            }
        }
    }

    @ViewBuilder private var sunsetLabel: some View {
        if let line = sunsetLine {
            Label(line, systemImage: "sun.horizon").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var sunsetLine: String? {
        guard let last = shoots.last, let lat = last.latitude, let lon = last.longitude,
              let sunset = Sun.sunset(on: day, lat: lat, lon: lon) else { return nil }
        var s = "Sunset \(FieldTime.clockAMPM(sunset)) in \(last.town)"
        if let end = last.end {
            let gap = Int(sunset.timeIntervalSince(end) / 60)
            if gap > 0 && gap < 90 { s += ", \(gap) min after the last shoot wraps" }
        }
        return s
    }
}

struct StopRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            JobThumb(job: job)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.street).font(.address(.body)).lineLimit(1)
                Text("\(job.start.map { FieldTime.clockAMPM($0) } ?? "No time")   \(job.town)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if job.status == .delivered { StatusChip(text: "Delivered", color: .green) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

/// The next shoot, big: photo (or map), when, where and who. Tap for the full order sheet.
struct UpNextHero: View {
    let job: Job
    var warning: String? = nil
    var leave: LeavePlan? = nil
    var height: CGFloat = 340

    var body: some View {
        Group {
            if let url = job.heroURL { photoHero(url) } else { mapHero }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(Rectangle())
    }

    /// A photo from an earlier shoot at this address: full bleed, type over a soft shade.
    private func photoHero(_ url: URL) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemotePhoto(url: url, cornerRadius: 0)
                .frame(height: height)
                .clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.78), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            details.foregroundStyle(.white).padding(22)
        }
        .frame(height: height)
    }

    /// No photos yet (a new listing): the map on top, the details underneath so nothing covers the map's labels.
    private var mapHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let lat = job.latitude, let lon = job.longitude {
                    ShootMap(pins: [MapPin(id: job.id, label: "", title: "", lat: lat, lon: lon, highlighted: true)])
                        .allowsHitTesting(false)
                } else {
                    DateArt(date: job.start)
                }
            }
            .frame(height: max(150, height - 180))
            .clipped()
            details
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.orange).lineLimit(1)
            }
            Text(whenLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(job.heroURL == nil ? Theme.accent : .white.opacity(0.85))
            Text(job.street)
                .font(.address(height > 380 ? 30 : 25))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text("\(job.town), for \(job.agentName)")
                .font(.subheadline)
                .opacity(0.75)
                .lineLimit(1)
            if let leave, let line = leaveLine(leave) {
                Label(line, systemImage: "car.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(leave.leaveAt <= Date() ? Color.orange : (job.heroURL == nil ? Color.primary : Color.white))
                    .padding(.top, 4)
            }
        }
    }

    /// "Leave by 9:53 AM, 27 min drive", or "Leave now" once that time has passed. Hidden once the shoot starts.
    private func leaveLine(_ plan: LeavePlan) -> String? {
        guard let s = job.start, s > Date() else { return nil }
        if plan.leaveAt <= Date() { return "Leave now, \(plan.driveLabel)" }
        return "Leave by \(FieldTime.clockAMPM(plan.leaveAt)), \(plan.driveLabel)"
    }

    /// "Tomorrow at 10:30 AM", "Now, until 3:30 PM", "Tuesday at 12:30 PM"
    private var whenLine: String {
        guard let s = job.start else { return "Date to be set" }
        let now = Date()
        if s <= now, let e = job.end, e > now { return "Happening now, until \(FieldTime.clockAMPM(e))" }
        let cal = FieldTime.calendar
        let day: String
        if cal.isDate(s, inSameDayAs: now) { day = "Today" }
        else if cal.isDate(s, inSameDayAs: FieldTime.addDays(1, to: now)) { day = "Tomorrow" }
        else { day = FieldTime.format(s, "EEEE") }
        return "\(day) at \(FieldTime.clockAMPM(s))"
    }
}

/// One line per upcoming shoot (used by lists): day and time on the left, address on the right.
struct UpcomingRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(job.start.map { FieldTime.format($0, "EEE") } ?? "TBD")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(job.start.map { FieldTime.clockAMPM($0) } ?? "")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.street).font(.address(.body)).lineLimit(1)
                Text(job.town).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Open times

/// When you're free this week, drawn as a timeline per day. Pick the openings you want to offer
/// and send them to an agent in one text.
struct AvailabilityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    @State private var minutes = 90
    @State private var picked: Set<DateInterval> = []

    private var days: [OpenDay] { Availability.week(jobs: model.visibleJobs) }
    private var gutter: CGFloat { Gutter.of(size) }

    var body: some View {
        let week = days
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("When you're free").font(.address(size == .regular ? 32 : 28))
                    Text("8 AM to sunset, with 30 minutes kept clear around each shoot for the drive. Tap openings to offer them.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                Picker("Shoot length", selection: $minutes) {
                    Text("1 hr").tag(60)
                    Text("1.5 hr").tag(90)
                    Text("2 hr").tag(120)
                    Text("3 hr").tag(180)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)
                .onChange(of: minutes) { _, m in
                    picked = picked.filter { $0.duration >= TimeInterval(m * 60) }
                }

                // Open Duo: two days side by side, so the whole week fits on screen.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 32, alignment: .top),
                                         count: size == .regular ? 2 : 1),
                          alignment: .leading, spacing: 28) {
                    ForEach(week) { day in
                        dayRow(day)
                    }
                }
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground))
        .slimBar("Open times")
        .safeAreaInset(edge: .bottom) {
            if !picked.isEmpty {
                offerBar(week)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: picked)
        .sensoryFeedback(.selection, trigger: picked)
    }

    private func dayLabel(_ d: Date) -> String {
        if FieldTime.isSameDay(d, Date()) { return "Today" }
        if FieldTime.isSameDay(d, FieldTime.addDays(1, to: Date())) { return "Tomorrow" }
        return FieldTime.format(d, "EEEE, MMM d")
    }

    private func dayRow(_ day: OpenDay) -> some View {
        let fits = day.fitting(minutes)
        let pastSunset = FieldTime.isSameDay(day.day, Date()) && Date() > day.closes
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayLabel(day.day)).font(.address(.title3))
                Spacer()
                Text(day.busy.isEmpty ? "Nothing booked" : (day.busy.count == 1 ? "1 shoot" : "\(day.busy.count) shoots"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            DayTimeline(day: day, minutes: minutes)
                .frame(height: 30)
            if pastSunset {
                Text("Done for today.").font(.subheadline).foregroundStyle(.secondary)
            } else if fits.isEmpty {
                Text("No \(minutes >= 120 ? "\(minutes / 60)-hour" : "\(minutes)-minute") openings.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: 8) {
                    ForEach(fits, id: \.self) { gap in
                        let on = picked.contains(gap)
                        Button {
                            if on { picked.remove(gap) } else { picked.insert(gap) }
                        } label: {
                            Text(Availability.phrase(gap, in: day).prefix(1).uppercased() + Availability.phrase(gap, in: day).dropFirst())
                                .font(.subheadline.weight(.semibold))
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

    /// "Hi! Here's when I'm free for a shoot: Tuesday (Oct 20) 8 AM to 12:30 PM, Wednesday (Oct 21) after 1 PM."
    private func message(_ week: [OpenDay]) -> String {
        let lines = week.compactMap { day -> String? in
            let mine = day.gaps.filter { picked.contains($0) }
            guard !mine.isEmpty else { return nil }
            let name = FieldTime.isSameDay(day.day, Date()) ? "today" :
                (FieldTime.isSameDay(day.day, FieldTime.addDays(1, to: Date())) ? "tomorrow" :
                    FieldTime.format(day.day, "EEEE, MMM d"))
            let times = mine.map { g -> String in
                let p = Availability.phrase(g, in: day)
                return p == "all day" ? "any time" : p
            }
            return "\(name) \(times.joined(separator: " or "))"
        }
        let body = lines.count == 1 ? lines[0] : lines.dropLast().joined(separator: ", ") + ", or " + (lines.last ?? "")
        return "Hi! I'm free for a shoot \(body). Let me know what works and I'll get it booked."
    }

    private func offerBar(_ week: [OpenDay]) -> some View {
        let text = message(week)
        return VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.subheadline).lineLimit(3)
            HStack(spacing: 10) {
                ShareLink(item: text) {
                    Label("Send", systemImage: "message.fill")
                }
                .buttonStyle(PrimaryActionStyle())
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(PrimaryActionStyle(prominent: false))
                Button {
                    picked.removeAll()
                } label: {
                    Image(systemName: "xmark").font(.headline)
                        .frame(width: 52, height: 52)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 2)
        .padding(.horizontal, Gutter.of(size))
        .padding(.bottom, 8)
        .frame(maxWidth: size == .regular ? 760 : .infinity)
    }
}

/// 8 AM on the left, sunset on the right: shoots in grey (with their drive time faded either side),
/// openings long enough for the shoot in green.
struct DayTimeline: View {
    let day: OpenDay
    let minutes: Int

    var body: some View {
        GeometryReader { geo in
            let span = max(day.closes.timeIntervalSince(day.opens), 1)
            let w = geo.size.width
            let x: (Date) -> CGFloat = { d in CGFloat(min(max(d.timeIntervalSince(day.opens) / span, 0), 1)) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                ForEach(day.fitting(minutes), id: \.self) { g in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.green.opacity(0.28))
                        .frame(width: max(2, x(g.end) - x(g.start)))
                        .offset(x: x(g.start))
                }
                ForEach(day.busy) { b in
                    let padFrom = b.from.addingTimeInterval(-Availability.pad), padTo = b.to.addingTimeInterval(Availability.pad)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: max(2, x(padTo) - x(padFrom)))
                        .offset(x: x(padFrom))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: max(3, x(b.to) - x(b.from)))
                        .offset(x: x(b.from))
                }
                if FieldTime.isSameDay(day.day, Date()), Date() > day.opens, Date() < day.closes {
                    Rectangle().fill(Color.red).frame(width: 2).offset(x: x(Date()))
                }
            }
            .clipShape(Capsule())
            .overlay(alignment: .bottom) {
                HStack {
                    Text("8 AM")
                    Spacer()
                    Text("Sunset \(Availability.short(day.closes))")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .offset(y: 16)
            }
        }
        .padding(.bottom, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline for the day")
    }
}

/// Chips that wrap onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
