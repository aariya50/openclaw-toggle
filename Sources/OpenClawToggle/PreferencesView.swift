// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Preferences panel for configuring services.

import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - GitHub Update Checker
// ---------------------------------------------------------------------------

/// Checks for updates against the GitHub Releases API for the
/// aariya50/openclaw-toggle repository.
@MainActor
final class GitHubUpdateChecker: ObservableObject {

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case updating
        case updateFinished(success: Bool, message: String)
        case error(String)

        static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.checking, .checking),
                 (.upToDate, .upToDate),
                 (.updating, .updating):
                return true
            case (.available(let a), .available(let b)):
                return a == b
            case (.updateFinished(let s1, let m1), .updateFinished(let s2, let m2)):
                return s1 == s2 && m1 == m2
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published var state: UpdateState = .idle

    /// The GitHub API endpoint for the latest release.
    private let apiURL = URL(string: "https://api.github.com/repos/aariya50/openclaw-toggle/releases/latest")!

    /// Check GitHub for the latest release and compare with current version.
    func checkForUpdates() {
        guard state != .checking && state != .updating else { return }
        state = .checking

        Task {
            do {
                var request = URLRequest(url: apiURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 15

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    state = .error("Could not reach GitHub (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    state = .error("Invalid response from GitHub")
                    return
                }

                // Strip leading "v" for comparison (e.g. "v2.1.0" → "2.1.0").
                let latestVersion = tagName.hasPrefix("v")
                    ? String(tagName.dropFirst())
                    : tagName
                let currentVersion = AppInfo.version

                if isVersion(latestVersion, newerThan: currentVersion) {
                    state = .available(version: latestVersion)
                } else {
                    state = .upToDate
                }
            } catch {
                state = .error("Network error: \(error.localizedDescription)")
            }
        }
    }

    /// Run `brew upgrade openclaw-toggle` in a background process.
    func runBrewUpgrade() {
        guard case .available = state else { return }
        state = .updating

        Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            // Use login shell to pick up the user's PATH (which includes Homebrew).
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "brew upgrade openclaw-toggle 2>&1"]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                await MainActor.run {
                    self.state = .updateFinished(success: false, message: "Failed to run brew: \(error.localizedDescription)")
                }
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let success = process.terminationStatus == 0

            await MainActor.run {
                if success {
                    self.state = .updateFinished(success: true, message: "Update complete! Restart the app to use the new version.")
                } else {
                    self.state = .updateFinished(success: false, message: "brew upgrade failed:\n\(output.prefix(200))")
                }
            }
        }
    }

    /// Simple semantic version comparison (supports major.minor.patch).
    private func isVersion(_ a: String, newerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)

        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }
}

// ---------------------------------------------------------------------------
// MARK: - Preferences View
// ---------------------------------------------------------------------------

/// A standalone window that lets the user configure tunnel port, service
/// labels, plist paths, gateway host — or auto-detect them from the system.
/// Also includes health diagnostics, Launch at Login, and Check for Updates.
struct PreferencesView: View {
    @ObservedObject var settings: AppSettings
    var updater: SparkleUpdaterManager?

    /// Locally-edited port string (converted to UInt16 on save).
    @State private var portText: String = ""

    /// Services discovered by the auto-detect scan.
    @State private var detectedServices: [ServiceDetector.DetectedService] = []
    @State private var showDetectResults = false
    @State private var detectMessage = ""

    /// GitHub update checker.
    @StateObject private var updateChecker = GitHubUpdateChecker()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── SSH Tunnel ──────────────────────────────────────
                sectionHeader("SSH Tunnel", icon: "network")

                VStack(alignment: .leading, spacing: 12) {
                    prefsRow(label: "Gateway Host") {
                        TextField("gateway.openclaw.ai", text: $settings.gatewayHost)
                            .textFieldStyle(.roundedBorder)
                    }
                    prefsRow(label: "Local Port") {
                        TextField("18789", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    prefsRow(label: "Service Label") {
                        TextField("ai.openclaw.ssh-tunnel", text: $settings.tunnelServiceLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                    prefsRow(label: "Plist Path") {
                        TextField("~/Library/LaunchAgents/…", text: $settings.tunnelPlistPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                }
                .padding(.leading, 4)

                Divider()

                // ── Node Service ────────────────────────────────────
                sectionHeader("Node Service", icon: "server.rack")

                VStack(alignment: .leading, spacing: 12) {
                    prefsRow(label: "Service Label") {
                        TextField("ai.openclaw.node", text: $settings.nodeServiceLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                    prefsRow(label: "Plist Path") {
                        TextField("~/Library/LaunchAgents/…", text: $settings.nodePlistPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                }
                .padding(.leading, 4)

                Divider()

                // ── Polling ─────────────────────────────────────────
                sectionHeader("Polling", icon: "clock.arrow.circlepath")

                prefsRow(label: "Interval") {
                    HStack(spacing: 8) {
                        TextField("3", value: $settings.pollInterval, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 4)

                Divider()

                // ── General ─────────────────────────────────────────
                sectionHeader("General", icon: "gearshape")

                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $settings.launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                            Text("Start OpenClaw Toggle automatically when you log in")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .padding(.leading, 4)

                Divider()

                // ── Auto-Detect Services ────────────────────────────
                sectionHeader("Auto-Detect Services", icon: "magnifyingglass")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Scan ~/Library/LaunchAgents for OpenClaw plist files and auto-populate settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            runDetection()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("Detect Services")
                            }
                        }
                        .controlSize(.regular)

                        if !detectMessage.isEmpty {
                            Text(detectMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }
                    }

                    if showDetectResults && !detectedServices.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(detectedServices) { svc in
                                HStack(spacing: 8) {
                                    Image(systemName: svc.role == .tunnel ? "network" : "server.rack")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(svc.label)
                                            .font(.callout.monospaced())
                                        Text(svc.role.rawValue)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button("Apply Detected Settings") {
                            ServiceDetector.detectAndApply(to: settings)
                            syncFromSettings()
                            detectMessage = "Applied!"
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 4)

                Divider()

                // ── Software Update ─────────────────────────────────
                sectionHeader("Software Update", icon: "arrow.triangle.2.circlepath")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Current version: \(AppInfo.version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            updateChecker.checkForUpdates()
                        } label: {
                            HStack(spacing: 4) {
                                if updateChecker.state == .checking {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(updateChecker.state == .checking ? "Checking…" : "Check for Updates")
                            }
                        }
                        .disabled(updateChecker.state == .checking || updateChecker.state == .updating)

                        updateStatusView
                    }

                    if case .available(let version) = updateChecker.state {
                        HStack(spacing: 12) {
                            Label("Update available: v\(version)", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.callout.weight(.medium))

                            Button {
                                updateChecker.runBrewUpgrade()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle")
                                    Text("Update via Homebrew")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }
                    }

                    if case .updating = updateChecker.state {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating via Homebrew…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if case .updateFinished(let success, let message) = updateChecker.state {
                        Label(message, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(success ? .green : .red)
                    }
                }
                .padding(.leading, 4)

                Divider()

                // ── Health Diagnostics ──────────────────────────────
                sectionHeader("Health Diagnostics", icon: "stethoscope")

                HealthDiagnosticsView(settings: settings)
                    .padding(.leading, 4)

                Divider()

                // ── Footer buttons ──────────────────────────────────
                HStack {
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                        syncFromSettings()
                    }
                    .controlSize(.small)

                    Spacer()

                    Button("Re-run Setup Wizard…") {
                        settings.hasCompletedSetup = false
                        NSApp.keyWindow?.close()
                    }
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(width: 500, height: 700)
        .onAppear {
            syncFromSettings()
        }
        .onChange(of: portText) { _, newValue in
            if let p = UInt16(newValue), p > 0 {
                settings.tunnelPort = p
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }

    // MARK: - Preferences Row

    private func prefsRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Update Status Inline

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateChecker.state {
        case .upToDate:
            Label("You're up to date!", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func syncFromSettings() {
        portText = String(settings.tunnelPort)
    }

    private func runDetection() {
        detectedServices = ServiceDetector.detect()
        showDetectResults = true
        if detectedServices.isEmpty {
            detectMessage = "No OpenClaw services found."
        } else {
            detectMessage = "Found \(detectedServices.count) service(s)"
        }
    }
}
