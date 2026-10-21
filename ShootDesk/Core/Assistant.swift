import Foundation

// Everything Claude does in the app: the listing kit, the Ask bar and message drafts.
// Claude only ever reads data the app hands it; it never changes anything in Aryeo.

public struct ListingKit: Hashable {
    public let mls: String
    public let social: String
    public let photosUsed: Int
}

public enum ListingKitWriter {
    static let system = """
    You write real estate listing copy for Kyle Silva, a real estate photographer in southeastern Massachusetts.
    Rules:
    - Describe only what is visible in the photos or stated in the property facts. Never guess bedroom or bathroom counts, \
    square footage, school districts, or anything not shown.
    - Plain, warm, specific language. No clichés like "nestled", "boasts", "dream home", "won't last".
    - Follow fair housing rules: describe the property, never the kind of buyer or neighbor.
    - MLS description: one paragraph, 80–120 words, then a final line of facts in this exact form: \
    "[Beds] bed · [Baths] bath · <sq ft> sq ft · <lot>" using the facts given and keeping [Beds]/[Baths] as placeholders.
    - Social post: written as Kyle for his own page. Short "quick hits" lines, no emojis, under 40 words, \
    then 2–3 hashtags (town + South Coast + real estate photography). Mention the agent by name.
    Reply with JSON only: {"mls": "...", "social": "..."}
    """

    /// Picks up to `limit` photos spread across the set so Claude sees exterior, interior and aerial shots.
    public static func samplePhotos(_ images: [ListingImage], limit: Int = 12) -> [String] {
        let urls = images.compactMap { $0.largeUrl ?? $0.originalUrl }
        guard urls.count > limit else { return urls }
        let step = Double(urls.count) / Double(limit)
        return (0..<limit).map { urls[min(urls.count - 1, Int(Double($0) * step))] }
    }

    public static func write(job: Job, facts: PropertyFacts?, claude: ClaudeClient) async throws -> ListingKit {
        let photos = samplePhotos(job.images)
        guard !photos.isEmpty else { throw FieldError.badResponse("This listing has no photos yet.") }
        var factLines = ["Address: \(job.street), \(job.townState)", "Listing agent: \(job.agentName)"]
        if let f = facts {
            if let a = f.livingAreaSqFt { factLines.append("Living area (town assessor): \(a) sq ft") }
            if let y = f.yearBuilt { factLines.append("Year built (town assessor): \(y)") }
            if let l = f.lotLabel { factLines.append("Lot (town assessor): \(l)") }
            if let s = f.style { factLines.append("Style (town assessor): \(s)") }
            if let r = f.rooms { factLines.append("Total rooms (town assessor): \(r)") }
        } else {
            factLines.append("No town records found; leave size and lot as [Sq ft] and [Lot].")
        }
        var blocks: [ClaudeBlock] = photos.map { ClaudeBlock.image(url: $0) }
        blocks.append(.text("Property facts:\n" + factLines.joined(separator: "\n") + "\n\nWrite the MLS description and the social post."))
        let raw = try await claude.send(model: ClaudeClient.smart, system: system, messages: [.user(blocks)], maxTokens: ClaudeClient.maxOutput)
        let json = JSONText.extractObject(raw)
        struct Out: Decodable { let mls: String; let social: String }
        guard let data = json.data(using: .utf8), let out = try? JSONDecoder().decode(Out.self, from: data) else {
            throw FieldError.badResponse("Couldn't read Claude's draft. Try again.")
        }
        return ListingKit(mls: out.mls, social: out.social, photosUsed: photos.count)
    }
}

public enum JSONText {
    /// Pulls the first {...} block out of a reply, in case the model wraps JSON in prose or code fences.
    public static func extractObject(_ s: String) -> String {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return s }
        return String(s[a...b])
    }
}

// MARK: - Ask

public enum AskContext {
    /// A compact, current snapshot of the business for Claude to answer from.
    /// Built fresh from live Aryeo data every time a question is asked. It holds no clock time, so it stays
    /// byte-for-byte the same between follow-ups and Claude can reuse it from its cache; the time goes with
    /// each question instead.
    public static func build(jobs: [Job], customers: [CustomerStats], now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("Money is in US dollars. 'Delivered' means the order was fulfilled. Canceled orders, $0 orders, Kyle's own orders and the Jordan Rebello test account are already excluded.")

        // Monthly totals by month the order was placed.
        var months: [String: (orders: Int, delivered: Int, cents: Int, video: Int)] = [:]
        for j in jobs {
            guard let c = FieldTime.parse(j.order.createdAt) else { continue }
            let key = FieldTime.format(c, "yyyy-MM")
            var m = months[key] ?? (0, 0, 0, 0)
            m.orders += 1
            if j.status == .delivered { m.delivered += 1; m.cents += j.order.totalAmount ?? 0; if j.hasVideo { m.video += 1 } }
            months[key] = m
        }
        lines.append("\nMONTHS (month placed | orders | delivered | delivered revenue | delivered with video)")
        for k in months.keys.sorted() {
            let m = months[k]!
            lines.append("\(k) | \(m.orders) | \(m.delivered) | \(m.cents / 100) | \(m.video)")
        }

        lines.append("\nAGENTS (name | delivered | revenue | avg | with video | first order | last order | group | phone)")
        for c in customers {
            let first = c.firstOrder.map { FieldTime.format($0, "yyyy-MM-dd") } ?? "-"
            let last = c.lastOrder.map { FieldTime.format($0, "yyyy-MM-dd") } ?? "-"
            lines.append("\(c.name) | \(c.delivered) | \(c.revenueCents / 100) | \(c.averageCents / 100) | \(c.videoOrders) | \(first) | \(last) | \(c.group(now: now).rawValue) | \(Phone.pretty(c.phone) ?? "-")")
        }

        lines.append("\nSHOOTS (order # | status | shoot date | agent | address | town | package | total | photos)")
        for j in jobs.sorted(by: { ($0.start ?? FieldTime.parse($0.order.createdAt) ?? .distantPast) > ($1.start ?? FieldTime.parse($1.order.createdAt) ?? .distantPast) }) {
            let when = j.start.map { FieldTime.format($0, "yyyy-MM-dd h:mm a") } ?? "no time"
            lines.append("\(j.number) | \(j.status.rawValue) | \(when) | \(j.agentName) | \(j.street) | \(j.town) | \(j.packageSummary) | \((j.order.totalAmount ?? 0) / 100) | \(j.images.count)")
        }
        return lines.joined(separator: "\n")
    }

    static let system = """
    You are the assistant inside Kyle Silva's personal field app for Horizon Home Media, his real estate photography business.
    Answer only from the business data provided. If the data can't answer it, say exactly what's missing.
    Kyle usually asks out loud, so questions come in as speech turned into text: allow for a misheard word or a loose phrasing and answer what he clearly means. Only if you truly can't tell what he's asking, don't guess: ask one short question back, the way you'd ask a person in conversation ("Do you mean this week or this month?"), and stop there, with no data and no follow-up line.
    Plain-spoken. Match the depth to the question: a quick question gets a one- or two-sentence answer; when Kyle asks for detail, analysis, a breakdown or an in-depth look, give a thorough answer, as long as it needs to be, using short paragraphs and bulleted lists (no tables, no headings). Lead with the answer. Use **bold** sparingly for names or totals.
    Use names, dates and dollar amounts from the data. Never invent numbers. Dates: "Jun 18" style.
    Aryeo amounts are what was booked; the STRIPE section (when present) is money actually received after card fees. Say which one you're using when it matters.
    The TODAY section (sent with each question) has the current time, the next week's bookings with leave-by times, open times (8 AM to sunset, 30 minutes kept clear before and after each shoot for driving), the upcoming-shoot weather and airspace check, and shoots missing a video or floor plan. Use it for questions about the day, the week, availability and what needs attention.

    The app turns a few markers in your answer into pictures. Use them like this:
    - Right after a sentence about one specific shoot, put [[shoot 1234]] on its own line, using the order # from SHOOTS. The app shows a card Kyle can tap to open it. At most 5 per answer, only for shoots that matter to the answer.
    - When an agent is someone Kyle might call, text or look up, put [[agent Full Name]] on its own line, with the name exactly as in AGENTS. At most 3 per answer.
    - When a trend or a comparison is clearer as a picture (months, weeks, towns, agents, packages), add one chart, and only one, as a fenced block with up to 24 points, using only numbers from the data:
    ```chart
    {"kind": "bar", "title": "Booked by month", "unit": "$", "points": [{"label": "Jan", "value": 7000, "series": "2026"}]}
    ```
    "kind" is "bar" or "line"; "unit" is "$" for money or "" for counts; "series" is optional and groups the points (for example this year against last year).
    - End every answer with one last line listing 2 or 3 short follow-up questions Kyle might ask next, in his own words: [[next: question one | question two | question three]]
    """

    /// `today` is the TODAY section: the time now and what's happening this week. It changes from question
    /// to question, so it rides with the question and the big data block before it stays cacheable.
    public static func ask(_ question: String, history: [(q: String, a: String)], jobs: [Job],
                           customers: [CustomerStats], money: String? = nil, today: String? = nil,
                           claude: ClaudeClient, onText: (@Sendable (String) -> Void)? = nil) async throws -> String {
        var context = build(jobs: jobs, customers: customers)
        if let money { context += "\n\n" + money }
        let source = money == nil ? "Aryeo" : "Aryeo and Stripe"
        // The data block is marked for caching: a follow-up within 5 minutes reuses it instead of re-reading it.
        var messages: [ClaudeMessage] = [.user([.cachedText("BUSINESS DATA (live from \(source)):\n" + context)]),
                                         .assistant("Got it. Ask away.")]
        for turn in history.suffix(6) {
            messages.append(.user([.text(turn.q)]))
            messages.append(.assistant(turn.a))
        }
        let now = "Now: \(FieldTime.format(Date(), "EEEE, MMMM d, yyyy h:mm a")) Eastern."
        let todayBlock = "TODAY\n" + now + (today.map { "\n" + $0 } ?? "")
        messages.append(.user([.text(todayBlock), .text(question)]))
        return try await claude.send(model: ClaudeClient.smart, system: system, messages: messages,
                                     maxTokens: ClaudeClient.maxOutput,
                                     options: .init(cacheConversation: true, effort: "low", fallback: true),
                                     onText: onText)
    }
}

// MARK: - Message drafts

public enum Drafts {
    /// Instant, no Claude needed.
    public static func onMyWay(job: Job, minutes: Int = 15) -> String {
        let first = job.agentName.split(separator: " ").first.map(String.init) ?? "Hi"
        return "Hi \(first), Kyle from Horizon Home Media. On my way to \(job.street), about \(minutes) minutes out."
    }

    public static func reschedule(job: Job, issue: String, newTime: Date, claude: ClaudeClient?) async -> String {
        let first = job.agentName.split(separator: " ").first.map(String.init) ?? "Hi"
        let when = "\(FieldTime.format(newTime, "EEEE, MMM d")) at \(FieldTime.clockAMPM(newTime))"
        let plain = "Hi \(first), Kyle from Horizon Home Media. The forecast for \(job.street) looks rough (\(issue.lowercased())). Could we move the shoot to \(when)? Happy to work around you."
        guard let claude = claude else { return plain }
        let prompt = """
        Rewrite this text message to a real estate agent so it sounds like a friendly, busy photographer texting. \
        Keep every fact. Under 45 words. No emojis. Reply with the message only.

        \(plain)
        """
        return (try? await claude.send(model: ClaudeClient.fast, system: nil, messages: [.user([.text(prompt)])], maxTokens: ClaudeClient.maxOutput))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? plain
    }
}
