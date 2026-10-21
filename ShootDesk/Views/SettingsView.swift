import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.horizontalSizeClass) private var size

    @State private var aryeo = ""
    @State private var claude = ""
    @State private var stripe = ""
    @State private var saving = false
    @State private var saved = false
    @State private var claudeTest: String?
    @AppStorage("morningBriefing") private var morningBriefing = true
    @AppStorage(AskSounds.settingKey) private var askSounds = true

    private var changed: Bool {
        aryeo != model.aryeoKey || claude != model.claudeKey || stripe != model.stripeKey
    }

    var body: some View {
        NavigationStack {
            Group {
                if size == .regular {
                    // Open Duo: two columns, so nothing is lost to empty margins.
                    HStack(alignment: .top, spacing: 0) {
                        Form { appearanceSection; connectionsSection; moneyErrorSection }
                            .contentMargins(.leading, 28, for: .scrollContent)
                            .contentMargins(.trailing, 14, for: .scrollContent)
                        Form { alertsSection; dataSection; claudeSection; askSection; aboutSection }
                            .contentMargins(.leading, 14, for: .scrollContent)
                            // Clear of the floating tab bar on the right edge.
                            .contentMargins(.trailing, 64, for: .scrollContent)
                    }
                } else {
                    Form { appearanceSection; connectionsSection; moneyErrorSection; alertsSection; dataSection; claudeSection; askSection; aboutSection }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .slimBar("Settings", grouped: true)
            .sensoryFeedback(.success, trigger: saved) { _, new in new }
            .onAppear {
                aryeo = model.aryeoKey
                claude = model.claudeKey
                stripe = model.stripeKey
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Appearance")
        }
    }

    private var connectionsSection: some View {
        Section {
            keyRow(name: "Aryeo", isOn: model.hasAryeoKey, text: $aryeo, prompt: "API key")
            keyRow(name: "Claude", isOn: model.claude != nil, text: $claude, prompt: "API key (sk-ant-…)")
            keyRow(logo: true, isOn: model.money != nil || (!model.stripeKey.isEmpty && model.moneyError == nil), text: $stripe, prompt: "Restricted key (rk_live_…)")
            Button {
                Task {
                    saving = true
                    saved = false
                    await model.saveKeys(aryeo: aryeo, claude: claude, stripe: stripe)
                    saving = false
                    withAnimation { saved = true }
                }
            } label: {
                HStack {
                    Text("Save keys").fontWeight(.semibold)
                    Spacer()
                    if saving { ProgressView() }
                    else if saved && !changed {
                        Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            .disabled(saving || !changed)
        } header: {
            Text("Connections")
        } footer: {
            Text("Keys stay in this iPhone's keychain. The Stripe key is read-only, so it can never move money. Maps are Apple Maps and need no key.")
        }
    }

    @ViewBuilder private var moneyErrorSection: some View {
        if let e = model.moneyError, !model.stripeKey.isEmpty {
            Section { Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
        }
    }

    private var alertsSection: some View {
        Section {
            Toggle("Morning briefing at 7 AM", isOn: $morningBriefing)
                .onChange(of: morningBriefing) { _, _ in
                    Task { await MorningBriefing.schedule(jobs: model.visibleJobs, checks: model.checkResults) }
                }
        } header: {
            Text("Alerts")
        } footer: {
            Text("On shoot days: what's booked and anything the upcoming check flagged. Leave-by alerts and the Lock Screen countdown always come with your next shoot.")
        }
    }

    private var dataSection: some View {
        Section("Your data") {
            LabeledContent("Shoots", value: "\(model.visibleJobs.count)")
            LabeledContent("Agents", value: "\(model.customers.count)")
            if let u = model.lastUpdated {
                LabeledContent("Updated", value: u.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                Task { await model.refresh(full: true) }
            } label: {
                HStack {
                    Text("Re-download everything from Aryeo")
                    if model.isRefreshing { Spacer(); ProgressView() }
                }
            }
            .disabled(!model.hasAryeoKey || model.isRefreshing)
            if let err = model.errorMessage { Text(err).font(.footnote).foregroundStyle(.red) }
        }
    }

    private var claudeSection: some View {
        Section {
            Button("Test Claude") { Task { await testClaude() } }
                .disabled(model.claude == nil)
            if let t = claudeTest { Text(t).font(.footnote).foregroundStyle(.secondary) }
        } footer: {
            Text("Claude writes listing kits, answers Ask questions and drafts texts. For Ask it gets your Aryeo orders and, with Stripe connected, your Stripe totals and recent payments. It never changes anything in Aryeo or Stripe.")
        }
    }

    /// Ask's sounds, and the voice model it downloads for press-and-hold talking.
    private var askSection: some View {
        Section {
            Toggle("Sounds in Ask", isOn: $askSounds)
            switch model.voice.phase {
            case .needsDownload:
                Button("Download voice (\(VoiceInput.sizeLabel))") { Task { await model.voice.download() } }
            case .downloading(let f):
                HStack { Text("Downloading voice"); Spacer(); Text("\(Int(f * 100))%").monospacedDigit().foregroundStyle(.secondary) }
            case .preparing:
                HStack { Text("Getting voice ready"); Spacer(); ProgressView() }
            case .failed(let m):
                Text(m).font(.footnote).foregroundStyle(.orange)
                Button("Try again") { model.voice.clearError(); Task { if model.voice.isDownloaded { await model.voice.prepare() } else { await model.voice.download() } } }
            default:
                LabeledContent("Voice", value: "Ready (\(VoiceInput.sizeLabel) on this phone)")
                Button("Remove voice download", role: .destructive) { model.voice.deleteModel() }
            }
        } header: {
            Text("Ask")
        } footer: {
            Text("Hold the mic in Ask and talk; let go to send. Speech is turned into text on the phone with WhisperKit (OpenAI's Whisper model), so your voice never leaves it. Sounds stay quiet when the phone is on silent.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("ShootDesk", value: version)
        } footer: {
            Text("Built for Horizon Home Media.")
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    /// One connection: the service on the left, the key field, and a green dot once it's working.
    private func keyRow(name: String = "", logo: Bool = false, isOn: Bool, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 12) {
            Group {
                if logo { StripeMark(height: 17) } else { Text(name).fontWeight(.medium) }
            }
            .frame(width: 64, alignment: .leading)
            SecureField(prompt, text: text)
                .textContentType(.password)
                .autocorrectionDisabled()
            Circle()
                .fill(isOn ? Color.green : Color(.tertiaryLabel))
                .frame(width: 8, height: 8)
                .accessibilityLabel(isOn ? "Connected" : "Not connected")
        }
    }

    private func testClaude() async {
        guard let c = model.claude else { return }
        claudeTest = "Asking…"
        do {
            let r = try await c.send(model: ClaudeClient.fast, system: nil,
                                     messages: [.user([.text("Reply with exactly: Connected.")])], maxTokens: 400)
            claudeTest = "Claude says: \(r)"
        } catch {
            claudeTest = error.localizedDescription
        }
    }
}
