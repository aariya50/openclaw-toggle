// SPDX-License-Identifier: MIT
// OpenClaw Toggle — popover view shown when the menu bar icon is clicked.

import SwiftUI

/// The small popover UI displayed from the menu bar icon.
/// Clean, minimal macOS-native design with text-only status and controls.
struct PopoverView: View {
    @ObservedObject var monitor: StatusMonitor
    @ObservedObject var updater: SparkleUpdaterManager

    /// Callback to open the Preferences window.
    var onOpenPreferences: (() -> Void)?

    /// Callback to open the About window.
    var onOpenAbout: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {

            // ── Header: Status ────────────────────────────────────────
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)

            // ── Controls ─────────────────────────────────────────────
            VStack(spacing: 0) {
                serviceRow(
                    label: "SSH Tunnel",
                    isActive: monitor.tunnelActive,
                    isLoaded: monitor.tunnelServiceLoaded,
                    isToggling: monitor.isTunnelToggling,
                    action: { Task { await monitor.toggleTunnel() } }
                )

                Divider()
                    .padding(.horizontal, 12)

                serviceRow(
                    label: "Node Service",
                    isActive: monitor.nodeRunning,
                    isLoaded: monitor.serviceLoaded,
                    isToggling: monitor.isToggling,
                    disableStart: !monitor.tunnelActive,
                    action: { Task { await monitor.toggleNode() } }
                )
            }
            .padding(.vertical, 4)

            Divider()
                .padding(.horizontal, 12)

            // ── Footer: Preferences, About, Updates & Quit ────────
            HStack(spacing: 12) {
                Button {
                    onOpenPreferences?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gear")
                        Text("Preferences…")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)

                Button {
                    onOpenAbout?()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("About OpenClaw Toggle")

                Button {
                    updater.checkForUpdates()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(!updater.canCheckForUpdates)
                .help("Check for Updates")

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 16)
            }
            .padding(.vertical, 10)
        }
        .frame(width: 280)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.state.rawValue)
                    .font(.headline)
                    .foregroundStyle(monitor.state == .disconnected ? .secondary : .primary)

                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var statusSubtitle: String {
        switch monitor.state {
        case .connected:    return "All systems operational"
        case .tunnelOnly:   return "Node service is down"
        case .disconnected: return "All services stopped"
        }
    }

    // MARK: - Service Row

    private func serviceRow(
        label: String,
        isActive: Bool,
        isLoaded: Bool,
        isToggling: Bool,
        disableStart: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            // Status dot — reflects whether the service process is running
            Circle()
                .fill(isActive ? Color.green : Color.red.opacity(0.7))
                .frame(width: 7, height: 7)

            // Label
            Text(label)
                .font(.subheadline)

            Spacer()

            // Toggle button
            if isToggling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 52, height: 22)
            } else {
                Button(isActive ? "Stop" : "Start") {
                    action()
                }
                .controlSize(.small)
                // Disable the "Start" button when the prerequisite is not met
                // (e.g. node cannot start without the tunnel).
                .disabled(!isActive && disableStart)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
