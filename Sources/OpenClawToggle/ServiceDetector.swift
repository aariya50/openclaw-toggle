// SPDX-License-Identifier: MIT
// OpenClaw Toggle — auto-detect existing OpenClaw launchd services.

import Foundation

/// Scans `~/Library/LaunchAgents` for plist files whose label contains
/// "openclaw", and returns what it finds so the Preferences panel (or
/// first-run setup) can auto-populate service labels and paths.
@MainActor
struct ServiceDetector {

    /// A single detected launchd service.
    struct DetectedService: Identifiable {
        let id = UUID()
        /// The `Label` value from inside the plist.
        let label: String
        /// Absolute path to the `.plist` file.
        let plistPath: String
        /// Best guess at the role: `.tunnel` or `.node`.
        let role: Role

        enum Role: String, CustomStringConvertible {
            case tunnel = "SSH Tunnel"
            case node   = "Node Service"
            case unknown = "Unknown"

            var description: String { rawValue }
        }
    }

    // MARK: - Public API

    /// Scan the user's LaunchAgents directory for OpenClaw-related plists.
    static func detect() -> [DetectedService] {
        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: launchAgentsDir) else {
            return []
        }

        var results: [DetectedService] = []

        for filename in contents where filename.hasSuffix(".plist") {
            let fullPath = launchAgentsDir + "/" + filename

            // Quick filename pre-filter: must mention "openclaw" (case-insensitive).
            guard filename.lowercased().contains("openclaw") else { continue }

            // Parse the plist to extract the Label key.
            guard let label = extractLabel(from: fullPath) else { continue }

            let role = classifyRole(label: label, filename: filename)
            results.append(DetectedService(
                label: label,
                plistPath: fullPath,
                role: role
            ))
        }

        return results.sorted { $0.role.rawValue < $1.role.rawValue }
    }

    /// Convenience: run detection and auto-apply results to `AppSettings`.
    /// Returns the number of services found.
    @discardableResult
    static func detectAndApply(to settings: AppSettings) -> Int {
        let services = detect()

        for svc in services {
            switch svc.role {
            case .node:
                settings.nodeServiceLabel = svc.label
                settings.nodePlistPath    = svc.plistPath
            case .tunnel:
                settings.tunnelServiceLabel = svc.label
                settings.tunnelPlistPath    = svc.plistPath
            case .unknown:
                // Don't auto-assign unknown services.
                break
            }
        }

        if !services.isEmpty {
            settings.hasCompletedSetup = true
        }

        return services.count
    }

    // MARK: - Private helpers

    /// Read the `Label` string from a launchd plist file.
    private static func extractLabel(from path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return nil
        }
        return plist["Label"] as? String
    }

    /// Heuristic: classify a service as tunnel or node based on its label
    /// and filename.
    private static func classifyRole(label: String, filename: String) -> DetectedService.Role {
        let combined = (label + " " + filename).lowercased()

        if combined.contains("tunnel") || combined.contains("ssh") {
            return .tunnel
        }
        if combined.contains("node") {
            return .node
        }
        return .unknown
    }
}
