// SPDX-License-Identifier: MIT
// OpenClaw Toggle — popover view shown when the menu bar icon is clicked.

import SwiftUI

/// The small popover UI displayed from the menu bar icon.
/// Clean, minimal macOS-native design with text-only status and controls.
struct PopoverView: View {
    @ObservedObject var monitor: StatusMonitor
    @ObservedObject var updater: SparkleUpdaterManager

    /// Whether voice mode is enabled (shows hotkey hint).
    var voiceEnabled: Bool = false

    /// Callback to open the Preferences window.
    var onOpenPreferences: (() -> Void)?

    /// Callback to open the About window.
    var onOpenAbout: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {

            // Header
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)

            // Controls
            VStack(spacing: 0) {
                serviceRow(
                    label: "SSH Tunnel",
                    isActive: monitor.tunnelActive,
                    isLoaded: monitor.tunnelServiceLoaded,
                    isToggling: monitor.isTunnelToggling,
                    onToggle: { Task { await monitor.toggleTunnel() } }
                )

                Divider()
                    .padding(.horizontal, 12)

                serviceRow(
                    label: "Node Service",
                    isActive: monitor.nodeRunning,
                    isLoaded: monitor.serviceLoaded,
                    isToggling: monitor.isToggling,
                    disableStart: !monitor.tunnelActive,
                    onToggle: { Task { await monitor.toggleNode() } }
                )
            }
            .padding(.vertical, 4)

            Divider()
                .padding(.horizontal, 12)

            // Footer
            HStack(spacing: 10) {
                Button {
                    onOpenPreferences?()
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Preferences")
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

            if voiceEnabled {
                HStack(spacing: 3) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9))
                    Text("⇧⌫")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .help("Hold Shift + Delete to talk to Alfred")
            }
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
        onToggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color.red.opacity(0.7))
                .frame(width: 7, height: 7)

            Text(label)
                .font(.subheadline)

            Spacer()

            if isToggling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 80, height: 22)
            } else {
                Button(isActive ? "Stop" : "Start") {
                    onToggle()
                }
                .controlSize(.small)
                .disabled(!isActive && disableStart)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
