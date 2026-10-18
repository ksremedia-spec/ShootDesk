import SwiftUI

/// After delivery: town-record facts plus an MLS description and a social post that Claude writes from the photos.
struct ListingKitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let job: Job

    @State private var facts: PropertyFacts?
    @State private var factsLoaded = false
    @State private var kit: ListingKit?
    @State private var working = false
    @State private var error: String?
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    factsCard
                    if let kit = kit {
                        Picker("Draft", selection: $tab) {
                            Text("MLS description").tag(0)
                            Text("Your social post").tag(1)
                        }
                        .pickerStyle(.segmented)
                        Card(title: tab == 0 ? "Drafted from \(kit.photosUsed) of your photos" : "Drafted in your voice") {
                            Text(tab == 0 ? kit.mls : kit.social)
                                .font(.body)
                                .textSelection(.enabled)
                            HStack {
                                Button {
                                    UIPasteboard.general.string = tab == 0 ? kit.mls : kit.social
                                } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Spacer()
                                ShareLink(item: tab == 0 ? kit.mls : kit.social) { Label("Share", systemImage: "square.and.arrow.up") }
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        Text(tab == 0 ? "Size and lot come from town records. Beds and baths stay as [Beds]/[Baths] until the agent confirms them."
                                      : "Posts from your account, not the agent's.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Button {
                        Task { await write() }
                    } label: {
                        HStack {
                            if working { ProgressView().tint(.white) }
                            Text(working ? "Writing from your photos…" : (kit == nil ? "Write it" : "Rewrite it"))
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(.white)
                        .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(working || model.claude == nil)
                    if model.claude == nil {
                        Text("Add your Claude key in Settings to write drafts.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemBackground))
            .slimBar("Listing kit")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await loadFacts() }
        }
    }

    private var factsCard: some View {
        Card(title: "Town record for \(job.street)") {
            if !factsLoaded {
                ProgressView()
            } else if let f = facts {
                InfoRow(label: "Living area", value: f.livingAreaSqFt.map { "\($0.formatted()) sq ft" } ?? "—")
                InfoRow(label: "Lot", value: f.lotLabel ?? "—")
                InfoRow(label: "Built", value: f.yearBuilt.map(String.init) ?? "—")
                InfoRow(label: "Style", value: f.style?.capitalized ?? "—")
                InfoRow(label: "Rooms", value: f.rooms.map(String.init) ?? "—")
                InfoRow(label: "Bedrooms / baths", value: "Confirm with \(job.agentName.split(separator: " ").first.map(String.init) ?? "agent")",
                        valueColor: .secondary)
                Text("Town assessor records\(f.fiscalYear.map { ", fiscal \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No town record found. Massachusetts addresses only.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func loadFacts() async {
        defer { factsLoaded = true }
        guard let lat = job.latitude, let lon = job.longitude else { return }
        facts = try? await model.records.facts(lat: lat, lon: lon)
    }

    private func write() async {
        guard let claude = model.claude else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            kit = try await ListingKitWriter.write(job: job, facts: facts, claude: claude)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
