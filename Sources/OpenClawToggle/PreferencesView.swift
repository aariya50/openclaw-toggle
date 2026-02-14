// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Preferences window.

import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - Preferences View
// ---------------------------------------------------------------------------

struct PreferencesView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: SparkleUpdaterManager

    /// Callback to apply voice settings (restart/stop voice assistant).
    var onApplyVoiceSettings: (() -> Void)?

    @State private var portText = ""
    @State private var changesSaved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── General ─────────────────────────────────────────
                PrefsSection("General") {
                    HStack {
                        Text("Launch at Login")
                        Spacer()
                        Toggle("", isOn: $settings.launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    HStack {
                        Text("Polling Interval")
                        Spacer()
                        Picker("", selection: $settings.pollInterval) {
                            Text("1s").tag(TimeInterval(1))
                            Text("2s").tag(TimeInterval(2))
                            Text("3s").tag(TimeInterval(3))
                            Text("5s").tag(TimeInterval(5))
                            Text("10s").tag(TimeInterval(10))
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }

                // ── Voice Assistant ────────────────────────────────
                PrefsSection("Voice Assistant") {
                    HStack {
                        Text("Enable Voice Control")
                        Spacer()
                        Toggle("", isOn: $settings.voiceEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: settings.voiceEnabled) { _, _ in
                                onApplyVoiceSettings?()
                            }
                    }

                    if settings.voiceEnabled {
                        FieldRow("Wake Word") {
                            TextField("hey alfred", text: $settings.wakeWord)
                                .textFieldStyle(.roundedBorder)
                        }

                        FieldRow("OpenAI API Key") {
                            TextField("Paste API key here (⌘V)", text: $settings.openAIAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("GPT Model")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $settings.openAIModel) {
                                Text("GPT-4o Mini").tag("gpt-4o-mini")
                                Text("GPT-4o").tag("gpt-4o")
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }
                }

                // ── SSH Tunnel ──────────────────────────────────────
                PrefsSection("SSH Tunnel") {
                    FieldRow("Service Label") {
                        TextField("", text: $settings.tunnelServiceLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }

                    FieldRow("Plist Path") {
                        TextField("", text: $settings.tunnelPlistPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }

                    FieldRow("Gateway Host") {
                        TextField("e.g. gateway.openclaw.ai", text: $settings.gatewayHost)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Local Port")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("18789", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onChange(of: portText) { _, newValue in
                                if let p = UInt16(newValue), p > 0 {
                                    settings.tunnelPort = p
                                }
                            }
                    }
                }

                // ── Node Service ────────────────────────────────────
                PrefsSection("Node Service") {
                    FieldRow("Service Label") {
                        TextField("", text: $settings.nodeServiceLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }

                    FieldRow("Plist Path") {
                        TextField("", text: $settings.nodePlistPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }
                }

                // ── Auto-Detect ─────────────────────────────────────
                AutoDetectSection(settings: settings)

                Divider()

                // ── Updates ─────────────────────────────────────────
                UpdatesSection()

                // ── Diagnostics ─────────────────────────────────────
                DiagnosticsSection(settings: settings)

                Divider()

                // ── Reset / Save ────────────────────────────────────
                HStack {
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                        portText = String(settings.tunnelPort)
                        changesSaved = false
                    }
                    .controlSize(.small)

                    Spacer()

                    if changesSaved {
                        Text("Saved ✓")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Button("Save Changes") {
                        // Settings auto-persist via UserDefaults didSet,
                        // but restart voice assistant to pick up changes.
                        onApplyVoiceSettings?()
                        changesSaved = true
                        // Reset the indicator after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            changesSaved = false
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .frame(width: 460, height: 780)
        .onAppear {
            portText = String(settings.tunnelPort)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Reusable Layout
// ---------------------------------------------------------------------------

/// A section with a bold header and grouped content.
private struct PrefsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(spacing: 8) {
                content
            }
        }
    }
}

/// A row with a label above a full-width control.
private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Auto-Detect
// ---------------------------------------------------------------------------

private struct AutoDetectSection: View {
    @ObservedObject var settings: AppSettings
    @State private var message = ""

    var body: some View {
        HStack(spacing: 12) {
            Button {
                let count = ServiceDetector.detectAndApply(to: settings)
                message = count > 0
                    ? "Applied \(count) service\(count == 1 ? "" : "s")."
                    : "No OpenClaw services found."
            } label: {
                Label("Auto-Detect Services", systemImage: "antenna.radiowaves.left.and.right")
            }
            .controlSize(.small)

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Updates
// ---------------------------------------------------------------------------

private struct UpdatesSection: View {
    @StateObject private var checker = GitHubUpdateChecker()

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Updates")
                .font(.headline)

            HStack(spacing: 10) {
                Text("v\(currentVersion)")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)

                if let release = checker.latestRelease {
                    if checker.isNewer {
                        Label("Update: \(release.tagName)", systemImage: "arrow.up.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else {
                        Label("Up to date", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                if let error = checker.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                Button {
                    Task { await checker.check() }
                } label: {
                    if checker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .controlSize(.small)
                .disabled(checker.isChecking)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - GitHub Update Checker
// ---------------------------------------------------------------------------

@MainActor
private final class GitHubUpdateChecker: ObservableObject {
    @Published var latestRelease: GitHubRelease?
    @Published var isNewer = false
    @Published var isChecking = false
    @Published var errorMessage: String?

    struct GitHubRelease: Decodable {
        let tagName: String
        let name: String
        let htmlUrl: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlUrl = "html_url"
        }
    }

    private let repoOwner = "aariya50"
    private let repoName = "openclaw-toggle"

    func check() async {
        isChecking = true
        errorMessage = nil
        latestRelease = nil
        isNewer = false
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            errorMessage = "Invalid URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "No response"
                return
            }
            if http.statusCode == 404 {
                errorMessage = "No releases yet"
                return
            }
            guard http.statusCode == 200 else {
                errorMessage = "HTTP \(http.statusCode)"
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latestRelease = release
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            let remote = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let local = currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            isNewer = remote.compare(local, options: .numeric) == .orderedDescending
        } catch is CancellationError {
            // ignore
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Diagnostics
// ---------------------------------------------------------------------------

private struct DiagnosticsSection: View {
    let settings: AppSettings
    @StateObject private var engine: DiagnosticsEngine

    init(settings: AppSettings) {
        self.settings = settings
        _engine = StateObject(wrappedValue: DiagnosticsEngine(settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Diagnostics")
                    .font(.headline)

                Spacer()

                if !engine.checks.isEmpty && !engine.isRunning {
                    let passed = engine.checks.filter { $0.status == .pass }.count
                    Text("\(passed)/\(engine.checks.count) passed")
                        .font(.caption)
                        .foregroundStyle(passed == engine.checks.count ? .green : .orange)
                }

                Button {
                    Task { await engine.runAll() }
                } label: {
                    if engine.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Run")
                    }
                }
                .controlSize(.small)
                .disabled(engine.isRunning)
            }

            if !engine.checks.isEmpty {
                VStack(spacing: 3) {
                    ForEach(engine.checks) { check in
                        HStack(spacing: 6) {
                            Image(systemName: check.status.icon)
                                .foregroundStyle(check.status.color)
                                .frame(width: 14)
                            Text(check.name)
                                .font(.caption)
                            Spacer()
                            Text(check.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
