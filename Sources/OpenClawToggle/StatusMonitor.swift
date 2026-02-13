// SPDX-License-Identifier: MIT
// OpenClaw Toggle — macOS menu bar app for OpenClaw node management.

import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - Connection State
// ---------------------------------------------------------------------------

/// Represents the aggregate health of the OpenClaw stack.
enum ConnectionState: String {
    case connected    = "Connected"      // tunnel + node both running
    case tunnelOnly   = "Tunnel Only"    // tunnel alive, node stopped
    case disconnected = "Disconnected"   // neither running

    /// SF Symbol color shown in the menu bar and status dot.
    var color: Color {
        switch self {
        case .connected:    return .green
        case .tunnelOnly:   return .yellow
        case .disconnected: return .red
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Status Monitor
// ---------------------------------------------------------------------------

/// Polls system state every few seconds and publishes the results so SwiftUI
/// views stay in sync automatically.
@MainActor
final class StatusMonitor: ObservableObject {

    // MARK: Published state

    @Published private(set) var tunnelActive: Bool = false
    @Published private(set) var nodeRunning: Bool  = false
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var isToggling: Bool = false

    // MARK: Configuration

    /// Local port used by the SSH tunnel.
    private let tunnelPort: UInt16 = 18789

    /// Launchd service label for the OpenClaw node.
    private let serviceLabel = "ai.openclaw.node"

    /// How often (in seconds) to refresh status.
    private let pollInterval: TimeInterval = 5

    /// The current user's UID (used in launchctl gui/<uid>/… paths).
    private let uid: String = {
        ProcessInfo.processInfo.environment["SUDO_UID"]
            ?? String(getuid())
    }()

    private var pollTask: Task<Void, Never>?

    // MARK: Lifecycle

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Refresh

    /// Runs both checks concurrently, then derives the aggregate state.
    func refresh() async {
        async let tunnel = checkTunnel()
        async let node   = checkNode()

        let (t, n) = await (tunnel, node)
        tunnelActive = t
        nodeRunning  = n

        switch (t, n) {
        case (true, true):   state = .connected
        case (true, false):  state = .tunnelOnly
        default:             state = .disconnected
        }
    }

    // MARK: Toggle

    /// Start or stop the launchd node service.
    func toggleNode() async {
        guard !isToggling else { return }
        isToggling = true
        defer { isToggling = false }

        if nodeRunning {
            await runShell("/bin/launchctl", arguments: [
                "kill", "SIGTERM", "gui/\(uid)/\(serviceLabel)"
            ])
        } else {
            await runShell("/bin/launchctl", arguments: [
                "kickstart", "-k", "gui/\(uid)/\(serviceLabel)"
            ])
        }

        // Brief pause so launchd has time to act, then refresh.
        try? await Task.sleep(for: .milliseconds(500))
        await refresh()
    }

    // MARK: - Private helpers

    /// Returns `true` when something is listening on `tunnelPort`.
    private func checkTunnel() async -> Bool {
        let output = await runShell(
            "/usr/sbin/lsof",
            arguments: ["-iTCP:\(tunnelPort)", "-sTCP:LISTEN", "-P", "-n"]
        )
        return !output.isEmpty
    }

    /// Returns `true` when the launchd service has a running PID.
    private func checkNode() async -> Bool {
        let output = await runShell(
            "/bin/launchctl", arguments: ["print", "gui/\(uid)/\(serviceLabel)"]
        )
        // `launchctl print` includes "state = running" when active
        // and "pid = <number>" when the process is alive.
        // A non-empty output that contains "pid =" with a numeric value
        // is a reliable indicator.
        let lines = output.lowercased()
        if lines.contains("state = running") { return true }
        // Fallback: check the legacy `launchctl list` approach.
        if lines.contains("could not find service") { return false }
        // If `print` worked but state isn't "running", check pid line.
        if let range = lines.range(of: "pid = ") {
            let after = lines[range.upperBound...]
            let digits = after.prefix(while: { $0.isNumber })
            if let pid = Int(digits), pid > 0 { return true }
        }
        return false
    }

    /// Runs a command and returns its trimmed stdout (ignoring failures).
    @discardableResult
    private func runShell(_ path: String, arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}
