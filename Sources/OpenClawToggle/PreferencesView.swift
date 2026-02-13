// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Preferences panel for configuring services.

import SwiftUI

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

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            Text("Preferences")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // ── Auto-detect ─────────────────────────────────
                    GroupBox(label: Label("Auto-Detect Services", systemImage: "magnifyingglass")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan ~/Library/LaunchAgents for OpenClaw plist files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("Detect Services") {
                                    runDetection()
                                }

                                if !detectMessage.isEmpty {
                                    Text(detectMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .transition(.opacity)
                                }
                            }

                            if showDetectResults && !detectedServices.isEmpty {
                                ForEach(detectedServices) { svc in
                                    HStack(spacing: 6) {
                                        Image(systemName: svc.role == .tunnel ? "network" : "server.rack")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(svc.label)
                                                .font(.caption.monospaced())
                                            Text(svc.role.rawValue)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }

                                Button("Apply Detected Settings") {
                                    ServiceDetector.detectAndApply(to: settings)
                                    syncFromSettings()
                                    detectMessage = "Applied!"
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // ── Tunnel settings ─────────────────────────────
                    GroupBox(label: Label("SSH Tunnel", systemImage: "network")) {
                        VStack(alignment: .leading, spacing: 8) {
                            settingsField(
                                label: "Gateway Host:",
                                text: $settings.gatewayHost,
                                help: "e.g. gateway.openclaw.ai or user@host"
                            )
                            settingsField(
                                label: "Port:",
                                text: $portText,
                                help: "Local port the tunnel forwards to"
                            )
                            settingsField(
                                label: "Service Label:",
                                text: $settings.tunnelServiceLabel,
                                help: "launchd label (e.g. ai.openclaw.ssh-tunnel)"
                            )
                            settingsField(
                                label: "Plist Path:",
                                text: $settings.tunnelPlistPath,
                                help: "Full path to the LaunchAgent plist"
                            )
                        }
                        .padding(.vertical, 4)
                    }

                    // ── Node settings ───────────────────────────────
                    GroupBox(label: Label("Node Service", systemImage: "server.rack")) {
                        VStack(alignment: .leading, spacing: 8) {
                            settingsField(
                                label: "Service Label:",
                                text: $settings.nodeServiceLabel,
                                help: "launchd label (e.g. ai.openclaw.node)"
                            )
                            settingsField(
                                label: "Plist Path:",
                                text: $settings.nodePlistPath,
                                help: "Full path to the LaunchAgent plist"
                            )
                        }
                        .padding(.vertical, 4)
                    }

                    // ── Polling ──────────────────────────────────────
                    GroupBox(label: Label("Polling", systemImage: "clock.arrow.circlepath")) {
                        HStack {
                            Text("Interval:")
                                .frame(width: 90, alignment: .trailing)
                            TextField("seconds", value: $settings.pollInterval, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    // ── General ──────────────────────────────────────
                    GroupBox(label: Label("General", systemImage: "gearshape")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $settings.launchAtLogin) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Launch at Login")
                                        .font(.subheadline)
                                    Text("Start OpenClaw Toggle automatically when you log in")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)

                            if let updater {
                                Divider()
                                HStack {
                                    CheckForUpdatesButton(updater: updater)
                                        .controlSize(.small)
                                    Spacer()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // ── Health Diagnostics ───────────────────────────
                    GroupBox {
                        HealthDiagnosticsView(settings: settings)
                            .padding(.vertical, 4)
                    }

                    // ── Footer buttons ──────────────────────────────
                    HStack {
                        Button("Reset to Defaults") {
                            settings.resetToDefaults()
                            syncFromSettings()
                        }
                        .controlSize(.small)

                        Spacer()

                        Button("Re-run Setup Wizard…") {
                            settings.hasCompletedSetup = false
                            // Close preferences — the app delegate will detect
                            // hasCompletedSetup=false on next launch or can
                            // handle it via notification.
                            NSApp.keyWindow?.close()
                        }
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 440, height: 680)
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

    @ViewBuilder
    private func settingsField(
        label: String,
        text: Binding<String>,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .frame(width: 90, alignment: .trailing)
                TextField(help, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
            }
        }
    }
}
