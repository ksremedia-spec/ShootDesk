import SwiftUI

/// Ask questions about the business; Claude answers from a fresh snapshot of your Aryeo data.
/// Answers stream in as a polished chat: tappable shoot and agent cards, a chart when it helps,
/// follow-up questions to tap, and press-and-hold voice (WhisperKit, on the phone).
struct AskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    @Namespace private var ns
    @State private var turns: [Turn] = AskHistory.load()
    @State private var draft = ""
    @State private var thinking = false
    @State private var path: [AppRoute] = []
    @State private var askTask: Task<Void, Never>?
    @State private var sendTick = 0
    @State private var micTick = 0
    @State private var offerVoice = false
    @State private var voiceNote: String?
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    struct Turn: Identifiable, Codable, Equatable {
        var id = UUID()
        let question: String
        var answer: String?
        var failed = false
    }

    private let suggestions = [
        "Who hasn't booked since spring?",
        "When am I free this week?",
        "What needs my attention before tomorrow's shoots?",
        "How is this month tracking against the same month last year?",
        "What are my top 5 towns this year?",
        "How much has Stripe actually paid out this year, and what did fees cost me?",
    ]

    private var voice: VoiceInput { model.voice }

    var body: some View {
        NavigationStack(path: $path) {
            // Open Duo held wide: ideas and this conversation in a column on the left. Held tall (or folded)
            // there isn't room for it, so the ideas sit above the chat instead.
            GeometryReader { geo in
                if geo.size.width >= Gutter.sideColumnWidth {
                    HStack(spacing: 0) {
                        askSidebar.frame(width: 340)
                        Divider()
                        chat(sidebar: true)
                    }
                } else {
                    chat(sidebar: false)
                }
            }
            .sensoryFeedback(.success, trigger: thinking) { was, now in was && !now }
            .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
            .sensoryFeedback(.impact(weight: .medium), trigger: micTick)
            .slimBar("Ask")
            .toolbar {
                if !turns.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { newConversation() } label: { Label("New question", systemImage: "square.and.pencil") }
                    }
                }
            }
            .appDestinations(ns)
            .onChange(of: turns) { _, t in AskHistory.save(t) }
            .task {
                // Get the voice model into memory early, so the first hold doesn't wait on it.
                if voice.isDownloaded { await voice.prepare() }
            }
            .alert("Turn on voice?", isPresented: $offerVoice) {
                Button("Download \(VoiceInput.sizeLabel)") { Task { await voice.download() } }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Hold the mic and talk; let go to send. Voice needs a one-time \(VoiceInput.sizeLabel) download, so use Wi-Fi. What you say is turned into text on the phone and never leaves it.")
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

    private func chat(sidebar: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if turns.isEmpty {
                        intro(sidebar: sidebar)
                        // Open Duo: the right half shows your business at a glance until you ask something.
                        if size == .regular {
                            BusinessSnapshot(money: model.money, stripeConnected: !model.stripeKey.isEmpty, moneyError: model.moneyError,
                                             missing: model.deliveryFlags, missingChecked: model.flagsChecked,
                                             offline: model.errorMessage != nil,
                                             jobs: model.jobs, customers: model.customers, ask: ask)
                        }
                    }
                    ForEach(turns) { t in
                        TurnView(turn: t,
                                 streaming: thinking && t.id == turns.last?.id,
                                 isLast: t.id == turns.last?.id,
                                 followUp: { ask($0) },
                                 retry: t.failed && !thinking ? {
                                     turns.removeAll { $0.id == t.id }
                                     ask(t.question)
                                 } : nil)
                        .id(t.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Gutter.of(size))
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.count) { _, _ in
                if let last = turns.last { withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .top) } }
            }
            // Follow the answer as it grows, but only while Claude is writing.
            .onChange(of: turns.last?.answer?.count ?? 0) { _, _ in
                if thinking, (turns.last?.answer?.count ?? 0) > 400 { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { inputArea }
    }

    private func intro(sidebar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Theme.accent)
                Text("Ask about your business").font(.address(22))
            }
            Text(model.money == nil ? "Answered from live Aryeo data. Hold the mic to talk." : "Answered from live Aryeo and Stripe data. Hold the mic to talk.")
                .foregroundStyle(.secondary)
            if model.claude == nil {
                Text("Add your Claude key in Settings to use Ask.").font(.footnote).foregroundStyle(.orange)
            }
            // With the side column showing, the ideas are over there instead.
            if !sidebar {
                VStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { ask(s) } label: {
                            HStack {
                                Text(s).multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.pressable)
                        .disabled(model.claude == nil || model.jobs.isEmpty)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Input

    private var listening: Bool { voice.phase == .listening }

    private var inputArea: some View {
        VStack(spacing: 6) {
            if let line = voiceStatusLine {
                Text(line)
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                if listening || voice.phase == .transcribing {
                    ListeningBar(level: voice.level, text: voice.liveText, transcribing: voice.phase == .transcribing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Ask about shoots, agents, money…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit { ask(draft) }
                        // A multi-line field turns Return into a new line; treat it as Send instead.
                        .onChange(of: draft) { _, v in
                            if v.hasSuffix("\n") { draft.removeLast(); ask(draft) }
                        }
                }
                if draft.trimmingCharacters(in: .whitespaces).isEmpty && !listening {
                    micButton
                } else if !listening {
                    Button { ask(draft) } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .frame(width: 38, height: 38)
                            .background(Theme.accent, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(thinking || model.claude == nil)
                    .accessibilityLabel("Send")
                } else {
                    micButton
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(listening ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
        }
        .padding(.horizontal, Gutter.of(size) - 6)
        .padding(.bottom, 6)
        .animation(.snappy, value: voice.phase)
        .animation(.snappy, value: voiceNote)
    }

    private var voiceStatusLine: String? {
        if let voiceNote { return voiceNote }
        switch voice.phase {
        case .downloading(let f): return "Downloading voice… \(Int(f * 100))%"
        case .preparing where holding: return "Getting voice ready… the first time can take a couple of minutes"
        case .listening: return "Listening. Let go to send, slide up to cancel."
        case .failed(let m): return m
        default: return nil
        }
    }

    /// Hold to talk: finger down starts recording, finger up sends, sliding up and away cancels.
    private var micButton: some View {
        Image(systemName: listening ? "waveform" : "mic.fill")
            .font(.body.weight(.semibold))
            .symbolEffect(.variableColor.iterative, isActive: listening)
            .frame(width: 38, height: 38)
            .background(listening ? Theme.accent : Color(.tertiarySystemFill), in: Circle())
            .foregroundStyle(listening ? .white : Theme.accent)
            .scaleEffect(holding ? 1.15 : 1)
            .animation(.snappy, value: holding)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !holding { holding = true; beginHold() }
                        _ = v
                    }
                    .onEnded { v in
                        holding = false
                        endHold(cancelled: v.translation.height < -60)
                    }
            )
            .accessibilityLabel("Hold to talk")
            .accessibilityAddTraits(.isButton)
    }

    private func beginHold() {
        voice.clearError()
        voiceNote = nil
        switch voice.phase {
        case .needsDownload:
            offerVoice = true
        case .preparing:
            Task { await voice.prepare() }
        case .ready:
            guard !thinking, model.claude != nil else { return }
            focused = false
            holdTask = Task {
                if await voice.start(hint: model.voiceHint) {
                    AskSounds.play(.micOn)
                    micTick += 1
                }
            }
        default:
            break
        }
    }

    private func endHold(cancelled: Bool) {
        let started = holdTask
        holdTask = nil
        Task {
            await started?.value
            guard voice.phase == .listening else { return }
            if cancelled {
                voice.cancel()
                AskSounds.play(.micOff)
                return
            }
            let text = await voice.stop()
            AskSounds.play(.micOff)
            micTick += 1
            if text.isEmpty {
                voiceNote = "Didn't catch that. Hold the mic while you talk."
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                voiceNote = nil
            } else {
                ask(text)
            }
        }
    }

    // MARK: Asking

    private func newConversation() {
        askTask?.cancel()
        thinking = false
        turns = []
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
        sendTick += 1
        AskSounds.play(.send)
        let jobs = model.jobs.filter { $0.status != .stale }
        let customers = model.customers
        let money = model.moneyContext()
        let today = model.askToday()
        askTask = Task {
            var answer: String
            var failed = false
            do {
                // The answer types out as Claude writes it. Updates arrive in order; a fallback model taking
                // over mid-answer starts the text again, so take every update rather than only longer ones.
                let id = turn.id
                answer = try await AskContext.ask(q, history: history, jobs: jobs, customers: customers,
                                                  money: money, today: today, claude: claude,
                                                  onText: { partial in
                                                      Task { @MainActor in
                                                          if let i = turns.firstIndex(where: { $0.id == id }) {
                                                              withAnimation(.easeOut(duration: 0.25)) { turns[i].answer = partial }
                                                          }
                                                      }
                                                  })
            } catch is CancellationError {
                return
            } catch let e as URLError where e.code == .cancelled {
                return
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
            thinking = false
            if !failed { AskSounds.play(.done) }
        }
    }
}

/// The current conversation, kept on the phone so it's still there after the app closes.
/// "New question" starts over. Only the last 40 turns are kept.
enum AskHistory {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShootDesk", isDirectory: true).appendingPathComponent("ask.json")
    }
    static func load() -> [AskView.Turn] {
        guard let d = try? Data(contentsOf: url), let t = try? JSONDecoder().decode([AskView.Turn].self, from: d) else { return [] }
        // An answer that was still being written when the app closed is shown as stopped.
        return t.map { var x = $0; if x.answer == nil { x.answer = "This answer was interrupted."; x.failed = true }; return x }
    }
    static func save(_ turns: [AskView.Turn]) {
        let keep = Array(turns.suffix(40))
        if let d = try? JSONEncoder().encode(keep) { try? d.write(to: url, options: .atomic) }
    }
}

/// Shown in place of the text field while you hold the mic: a live level meter and the words so far.
struct ListeningBar: View {
    let level: Float
    let text: String
    let transcribing: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 3, height: 6 + CGFloat(level) * 20 * [0.5, 0.8, 1, 0.8, 0.5][i])
                }
            }
            .animation(.easeOut(duration: 0.1), value: level)
            .frame(height: 28)
            Text(transcribing ? (text.isEmpty ? "Writing it down…" : text) : (text.isEmpty ? "Listening…" : text))
                .lineLimit(2)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .contentTransition(.opacity)
        }
    }
}

// MARK: - One question and its answer

struct TurnView: View {
    @Environment(AppModel.self) private var model
    let turn: AskView.Turn
    var streaming = false
    var isLast = false
    var followUp: (String) -> Void = { _ in }
    var retry: (() -> Void)? = nil
    @State private var copied = false

    var body: some View {
        let parsed = AnswerParser.parse(turn.answer ?? "", streaming: streaming)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 48)
                Text(turn.question)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(turn.failed ? Color.orange : Theme.accent)
                    .symbolEffect(.pulse, isActive: streaming)
                    .frame(width: 22)
                    .padding(.top, 14)
                VStack(alignment: .leading, spacing: 12) {
                    if turn.answer == nil || (streaming && parsed.blocks.isEmpty) {
                        Text("Reading your orders…")
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    AnswerBody(blocks: parsed.blocks, failed: turn.failed)
                    if !streaming, turn.answer != nil, !turn.failed {
                        actions(parsed.plain)
                    }
                    if let retry {
                        Button(action: retry) { Label("Try again", systemImage: "arrow.clockwise") }
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if isLast, !streaming, !turn.failed, !parsed.followUps.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(parsed.followUps, id: \.self) { q in
                        Button { followUp(q) } label: {
                            Text(q)
                                .font(.subheadline)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(Capsule().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.leading, 32)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: streaming)
    }

    private func actions(_ plain: String) -> some View {
        HStack(spacing: 18) {
            Button {
                UIPasteboard.general.string = plain
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            ShareLink(item: plain) { Label("Share", systemImage: "square.and.arrow.up") }
            Spacer()
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .labelStyle(.iconOnly)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
    }
}

/// The answer, block by block: paragraphs, lists, shoot and agent cards, and a chart.
struct AnswerBody: View {
    let blocks: [AnswerBlock]
    var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                block(b).transition(.opacity)
            }
        }
    }

    @ViewBuilder private func block(_ b: AnswerBlock) -> some View {
        switch b {
        case .text(let s):
            Text(AnswerParser.inline(s))
                .lineSpacing(3)
                .foregroundStyle(failed ? Color.orange : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let items, let numbered):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(numbered ? "\(i + 1)." : "•")
                            .foregroundStyle(Theme.accent)
                            .monospacedDigit()
                            .frame(minWidth: numbered ? 18 : 10, alignment: .trailing)
                        Text(AnswerParser.inline(item)).lineSpacing(3).textSelection(.enabled)
                    }
                }
            }
        case .shoot(let number):
            ShootChip(number: number)
        case .agent(let name):
            AgentChip(name: name)
        case .chart(let spec):
            AnswerChart(spec: spec)
        case .chartPending:
            HStack(spacing: 8) {
                ProgressView()
                Text("Drawing a chart…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(height: 60)
        }
    }
}

/// A shoot Claude mentioned: tap to open its page.
struct ShootChip: View {
    @Environment(AppModel.self) private var model
    let number: Int

    var body: some View {
        if let job = model.jobs.first(where: { $0.number == number }) {
            NavigationLink(value: AppRoute.shoot(job.id)) {
                HStack(spacing: 12) {
                    JobThumb(job: job, size: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.street).font(.address(.subheadline)).foregroundStyle(.primary).lineLimit(1)
                        Text([job.town, job.start.map { FieldTime.format($0, "EEE MMM d") } ?? job.status.label]
                            .filter { !$0.isEmpty }.joined(separator: "   "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(8)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.pressable)
        }
    }
}

/// An agent Claude mentioned: tap for their page, or call or text right from the answer.
struct AgentChip: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        if let c = model.customers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            HStack(spacing: 12) {
                NavigationLink(value: AppRoute.customer(c.id)) {
                    HStack(spacing: 12) {
                        Text(c.initials)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 44)
                            .background(Theme.accent.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.address(.subheadline)).foregroundStyle(.primary).lineLimit(1)
                            Text("\(c.delivered) shoot\(c.delivered == 1 ? "" : "s")" + (c.lastOrder.map { ", last booked \(FieldTime.format($0, "MMM d"))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let call = Phone.dialURL(c.phone) {
                    circle("phone.fill", "Call \(c.name)") { Launcher.open(call) }
                }
                if let text = Phone.textURL(c.phone) {
                    circle("message.fill", "Text \(c.name)") { Launcher.open(text) }
                }
            }
            .padding(8)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func circle(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.subheadline.weight(.semibold))
                .frame(width: 38, height: 38)
                .background(Theme.accent.opacity(0.14), in: Circle())
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }
}

/// Lays chips out in rows, wrapping to the next line (no sideways scrolling).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { y += rowHeight + spacing; x = bounds.minX; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
