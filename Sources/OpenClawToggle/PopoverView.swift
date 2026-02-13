// SPDX-License-Identifier: MIT
// OpenClaw Toggle — popover view shown when the menu bar icon is clicked.

import SwiftUI

/// The small popover UI displayed from the menu bar icon.
struct PopoverView: View {
    @ObservedObject var monitor: StatusMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Header ────────────────────────────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.state.color)
                    .frame(width: 12, height: 12)

                Text(monitor.state.rawValue)
                    .font(.headline)
            }

            Divider()

            // ── Detail rows ───────────────────────────────────────────
            StatusRow(
                label: "SSH Tunnel (port 18789)",
                active: monitor.tunnelActive
            )

            StatusRow(
                label: "Node Service",
                active: monitor.nodeRunning
            )

            Divider()

            // ── Actions ───────────────────────────────────────────────
            Button {
                Task {
                    await monitor.toggleNode()
                }
            } label: {
                HStack {
                    Spacer()
                    if monitor.isToggling {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }
                    // Show "Stop Node" when service is loaded/running,
                    // "Start Node" when service has been booted out.
                    Text(buttonLabel)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .controlSize(.large)
            .disabled(monitor.isToggling)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(width: 260)
    }

    /// Determines the toggle button label based on whether the service
    /// is loaded in launchd (not just whether the process is running).
    private var buttonLabel: String {
        if monitor.nodeRunning || monitor.serviceLoaded {
            return "Stop Node"
        } else {
            return "Start Node"
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Status Row
// ---------------------------------------------------------------------------

/// A single status line: colored dot + label text.
private struct StatusRow: View {
    let label: String
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(active ? .green : .red)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.subheadline)

            Spacer()

            Text(active ? "Active" : "Inactive")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
