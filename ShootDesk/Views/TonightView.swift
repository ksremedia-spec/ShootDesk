import SwiftUI

/// The evening check: upcoming shoots with weather, drone airspace, agent-detail and timing problems flagged.
struct TonightView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.checkResults.isEmpty && !model.isChecking {
                    Card { Text("Nothing booked for the next two days.").foregroundStyle(.secondary) }
                }
                if size == .regular {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .top),
                                        GridItem(.flexible(), spacing: 18, alignment: .top)], spacing: 18) {
                        ForEach(model.checkResults) { r in CheckCard(result: r) }
                    }
                } else {
                    ForEach(model.checkResults) { r in
                        CheckCard(result: r)
                    }
                }
                Text("Forecast from the National Weather Service. Drone airspace checks cover New Bedford's airport.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Gutter.of(size))
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground))
        .slimBar("Upcoming check")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.runCheck() } } label: { Label("Check again", systemImage: "arrow.clockwise") }
                    .disabled(model.isChecking)
            }
        }
        .refreshable { await model.runCheck() }
    }

    private var headline: String {
        if model.isChecking { return "Checking…" }
        let n = model.checkResults.count
        let a = model.needsAttentionCount
        let shoots = n == 1 ? "1 shoot coming up" : "\(n) shoots coming up"
        if n == 0 { return "Nothing coming up" }
        if a == 0 { return "\(shoots), all clear" }
        return "\(shoots), \(a) \(a == 1 ? "needs" : "need") you"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let ran = model.checkRanAt {
                Text("Checked at \(FieldTime.clockAMPM(ran))").font(.subheadline).foregroundStyle(.secondary)
            }
            Text(headline)
                .font(.address(size == .regular ? 32 : 28))
        }
    }
}

struct CheckCard: View {
    @Environment(AppModel.self) private var model
    let result: CheckResult
    @State private var drafting = false

    private var job: Job { result.job }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(whenLine).font(.subheadline.weight(.semibold)).foregroundStyle(result.needsAttention ? Color.orange : Color.secondary)
                    Spacer()
                    if result.needsAttention { StatusChip(text: "Needs you", color: .orange) }
                }
                Text(job.street + (job.town.isEmpty ? "" : ", \(job.town)")).font(.address(.title3))
                Text("For \(job.agentName): \(job.packageSummary)").font(.subheadline).foregroundStyle(.secondary)
                ForEach(result.notes) { n in
                    Text(n.text).font(.footnote).foregroundStyle(Theme.accent)
                }
            }

            if result.issues.isEmpty && !result.weatherChecked {
                // Same as the Evening Check widget: no forecast means "not checked", not "all clear".
                Label("Weather not checked. Pull down to try again.", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            } else if result.issues.isEmpty {
                Label("All clear\(result.weatherLine.map { ", \($0)" } ?? "")", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(result.issues) { issue in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon(issue.kind)).foregroundStyle(color(issue.kind)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(issue.title).font(.subheadline.weight(.semibold))
                                Text(issue.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if issue.kind == .email || issue.kind == .unscheduled {
                                Button("Fix") { Launcher.open(job.adminURL) }
                                    .font(.subheadline.weight(.semibold))
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }

            if let s = result.suggestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Better day to move it to").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text("\(FieldTime.format(s.date, "EEEE, MMM d")) at \(FieldTime.clockAMPM(s.date))").font(.address(.headline))
                    Text(s.reason).font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            Task { await textAgent(suggestion: s) }
                        } label: {
                            HStack {
                                if drafting { ProgressView().tint(.white) }
                                Text("Text \(firstName)")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(drafting || job.agentPhone == nil)
                        Button { Launcher.open(job.adminURL) } label: {
                            Text("Reschedule in Aryeo").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(PrimaryActionStyle(prominent: false))
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var firstName: String { job.agentName.split(separator: " ").first.map(String.init) ?? "agent" }

    private var whenLine: String {
        guard let s = job.start else { return "No shoot time yet" }
        return "\(FieldTime.format(s, "EEE, MMM d")), \(job.timeRange)"
    }

    private func textAgent(suggestion s: CheckSuggestion) async {
        drafting = true
        defer { drafting = false }
        let issue = result.issues.first { $0.kind == .rain || $0.kind == .wind }?.title ?? "weather"
        let body = await Drafts.reschedule(job: job, issue: issue, newTime: s.date, claude: model.claude)
        Launcher.open(Phone.textURL(job.agentPhone, body: body))
    }

    private func icon(_ k: CheckIssue.Kind) -> String {
        switch k {
        case .rain: return "cloud.rain"
        case .wind: return "wind"
        case .airspace: return "airplane"
        case .email: return "envelope.badge"
        case .unscheduled: return "calendar.badge.exclamationmark"
        case .sunset: return "sun.horizon"
        }
    }

    private func color(_ k: CheckIssue.Kind) -> Color {
        switch k {
        case .rain, .wind: return .cyan
        case .airspace, .sunset: return .orange
        case .email, .unscheduled: return .red
        }
    }
}
