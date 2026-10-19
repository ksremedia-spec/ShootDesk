import SwiftUI

/// Ask questions about the business; Claude answers from a fresh snapshot of your Aryeo data.
struct AskView: View {
    @Environment(AppModel.self) private var model
    @State private var turns: [Turn] = []
    @State private var draft = ""
    @State private var thinking = false
    @FocusState private var focused: Bool
    @Environment(\.horizontalSizeClass) private var size

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var failed = false
    }

    private let suggestions = [
        "Who hasn't booked since spring?",
        "How is this month tracking against the same month last year?",
        "Which agents never add video?",
        "What are my top 5 towns this year?",
        "Who are my newest clients?",
        "How much has Stripe actually paid out this year, and what did fees cost me?",
    ]

    var body: some View {
        NavigationStack {
            Group {
                if size == .regular {
                    HStack(spacing: 0) {
                        askSidebar.frame(width: 360)
                        Divider()
                        chat
                    }
                } else {
                    chat
                }
            }
            .sensoryFeedback(.success, trigger: thinking) { was, now in was && !now }
            .slimBar("Ask")
            .toolbar {
                if !turns.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { turns = [] } label: { Label("New question", systemImage: "square.and.pencil") }
                    }
                }
            }
        }
    }

    /// Open Duo, left half: ideas to ask, and the questions asked so far.
    private var askSidebar: some View {
        List {
            Section("Try asking") {
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { ask(s) }
                        .disabled(model.claude == nil || model.jobs.isEmpty || thinking)
                }
            }
            if !turns.isEmpty {
                Section("This conversation") {
                    ForEach(turns) { t in
                        Label(t.question, systemImage: t.answer == nil ? "ellipsis.bubble" : "text.bubble")
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }

    private var chat: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if turns.isEmpty {
                            intro
                            // Open Duo: the right half shows your business at a glance until you ask something.
                            if size == .regular {
                                BusinessSnapshot(money: model.money, stripeConnected: !model.stripeKey.isEmpty, moneyError: model.moneyError,
                                                 missing: model.deliveryFlags, missingChecked: model.flagsChecked,
                                                 offline: model.errorMessage != nil,
                                                 jobs: model.jobs, customers: model.customers, ask: ask)
                            }
                        }
                        ForEach(turns) { t in
                            TurnView(turn: t, retry: t.failed && !thinking ? {
                                turns.removeAll { $0.id == t.id }
                                ask(t.question)
                            } : nil).id(t.id)
                        }
                        if thinking && turns.last?.answer == nil {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Claude is reading your orders. Detailed answers can take up to a minute.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: turns.count) { _, _ in
                    if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.money == nil ? "Questions about your business, answered from live Aryeo data." : "Questions about your business, answered from live Aryeo and Stripe data.")
                .foregroundStyle(.secondary)
            if model.claude == nil {
                Text("Add your Claude key in Settings to use Ask.").font(.footnote).foregroundStyle(.orange)
            }
            // On the open Duo the ideas sit in the left column instead.
            ForEach(size == .regular ? [] : suggestions, id: \.self) { s in
                Button { ask(s) } label: {
                    Text(s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.claude == nil || model.jobs.isEmpty)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about shoots, agents, money…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { ask(draft) }
                // A multi-line field turns Return into a new line; treat it as Send instead.
                .onChange(of: draft) { _, v in
                    if v.hasSuffix("\n") { draft.removeLast(); ask(draft) }
                }
            Button { ask(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(width: 36, height: 36)
                    .background(Theme.accent, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || thinking || model.claude == nil)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking, let claude = model.claude else { return }
        draft = ""
        focused = false
        let history = turns.filter { !$0.failed }.compactMap { t in t.answer.map { (q: t.question, a: $0) } }
        let turn = Turn(question: q)
        turns.append(turn)
        thinking = true
        Task {
            defer { thinking = false }
            var answer: String
            var failed = false
            do {
                // The answer types out as Claude writes it.
                let id = turn.id
                answer = try await AskContext.ask(q, history: history, jobs: model.jobs.filter { $0.status != .stale },
                                                  customers: model.customers, money: model.moneyContext(), claude: claude,
                                                  onText: { partial in
                                                      Task { @MainActor in
                                                          if let i = turns.firstIndex(where: { $0.id == id }),
                                                             (turns[i].answer?.count ?? 0) < partial.count {
                                                              turns[i].answer = partial
                                                          }
                                                      }
                                                  })
            } catch let e as URLError where [.networkConnectionLost, .notConnectedToInternet, .timedOut].contains(e.code) {
                answer = "The connection dropped before Claude finished answering."
                failed = true
            } catch {
                answer = error.localizedDescription
                failed = true
            }
            // The conversation may have been cleared while Claude was answering.
            if let i = turns.firstIndex(where: { $0.id == turn.id }) {
                turns[i].answer = answer
                turns[i].failed = failed
            }
        }
    }
}

struct TurnView: View {
    let turn: AskView.Turn
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 40)
                Text(turn.question)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if let a = turn.answer {
                Text(Self.markdown(a))
                    .lineSpacing(3)
                    .foregroundStyle(turn.failed ? Color.orange : Color.primary)
                    .textSelection(.enabled)
            }
            if let retry {
                Button(action: retry) { Label("Try again", systemImage: "arrow.clockwise") }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    /// Bold and italics render; list dashes become proper bullets.
    static func markdown(_ s: String) -> AttributedString {
        let tidy = s.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = line.prefix { $0 == " " }.count >= 2 ? "      " : ""
                return indent + "•  " + trimmed.dropFirst(2)
            }
            return line
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: tidy, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(tidy)
    }
}


/// Your numbers at a glance, worked out on the phone from the Aryeo data (no Claude cost).
/// Tap a tile to ask Claude about it.
struct BusinessSnapshot: View {
    var money: MoneySummary? = nil
    var stripeConnected = false
    var moneyError: String? = nil
    var missing: [DeliveryFlag] = []
    /// False while the first delivery check is still running.
    var missingChecked = true
    /// The last Aryeo download failed, so the Stripe and delivery checks that follow it haven't run.
    var offline = false
    let jobs: [Job]
    let customers: [CustomerStats]
    let ask: (String) -> Void

    private let cal = FieldTime.calendar
    private var now: Date { Date() }

    private func created(_ j: Job) -> Date? { FieldTime.parse(j.order.createdAt) }
    private func paid(_ j: Job) -> Int { j.order.totalAmount ?? 0 }
    private var delivered: [Job] { jobs.filter { $0.status == .delivered && paid($0) > 0 } }

    private func revenue(monthOf d: Date) -> (cents: Int, count: Int) {
        let list = delivered.filter { created($0).map { cal.isDate($0, equalTo: d, toGranularity: .month) } ?? false }
        return (list.reduce(0) { $0 + paid($1) }, list.count)
    }

    private var thisMonth: (cents: Int, count: Int) { revenue(monthOf: now) }
    private var lastYear: (cents: Int, count: Int) {
        revenue(monthOf: cal.date(byAdding: .year, value: -1, to: now) ?? now)
    }

    private var weekAhead: [Job] {
        let end = FieldTime.addDays(7, to: now)
        return jobs.filter { j in
            guard j.status != .delivered, j.status != .stale, let s = j.start else { return false }
            return s > now && s < end
        }.sorted { ($0.start ?? now) < ($1.start ?? now) }
    }

    private var shotThisMonth: Int {
        jobs.filter { j in
            guard let s = j.start, s < now, j.status != .stale else { return false }
            return cal.isDate(s, equalTo: now, toGranularity: .month)
        }.count
    }

    private var yearJobs: [Job] {
        delivered.filter { created($0).map { cal.isDate($0, equalTo: now, toGranularity: .year) } ?? false }
    }

    private var topTowns: [(String, Int)] {
        Dictionary(grouping: yearJobs.filter { !$0.town.isEmpty }, by: \.town)
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
    }

    private var topAgents: [(String, Int, Int)] {
        Dictionary(grouping: yearJobs, by: \.agentName)
            .map { ($0.key, $0.value.reduce(0) { $0 + paid($1) }, $0.value.count) }
            .sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
    }

    var body: some View {
        let month = FieldTime.format(now, "MMMM")
        let active = customers.filter { $0.group(now: now) == .active }.count
        let lapsed = customers.filter { $0.group(now: now) == .lapsed }.count
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                if let money {
                    tile("Received in \(month)", Money.dollars((money.monthNet / 100) * 100),
                         "\(money.monthPayments) payments, \(Money.dollars((money.monthFees / 100) * 100)) in fees",
                         ask: "How busy has \(month) been compared to last month?", stripe: true)
                } else if !stripeConnected {
                    tile("Money", "Not connected", "Add your key in Settings to see what's landed",
                         ask: "How many shoots did I deliver in \(month)?", stripe: true)
                } else if moneyError != nil || offline {
                    tile("Money", "Couldn't reach Stripe", "Open the Money tab to try again",
                         ask: "How many shoots did I deliver in \(month)?", stripe: true)
                } else {
                    tile("Money", "Checking…", "Reading Stripe",
                         ask: "How many shoots did I deliver in \(month)?", stripe: true)
                }
                tile("Next 7 days", "\(weekAhead.count) shoot\(weekAhead.count == 1 ? "" : "s")",
                     weekAhead.first.map { "Next: \($0.street)" } ?? "Nothing booked",
                     ask: "What does my next week look like?")
                if missingChecked {
                    tile("Missing", missing.isEmpty ? "All delivered" : "\(missing.count)",
                         missing.first.map { "\($0.job.street): \($0.line.lowercased())" } ?? "Every recent video and floor plan is in",
                         ask: "Which recent shoots are missing their video or floor plan?")
                } else if offline {
                    tile("Missing", "Not checked", "Needs a connection to Aryeo",
                         ask: "Which recent shoots are missing their video or floor plan?")
                } else {
                    tile("Missing", "Checking…", "Looking for videos and floor plans in Aryeo",
                         ask: "Which recent shoots are missing their video or floor plan?")
                }
                tile("Shot this month", "\(shotThisMonth)", "shoots done in \(month)",
                     ask: "How many shoots did I do in \(month) compared to last \(month)?")
                tile("Agents", "\(active) active", "\(lapsed) quiet lately, worth a check-in",
                     ask: "Which lapsed agents should I reach out to first?")
                tile("Top town this year", topTowns.first?.0 ?? "—",
                     topTowns.first.map { "\($0.1) shoots" } ?? "",
                     ask: "What are my top 5 towns this year?")
            }

            if !topAgents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Top agents this year, by amount booked").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    ForEach(Array(topAgents.enumerated()), id: \.offset) { i, a in
                        Button { ask("How is \(a.0) doing this year compared to last year?") } label: {
                            HStack {
                                Text("\(i + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                                Text(a.0).font(.body)
                                Spacer()
                                Text("\(a.2) \(a.2 == 1 ? "shoot" : "shoots"), \(Money.dollars(a.1))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < topAgents.count - 1 { Divider() }
                    }
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String, ask question: String, stripe: Bool = false) -> some View {
        Button { ask(question) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if stripe { Spacer(minLength: 4); StripeMark(height: 13) }
                }
                Text(value).font(.system(.title2, design: .serif, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
