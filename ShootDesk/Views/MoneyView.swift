import SwiftUI
import Charts

/// Everything Stripe knows about your money: what's landed, what's on the way, month by month against
/// last year, fees, payouts to the bank and every payment. Read-only.
struct MoneyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    @State private var showAllPayments = false
    @State private var showAllPayouts = false
    @Namespace private var ns

    private let cal = FieldTime.calendar
    private var now: Date { Date() }

    var body: some View {
        NavigationStack {
            Group {
                if model.stripeKey.isEmpty {
                    ContentUnavailableView {
                        Label("Connect Stripe", systemImage: "dollarsign.circle")
                    } description: {
                        Text("Add a read-only Stripe key in Settings to see what's landed, what's on the way and every payout.")
                    }
                } else if let m = model.money {
                    page(m)
                } else if let e = model.moneyError {
                    ContentUnavailableView("Couldn't reach Stripe", systemImage: "exclamationmark.triangle", description: Text(e))
                } else {
                    ProgressView("Reading Stripe…").task { await model.refreshMoney() }
                }
            }
            .background(Color(.systemBackground))
            .slimBar("Money")
            .toolbar {
                if size == .regular { TitleBarMark { StripeMark(height: 18) } }
            }
            .foldedTitleHidden()
            .refreshable { await model.refreshMoney() }
            .appDestinations(ns)
        }
    }

    /// "Payment for Order #1829" → the shoot for order 1829, so payments show the house they paid for.
    private func job(for t: StripeTxn) -> Job? {
        guard let r = t.description.range(of: #"#(\d+)"#, options: .regularExpression),
              let n = Int(t.description[r].dropFirst()) else { return nil }
        return model.jobs.first { $0.number == n }
    }

    // MARK: Numbers

    private struct ClientTotal: Identifiable {
        let name: String
        let net: Int
        let payments: Int
        var id: String { name }
    }

    /// Who actually paid you this year: Stripe payments matched to their order, totalled by agent.
    private func topClients(_ m: MoneySummary) -> (rows: [ClientTotal], matchedShare: Double) {
        guard let start = cal.date(from: cal.dateComponents([.year], from: now)) else { return ([], 0) }
        let list = m.transactions.filter { $0.isPayment && $0.created >= start }
        var totals: [String: (Int, Int)] = [:]
        var matched = 0
        for t in list {
            guard let j = job(for: t) else { continue }
            matched += t.net
            let cur = totals[j.agentName] ?? (0, 0)
            totals[j.agentName] = (cur.0 + t.net, cur.1 + 1)
        }
        let all = list.reduce(0) { $0 + $1.net }
        let rows = totals.map { ClientTotal(name: $0.key, net: $0.value.0, payments: $0.value.1) }
            .sorted { $0.net > $1.net }
        return (Array(rows.prefix(8)), all > 0 ? Double(matched) / Double(all) : 0)
    }

    private func net(_ m: MoneySummary, month d: Date) -> Int {
        m.transactions.filter { cal.isDate($0.created, equalTo: d, toGranularity: .month) }.reduce(0) { $0 + $1.net }
    }

    private func yearToDate(_ m: MoneySummary, yearsAgo: Int) -> (net: Int, fees: Int, gross: Int, count: Int) {
        guard let ref = cal.date(byAdding: .year, value: -yearsAgo, to: now),
              let start = cal.date(from: cal.dateComponents([.year], from: ref)) else { return (0, 0, 0, 0) }
        let list = m.transactions.filter { $0.created >= start && $0.created <= ref }
        return (list.reduce(0) { $0 + $1.net }, list.reduce(0) { $0 + $1.fee },
                list.filter(\.isPayment).reduce(0) { $0 + $1.amount }, list.filter(\.isPayment).count)
    }

    private struct MonthPoint: Identifiable {
        let month: Date
        let year: String
        let dollars: Double
        var id: String { year + FieldTime.format(month, "MM") }
    }

    /// Net received per month, this year and last year, plotted on the same Jan–Dec axis.
    private func monthly(_ m: MoneySummary) -> [MonthPoint] {
        let thisYear = cal.component(.year, from: now)
        var out: [MonthPoint] = []
        for offset in [0, 1] {
            let y = thisYear - offset
            for mo in 1...12 {
                guard let real = cal.date(from: DateComponents(year: y, month: mo, day: 1)),
                      let axis = cal.date(from: DateComponents(year: thisYear, month: mo, day: 1)) else { continue }
                if offset == 0 && real > now { continue }
                out.append(MonthPoint(month: axis, year: String(y), dollars: Double(net(m, month: real)) / 100))
            }
        }
        return out
    }

    private func whole(_ cents: Int) -> String { Money.dollars((cents / 100) * 100) }

    /// Where the year should land if the rest of it goes the way the rest of last year did.
    /// Uses last year's shape, so a slow winter doesn't get counted as a slow year.
    private func pace(_ m: MoneySummary, ytd: Int, lastYtd: Int) -> String? {
        let lastYear = cal.component(.year, from: now) - 1
        guard let start = cal.date(from: DateComponents(year: lastYear, month: 1, day: 1)),
              let end = cal.date(from: DateComponents(year: lastYear + 1, month: 1, day: 1)) else { return nil }
        let lastFull = m.transactions.filter { $0.created >= start && $0.created < end }.reduce(0) { $0 + $1.net }
        guard lastYtd > 0, lastFull > lastYtd, ytd > 0 else { return nil }
        let rest = lastFull - lastYtd
        let estimate = ytd + Int(Double(rest) * Double(ytd) / Double(lastYtd))
        let rounded = (estimate / 100_000) * 100_000   // nearest $1,000 down
        return "On pace for about \(Money.dollars(rounded)) this year, if the rest of it goes like the rest of \(lastYear). Last year finished at \(whole(lastFull))."
    }

    // MARK: Page

    private func page(_ m: MoneySummary) -> some View {
        let month = FieldTime.format(now, "MMMM")
        let thisMonth = net(m, month: now)
        // Same stretch last year: the 1st of this month up to today's date, a year ago.
        let lastYearNow = cal.date(byAdding: .year, value: -1, to: now) ?? now
        let lastYearMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: lastYearNow)) ?? lastYearNow
        let sameMonthLastYear = m.transactions.filter { $0.created >= lastYearMonthStart && $0.created <= lastYearNow }
            .reduce(0) { $0 + $1.net }
        let ytd = yearToDate(m, yearsAgo: 0)
        let lastYtd = yearToDate(m, yearsAgo: 1)
        let wide = size == .regular

        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                // The number that matters
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Received in \(month)").font(.headline).foregroundStyle(.secondary)
                        // Folded, the title bar is gone, so the Stripe mark sits here instead.
                        if !wide { Spacer(); StripeMark(height: 16) }
                    }
                    Text(whole(thisMonth))
                        .font(.system(size: wide ? 56 : 44, weight: .semibold, design: .serif))
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text(compare(thisMonth, sameMonthLastYear, label: "\(month) 1–\(cal.component(.day, from: now)) last year"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                // Where the money is right now
                HStack(alignment: .top, spacing: 0) {
                    figure("Available", whole(m.available), m.available < 0 ? "comes out of the next payout" : "ready to pay out")
                    Divider().padding(.horizontal, 14)
                    figure("On the way", whole(m.pending), "still clearing")
                    Divider().padding(.horizontal, 14)
                    if let p = m.nextPayout {
                        figure("Next payout", whole(p.amount), "lands \(FieldTime.format(p.arrival, "EEE MMM d"))")
                    } else if let p = m.lastPayout {
                        figure("Last payout", whole(p.amount), "landed \(FieldTime.format(p.arrival, "MMM d"))")
                    } else {
                        figure("Payouts", "—", "none yet")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                // Month by month
                VStack(alignment: .leading, spacing: 10) {
                    Text("Month by month").font(.title3.weight(.semibold))
                    Chart(monthly(m)) { p in
                        BarMark(x: .value("Month", p.month, unit: .month), y: .value("Received", p.dollars))
                            .foregroundStyle(by: .value("Year", p.year))
                            .position(by: .value("Year", p.year))
                            .cornerRadius(3)
                    }
                    .chartForegroundStyleScale([String(cal.component(.year, from: now) - 1): Color.secondary.opacity(0.35),
                                                String(cal.component(.year, from: now)): Theme.accent])
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) { _ in
                            AxisValueLabel(format: .dateTime.month(.narrow))
                        }
                    }
                    .chartYAxis {
                        AxisMarks { v in
                            AxisGridLine()
                            AxisValueLabel { if let d = v.as(Double.self) { Text(d >= 1000 ? "$\(Int(d / 1000))k" : "$\(Int(d))") } }
                        }
                    }
                    .frame(height: wide ? 260 : 200)
                }

                // The year so far
                VStack(alignment: .leading, spacing: 12) {
                    Text("This year so far").font(.title3.weight(.semibold))
                    if let line = pace(m, ytd: ytd.net, lastYtd: lastYtd.net) {
                        Label(line, systemImage: "chart.line.uptrend.xyaxis")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading), count: wide ? 4 : 2),
                              alignment: .leading, spacing: 18) {
                        figure("Received", whole(ytd.net), compare(ytd.net, lastYtd.net, label: "this time last year"))
                        figure("Payments", "\(ytd.count)", ytd.count > 0 ? "about \(whole(ytd.gross / max(ytd.count, 1))) each" : "")
                        figure("Stripe fees", whole(ytd.fees),
                               ytd.gross > 0 ? String(format: "%.1f%% of what clients paid", Double(ytd.fees) / Double(ytd.gross) * 100) : "")
                        figure("Charged", whole(ytd.gross), "before fees and refunds")
                    }
                }

                clientsSection(m)

                // Lists
                if wide {
                    HStack(alignment: .top, spacing: 28) {
                        paymentsList(m).frame(maxWidth: .infinity)
                        payoutsList(m).frame(maxWidth: .infinity)
                    }
                } else {
                    paymentsList(m)
                    payoutsList(m)
                }

                Text("From Stripe, checked \(FieldTime.clockAMPM(m.checkedAt)). Pull down to refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Gutter.of(size))
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder private func clientsSection(_ m: MoneySummary) -> some View {
        let top = topClients(m)
        if !top.rows.isEmpty {
            let best = max(top.rows.first?.net ?? 1, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Who paid you this year").font(.title3.weight(.semibold))
                Text("From Stripe payments matched to their orders (\(Int((top.matchedShare * 100).rounded()))% of this year's money).")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .top), count: size == .regular ? 2 : 1),
                          alignment: .leading, spacing: 0) {
                    ForEach(Array(top.rows.enumerated()), id: \.element.id) { i, c in
                        clientRow(c, rank: i + 1, share: Double(c.net) / Double(best))
                    }
                }
            }
        }
    }

    private func clientRow(_ c: ClientTotal, rank: Int, share: Double) -> some View {
        let stats = model.stats(for: c.name)
        let row = HStack(spacing: 12) {
            Monogram(name: c.name, initials: stats?.initials ?? String(c.name.prefix(2)).uppercased(), size: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(whole(c.net)).font(.system(.subheadline, design: .serif, weight: .semibold)).monospacedDigit()
                }
                GeometryReader { geo in
                    Capsule().fill(Theme.accent.opacity(rank == 1 ? 0.9 : 0.45))
                        .frame(width: max(6, geo.size.width * share))
                }
                .frame(height: 5)
                Text(c.payments == 1 ? "1 payment" : "\(c.payments) payments").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        return Group {
            if let stats {
                NavigationLink(value: AppRoute.customer(stats.id)) { row }.buttonStyle(.pressable)
            } else {
                row
            }
        }
    }

    private func compare(_ a: Int, _ b: Int, label: String) -> String {
        guard b != 0 else { return a == 0 ? "Nothing yet" : "Nothing in \(label)" }
        let diff = a - b
        if abs(diff) < 100 { return "Same as \(label)" }
        return "\(whole(abs(diff))) \(diff > 0 ? "more" : "less") than \(label)"
    }

    private func figure(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .serif, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paymentsList(_ m: MoneySummary) -> some View {
        let list = m.transactions.filter { $0.isPayment || $0.isRefund }
        let shown = showAllPayments ? Array(list.prefix(200)) : Array(list.prefix(12))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Payments").font(.title3.weight(.semibold)).padding(.bottom, 8)
            ForEach(shown) { t in
                if let j = job(for: t) {
                    NavigationLink(value: AppRoute.shoot(j.id)) { paymentRow(t, job: j) }
                        .buttonStyle(.pressable)
                } else {
                    paymentRow(t, job: nil)
                }
                Divider()
            }
            if list.count > 12 {
                Button(showAllPayments ? "Show fewer" : "Show all \(min(list.count, 200))") {
                    withAnimation { showAllPayments.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 10)
            }
        }
    }

    private func paymentRow(_ t: StripeTxn, job: Job?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let job { JobThumb(job: job, size: 40) }
            VStack(alignment: .leading, spacing: 2) {
                if let job {
                    Text(job.street).font(.address(.subheadline)).lineLimit(1)
                    Text("\(job.agentName), \(FieldTime.format(t.created, "MMM d"))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(t.description.isEmpty ? (t.isRefund ? "Refund" : "Payment") : t.description)
                        .font(.subheadline).lineLimit(1)
                    Text(FieldTime.format(t.created, "MMM d, yyyy")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.dollars(t.net)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(t.isRefund ? Color.red : Color.primary)
                if t.fee != 0 {
                    Text("\(Money.dollars(t.fee)) fee").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 9)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }

    private func payoutsList(_ m: MoneySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Payouts to your bank").font(.title3.weight(.semibold)).padding(.bottom, 8)
            if m.payouts.isEmpty { Text("No payouts yet.").foregroundStyle(.secondary) }
            ForEach(showAllPayouts ? m.payouts : Array(m.payouts.prefix(10))) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FieldTime.format(p.arrival, "EEE MMM d, yyyy")).font(.subheadline)
                        Text(status(p.status)).font(.caption)
                            .foregroundStyle(p.status == "failed" || p.status == "canceled" ? Color.red : Color.secondary)
                    }
                    Spacer()
                    Text(Money.dollars(p.amount)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                .padding(.vertical, 9)
                Divider()
            }
            if m.payouts.count > 10 {
                Button(showAllPayouts ? "Show fewer" : "Show all \(m.payouts.count)") {
                    withAnimation(.snappy) { showAllPayouts.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 10)
            }
        }
    }

    private func status(_ s: String) -> String {
        switch s {
        case "paid": return "In your bank"
        case "in_transit": return "On its way"
        case "pending": return "Scheduled"
        case "failed": return "Failed"
        case "canceled": return "Canceled"
        default: return s.capitalized
        }
    }
}
