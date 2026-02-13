// SPDX-License-Identifier: MIT
// OpenClaw Toggle — manages the full lifecycle of launchd services.
//
// Responsibilities:
//   • App launch  → bootstrap tunnel + node services, write PID file,
//                    install a watchdog LaunchAgent.
//   • App quit    → bootout services, remove PID file, unload watchdog.
//   • App crash   → the watchdog (a lightweight launchd job) notices the PID
//                    is gone and bootouts the services on its behalf.

import Foundation

// ---------------------------------------------------------------------------
// MARK: - ServiceLifecycleManager
// ---------------------------------------------------------------------------

/// Encapsulates all service start / stop / watchdog logic so the AppDelegate
/// can simply call `start()` and `teardown()`.
@MainActor
final class ServiceLifecycleManager {

    private let settings: AppSettings

    // -- Derived paths -------------------------------------------------------

    /// Directory for runtime files (PID, watchdog plist & script).
    private var runtimeDir: String {
        NSHomeDirectory() + "/Library/Application Support/OpenClawToggle"
    }

    private var pidFilePath: String { runtimeDir + "/app.pid" }
    private var watchdogScriptPath: String { runtimeDir + "/watchdog.sh" }

    private var watchdogPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/ai.openclaw.toggle-watchdog.plist"
    }

    private let watchdogLabel = "ai.openclaw.toggle-watchdog"

    private let uid: String = String(getuid())

    // MARK: Init

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Called from `applicationDidFinishLaunching`.
    /// Bootstraps both services and installs the crash watchdog.
    func start() {
        ensureRuntimeDir()
        writePIDFile()
        installWatchdog()
        bootstrapServices()
    }

    /// Called from `applicationShouldTerminate` (before the app exits).
    /// Bootouts services, removes PID file, and unloads the watchdog.
    /// Runs asynchronously; call the `completion` closure when done.
    func teardown(completion: @escaping () -> Void) {
        let tunnelLabel = settings.tunnelServiceLabel
        let nodeLabel   = settings.nodeServiceLabel
        let uid         = self.uid
        let pidPath     = self.pidFilePath
        let wdLabel     = self.watchdogLabel
        let wdPlistPath = self.watchdogPlistPath
        let wdScriptPath = self.watchdogScriptPath

        Task.detached(priority: .userInitiated) {
            // 1. Bootout the two app services.
            for label in [nodeLabel, tunnelLabel] {
                Self.runProcess("/bin/launchctl", args: [
                    "bootout", "gui/\(uid)/\(label)"
                ])
            }

            // 2. Unload the watchdog.
            Self.runProcess("/bin/launchctl", args: [
                "bootout", "gui/\(uid)/\(wdLabel)"
            ])

            // 3. Clean up files.
            try? FileManager.default.removeItem(atPath: pidPath)
            try? FileManager.default.removeItem(atPath: wdPlistPath)
            try? FileManager.default.removeItem(atPath: wdScriptPath)

            await MainActor.run { completion() }
        }
    }

    // MARK: - Bootstrap services

    private func bootstrapServices() {
        let tunnelPlist = settings.tunnelPlistPath
        let nodePlist   = settings.nodePlistPath
        let uid         = self.uid

        Task.detached(priority: .userInitiated) {
            // Bootstrap the tunnel first.
            Self.runProcess("/bin/launchctl", args: [
                "bootstrap", "gui/\(uid)", tunnelPlist
            ])

            // Give the tunnel a moment to establish before starting the node.
            try? await Task.sleep(for: .seconds(2))

            Self.runProcess("/bin/launchctl", args: [
                "bootstrap", "gui/\(uid)", nodePlist
            ])
        }
    }

    // MARK: - PID file

    private func writePIDFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        try? String(pid).write(
            toFile: pidFilePath,
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Watchdog

    /// Installs a lightweight launchd plist + shell script that polls every
    /// 10 seconds. If the app PID is no longer alive, the script bootouts
    /// the tunnel and node services, removes the PID file, and unloads itself.
    private func installWatchdog() {
        writeWatchdogScript()
        writeWatchdogPlist()

        // Unload any stale instance first (ignore errors).
        let uid = self.uid
        Task.detached(priority: .utility) {
            Self.runProcess("/bin/launchctl", args: [
                "bootout", "gui/\(uid)/ai.openclaw.toggle-watchdog"
            ])
            // Small delay so launchd finishes the unload.
            try? await Task.sleep(for: .milliseconds(500))
            Self.runProcess("/bin/launchctl", args: [
                "bootstrap", "gui/\(uid)",
                NSHomeDirectory() + "/Library/LaunchAgents/ai.openclaw.toggle-watchdog.plist"
            ])
        }
    }

    private func writeWatchdogScript() {
        let tunnelLabel = settings.tunnelServiceLabel
        let nodeLabel   = settings.nodeServiceLabel
        let uid         = self.uid

        let script = """
        #!/bin/bash
        # OpenClaw Toggle watchdog — stops services if the app is no longer running.
        PID_FILE="\(pidFilePath)"
        
        if [ ! -f "$PID_FILE" ]; then
            exit 0
        fi
        
        APP_PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -z "$APP_PID" ]; then
            exit 0
        fi
        
        # Check if the app process is still alive.
        if kill -0 "$APP_PID" 2>/dev/null; then
            # App is alive — nothing to do.
            exit 0
        fi
        
        # App is dead — stop the services.
        /bin/launchctl bootout "gui/\(uid)/\(nodeLabel)" 2>/dev/null
        /bin/launchctl bootout "gui/\(uid)/\(tunnelLabel)" 2>/dev/null
        
        # Clean up.
        rm -f "$PID_FILE"
        
        # Unload ourselves.
        /bin/launchctl bootout "gui/\(uid)/\(watchdogLabel)" 2>/dev/null
        """

        try? script.write(
            toFile: watchdogScriptPath,
            atomically: true,
            encoding: .utf8
        )

        // Make executable.
        chmod(watchdogScriptPath, 0o755)
    }

    private func writeWatchdogPlist() {
        let plist: [String: Any] = [
            "Label": watchdogLabel,
            "ProgramArguments": ["/bin/bash", watchdogScriptPath],
            "StartInterval": 10,   // every 10 seconds
            "RunAtLoad": true,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]

        let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try? data?.write(to: URL(fileURLWithPath: watchdogPlistPath))
    }

    // MARK: - Helpers

    private func ensureRuntimeDir() {
        try? FileManager.default.createDirectory(
            atPath: runtimeDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// chmod wrapper using POSIX API.
    private func chmod(_ path: String, _ mode: mode_t) {
        Darwin.chmod(path, mode)
    }

    /// Fire-and-forget process execution.
    private nonisolated static func runProcess(_ path: String, args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
