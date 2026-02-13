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
                Image(systemName: "circle.fill")
                    .foregroundStyle(monitor.state.color)
                    .font(.system(size: 12))

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
                Task { await monitor.toggleNode() }
            } label: {
                HStack {
                    Spacer()
                    if monitor.isToggling {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }
                    Text(monitor.nodeRunning ? "Stop Node" : "Start Node")
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
            Image(systemName: "circle.fill")
                .foregroundStyle(active ? .green : .red)
                .font(.system(size: 8))

            Text(label)
                .font(.subheadline)

            Spacer()

            Text(active ? "Active" : "Inactive")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
