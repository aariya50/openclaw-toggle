// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Health Diagnostics engine and view.
//
// Performs a series of checks to verify the OpenClaw stack is correctly
// configured and running.  Used by both the Setup Wizard (final step)
// and the Preferences panel.

import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - Diagnostic Check Model
// ---------------------------------------------------------------------------

/// A single diagnostic check result.
struct DiagnosticCheck: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let status: Status

    enum Status {
        case pass
        case warn
        case fail
        case running

        var icon: String {
            switch self {
            case .pass:    return "checkmark.circle.fill"
            case .warn:    return "exclamationmark.triangle.fill"
            case .fail:    return "xmark.circle.fill"
            case .running: return "arrow.triangle.2.circlepath"
            }
        }

        var color: Color {
            switch self {
            case .pass:    return .green
            case .warn:    return .yellow
            case .fail:    return .red
            case .running: return .secondary
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Diagnostics Engine
// ---------------------------------------------------------------------------

/// Runs health-check diagnostics against the system.
@MainActor
final class DiagnosticsEngine: ObservableObject {

    @Published var checks: [DiagnosticCheck] = []
    @Published var isRunning = false

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Run all diagnostics sequentially.
    func runAll() async {
        isRunning = true
        checks = []

        // 1. Check tunnel plist exists
        checks.append(await checkFileExists(
            name: "Tunnel Plist",
            path: settings.tunnelPlistPath,
            description: "SSH tunnel LaunchAgent plist"
        ))

        // 2. Check node plist exists
        checks.append(await checkFileExists(
            name: "Node Plist",
            path: settings.nodePlistPath,
            description: "Node service LaunchAgent plist"
        ))

        // 3. Check tunnel service loaded in launchd
        checks.append(await checkServiceLoaded(
            name: "Tunnel Service",
            label: settings.tunnelServiceLabel
        ))

        // 4. Check node service loaded in launchd
        checks.append(await checkServiceLoaded(
            name: "Node Service",
            label: settings.nodeServiceLabel
        ))

        // 5. Check tunnel port listening
        checks.append(await checkPortListening(
            name: "Tunnel Port",
            port: settings.tunnelPort
        ))

        // 6. Check SSH connectivity (can we reach the gateway?)
        if !settings.gatewayHost.isEmpty {
            checks.append(await checkSSHConnectivity(
                name: "SSH Gateway",
                host: settings.gatewayHost
            ))
        }

        // 7. Check OpenAI API key
        if settings.voiceEnabled {
            checks.append(checkAPIKey())
        }

        isRunning = false
    }

    // MARK: - Individual checks

    private func checkFileExists(name: String, path: String, description: String) async -> DiagnosticCheck {
        let exists = FileManager.default.fileExists(atPath: path)
        return DiagnosticCheck(
            name: name,
            detail: exists ? path : "Not found: \(path)",
            status: exists ? .pass : .fail
        )
    }

    private func checkServiceLoaded(name: String, label: String) async -> DiagnosticCheck {
        let output = await runShell("/bin/launchctl", arguments: ["print", "gui/\(getuid())/\(label)"])
        let lower = output.lowercased()

        if lower.contains("could not find service") || output.isEmpty {
            return DiagnosticCheck(
                name: name,
                detail: "Service '\(label)' is not loaded",
                status: .fail
            )
        }

        if lower.contains("state = running") {
            return DiagnosticCheck(
                name: name,
                detail: "Service '\(label)' is running",
                status: .pass
            )
        }

        // Loaded but not running
        return DiagnosticCheck(
            name: name,
            detail: "Service '\(label)' is loaded but not running",
            status: .warn
        )
    }

    private func checkPortListening(name: String, port: UInt16) async -> DiagnosticCheck {
        let output = await runShell(
            "/usr/sbin/lsof",
            arguments: ["-iTCP:\(port)", "-sTCP:LISTEN", "-P", "-n"]
        )
        let listening = !output.isEmpty
        return DiagnosticCheck(
            name: name,
            detail: listening
                ? "Port \(port) is listening"
                : "Nothing listening on port \(port)",
            status: listening ? .pass : .fail
        )
    }

    private func checkSSHConnectivity(name: String, host: String) async -> DiagnosticCheck {
        // Try a quick SSH connection test with a 5-second timeout.
        // We use `ssh -o ConnectTimeout=5 -o BatchMode=yes` to avoid
        // password prompts.
        let output = await runShell("/usr/bin/ssh", arguments: [
            "-o", "ConnectTimeout=5",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            host,
            "echo ok"
        ])

        if output.contains("ok") {
            return DiagnosticCheck(
                name: name,
                detail: "Successfully connected to \(host)",
                status: .pass
            )
        }

        // Even if the command fails, if we got *any* output it means
        // SSH reached the host (might be auth failure, which is fine
        // for connectivity check).
        // Check if the error is a connection refusal vs auth failure.
        let errOutput = await runShellWithStderr("/usr/bin/ssh", arguments: [
            "-o", "ConnectTimeout=5",
            "-o", "BatchMode=yes",
            host,
            "echo ok"
        ])

        if errOutput.contains("Permission denied") || errOutput.contains("publickey") {
            return DiagnosticCheck(
                name: name,
                detail: "Reachable (auth may need configuration)",
                status: .warn
            )
        }

        return DiagnosticCheck(
            name: name,
            detail: "Cannot reach \(host)",
            status: .fail
        )
    }

    private func checkAPIKey() -> DiagnosticCheck {
        let key = settings.openAIAPIKey
        if !key.isEmpty {
            let masked = String(key.prefix(7)) + "..." + String(key.suffix(4))
            return DiagnosticCheck(
                name: "OpenAI API Key",
                detail: "Key set (\(masked))",
                status: .pass
            )
        }
        return DiagnosticCheck(
            name: "OpenAI API Key",
            detail: "No API key configured — voice commands won't work",
            status: .fail
        )
    }

    // MARK: - Shell helpers

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

    private func runShellWithStderr(_ path: String, arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let errPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Health Diagnostics View
// ---------------------------------------------------------------------------

/// Standalone view for health diagnostics, usable in Preferences or Wizard.
struct HealthDiagnosticsView: View {
    @StateObject private var engine: DiagnosticsEngine

    init(settings: AppSettings) {
        _engine = StateObject(wrappedValue: DiagnosticsEngine(settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Health Diagnostics", systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await engine.runAll() }
                } label: {
                    HStack(spacing: 4) {
                        if engine.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(engine.isRunning ? "Running…" : "Run Diagnostics")
                    }
                }
                .disabled(engine.isRunning)
                .controlSize(.small)
            }

            if engine.checks.isEmpty && !engine.isRunning {
                Text("Click \"Run Diagnostics\" to check your OpenClaw setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.checks) { check in
                        HStack(spacing: 8) {
                            Image(systemName: check.status.icon)
                                .foregroundStyle(check.status.color)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.name)
                                    .font(.subheadline.weight(.medium))
                                Text(check.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Summary
            if !engine.checks.isEmpty && !engine.isRunning {
                let passCount = engine.checks.filter { $0.status == .pass }.count
                let totalCount = engine.checks.count
                Divider()
                HStack {
                    Text("\(passCount)/\(totalCount) checks passed")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(passCount == totalCount ? .green : .orange)
                    Spacer()
                }
            }
        }
    }
}
