// SPDX-License-Identifier: MIT
// OpenClaw Toggle — popover view shown when the menu bar icon is clicked.

import SwiftUI

/// The small popover UI displayed from the menu bar icon.
/// Clean, minimal macOS-native design with Instagram-style status ring avatar.
struct PopoverView: View {
    @ObservedObject var monitor: StatusMonitor

    var body: some View {
        VStack(spacing: 0) {

            // ── Header: Avatar + Status ──────────────────────────────
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
                    action: { Task { await monitor.toggleNode() } }
                )
            }
            .padding(.vertical, 4)

            Divider()
                .padding(.horizontal, 12)

            // ── Quit ─────────────────────────────────────────────────
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 280)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            // Instagram-style circular avatar with status ring
            AvatarRingView(state: monitor.state, diameter: 40)

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
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            // Status dot
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
                Button(isActive || isLoaded ? "Stop" : "Start") {
                    action()
                }
                .buttonStyle(ServiceButtonStyle(isActive: isActive || isLoaded))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Avatar Ring View (Instagram Close Friends style)
// ---------------------------------------------------------------------------

/// Draws a circular avatar with an optional Instagram-style ring.
/// Used in both the popover header and could be reused elsewhere.
private struct AvatarRingView: View {
    let state: ConnectionState
    let diameter: CGFloat

    /// Ring thickness as proportion of diameter
    private var ringWidth: CGFloat { max(2.0, diameter * 0.06) }
    /// Gap between ring and avatar
    private var gap: CGFloat { max(1.5, diameter * 0.04) }
    /// Avatar diameter after subtracting ring + gap
    private var avatarDiameter: CGFloat {
        diameter - (ringWidth + gap) * 2
    }

    var body: some View {
        ZStack {
            // Ring (only when not disconnected)
            if state != .disconnected {
                Circle()
                    .stroke(ringColor, lineWidth: ringWidth)
                    .frame(width: diameter, height: diameter)
            }

            // Circular avatar
            AlfredAvatarImage(diameter: avatarDiameter, dimmed: state == .disconnected)
        }
        .frame(width: diameter, height: diameter)
    }

    private var ringColor: Color {
        switch state {
        case .connected:    return .green
        case .tunnelOnly:   return .yellow
        case .disconnected: return .clear
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Alfred Avatar Image
// ---------------------------------------------------------------------------

/// Loads the Alfred icon from disk and displays it clipped to a circle.
private struct AlfredAvatarImage: View {
    let diameter: CGFloat
    let dimmed: Bool

    private static let image: NSImage? = {
        let bundlePath = Bundle.main.bundlePath
            + "/Contents/Resources/alfred-icon.png"
        if let img = NSImage(contentsOfFile: bundlePath) { return img }
        let fallback = NSString(
            string: "~/Projects/OpenClawToggle/Resources/alfred-icon.png"
        ).expandingTildeInPath
        return NSImage(contentsOfFile: fallback)
    }()

    var body: some View {
        Group {
            if let nsImage = Self.image {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .opacity(dimmed ? 0.45 : 1.0)
            } else {
                Circle()
                    .fill(.quaternary)
                    .frame(width: diameter, height: diameter)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Service Button Style
// ---------------------------------------------------------------------------

/// A clean, minimal button style for start/stop service controls.
private struct ServiceButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(isActive ? .red : .green)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive
                        ? Color.red.opacity(0.1)
                        : Color.green.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive
                        ? Color.red.opacity(0.25)
                        : Color.green.opacity(0.25),
                        lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
