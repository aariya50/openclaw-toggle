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

    /// Callback to open the Logs window.
    var onOpenLogs: (() -> Void)?

    /// Whether a manual refresh is in progress.
    @State private var isRefreshing = false

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
                    onToggle: { Task { await monitor.toggleTunnel() } },
                    onRestart: { Task { await monitor.restartTunnel() } }
                )

                Divider()
                    .padding(.horizontal, 12)

                serviceRow(
                    label: "Node Service",
                    isActive: monitor.nodeRunning,
                    isLoaded: monitor.serviceLoaded,
                    isToggling: monitor.isToggling,
                    disableStart: !monitor.tunnelActive,
                    onToggle: { Task { await monitor.toggleNode() } },
                    onRestart: { Task { await monitor.restartNode() } }
                )
            }
            .padding(.vertical, 4)

            Divider()
                .padding(.horizontal, 12)

            // ── Footer: Preferences, About, Logs, Refresh & Quit ──
            HStack(spacing: 10) {
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
                    onOpenLogs?()
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("View Logs")

                Button {
                    Task {
                        isRefreshing = true
                        await monitor.refresh()
                        // Brief delay so the spinner is visible even on fast refreshes
                        try? await Task.sleep(for: .milliseconds(400))
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(isRefreshing)
                .help("Refresh Status")

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
        .frame(width: 300)
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
        onToggle: @escaping () -> Void,
        onRestart: @escaping () -> Void
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

            // Toggle + Restart buttons
            if isToggling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 80, height: 22)
            } else {
                HStack(spacing: 6) {
                    // Restart button (only shown when service is active)
                    if isActive {
                        Button {
                            onRestart()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption2)
                        }
                        .controlSize(.small)
                        .help("Restart")
                    }

                    Button(isActive ? "Stop" : "Start") {
                        onToggle()
                    }
                    .controlSize(.small)
                    // Disable the "Start" button when the prerequisite is not met
                    // (e.g. node cannot start without the tunnel).
                    .disabled(!isActive && disableStart)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
