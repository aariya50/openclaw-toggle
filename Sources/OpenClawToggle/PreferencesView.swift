// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Preferences panel for configuring services.

import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - Preferences View
// ---------------------------------------------------------------------------

/// A standalone settings window that lets the user configure tunnel port,
/// service labels, plist paths, gateway host — or auto-detect them from the
/// system.  Also includes health diagnostics, Launch at Login, and Sparkle
/// update controls.
///
/// Designed with native macOS `Form` / `Section` styling for a clean,
/// modern appearance.
struct PreferencesView: View {
    @ObservedObject var settings: AppSettings
    var updater: SparkleUpdaterManager?

    /// Locally-edited port string (converted to UInt16 on save).
    @State private var portText: String = ""

    /// Services discovered by the auto-detect scan.
    @State private var detectedServices: [ServiceDetector.DetectedService] = []
    @State private var showDetectResults = false
    @State private var detectMessage = ""

    var body: some View {
        Form {
            // ── SSH Tunnel ──────────────────────────────────────────
            Section {
                TextField("Gateway Host:", text: $settings.gatewayHost)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("Local Port:", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("TCP port for the SSH tunnel")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                TextField("Service Label:", text: $settings.tunnelServiceLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                TextField("Plist Path:", text: $settings.tunnelPlistPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            } header: {
                Label("SSH Tunnel", systemImage: "network")
            }

            // ── Node Service ────────────────────────────────────────
            Section {
                TextField("Service Label:", text: $settings.nodeServiceLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                TextField("Plist Path:", text: $settings.nodePlistPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            } header: {
                Label("Node Service", systemImage: "server.rack")
            }

            // ── Polling ─────────────────────────────────────────────
            Section {
                HStack(spacing: 8) {
                    TextField("Interval", value: $settings.pollInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Polling", systemImage: "clock.arrow.circlepath")
            }

            // ── General ─────────────────────────────────────────────
            Section {
                Toggle(isOn: $settings.launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("Start OpenClaw Toggle automatically when you log in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Label("General", systemImage: "gearshape")
            }

            // ── Auto-Detect Services ────────────────────────────────
            Section {
                Text("Scan ~/Library/LaunchAgents for OpenClaw plist files and auto-populate settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        runDetection()
                    } label: {
                        Label("Detect Services", systemImage: "antenna.radiowaves.left.and.right")
                    }

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
            } header: {
                Label("Auto-Detect Services", systemImage: "magnifyingglass")
            }

            // ── Software Update ─────────────────────────────────────
            Section {
                HStack(spacing: 12) {
                    Text("Version \(AppInfo.version) (\(AppInfo.build))")
                        .font(.callout.monospacedDigit())

                    Spacer()

                    if let updater {
                        Button {
                            updater.checkForUpdates()
                        } label: {
                            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(!updater.canCheckForUpdates)
                    }
                }

                Text("Updates are delivered automatically via Sparkle. When a new version is available it will be downloaded and installed on next launch.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Label("Software Update", systemImage: "arrow.triangle.2.circlepath")
            }

            // ── Health Diagnostics ──────────────────────────────────
            Section {
                HealthDiagnosticsView(settings: settings)
            } header: {
                Label("Health Diagnostics", systemImage: "stethoscope")
            }

            // ── Footer buttons ──────────────────────────────────────
            Section {
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
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .onAppear {
            syncFromSettings()
        }
        .onChange(of: portText) { _, newValue in
            if let p = UInt16(newValue), p > 0 {
                settings.tunnelPort = p
            }
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
