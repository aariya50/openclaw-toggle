// SPDX-License-Identifier: MIT
// OpenClaw Toggle — persistent user settings backed by UserDefaults.

import Foundation

/// Central store for all user-configurable settings.
///
/// Every property is backed by `UserDefaults.standard` so values survive
/// across launches.  `StatusMonitor` and the Preferences UI both read/write
/// through the same `AppSettings.shared` instance.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - Keys

    private enum Key: String {
        case tunnelPort          = "tunnelPort"
        case nodeServiceLabel    = "nodeServiceLabel"
        case tunnelServiceLabel  = "tunnelServiceLabel"
        case nodePlistPath       = "nodePlistPath"
        case tunnelPlistPath     = "tunnelPlistPath"
        case pollInterval        = "pollInterval"
        case hasCompletedSetup   = "hasCompletedSetup"
    }

    // MARK: - Defaults

    private static let defaultTunnelPort: UInt16        = 18789
    private static let defaultNodeLabel: String         = "ai.openclaw.node"
    private static let defaultTunnelLabel: String       = "ai.openclaw.ssh-tunnel"
    private static let defaultPollInterval: TimeInterval = 3

    private static var defaultNodePlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(defaultNodeLabel).plist"
    }
    private static var defaultTunnelPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(defaultTunnelLabel).plist"
    }

    // MARK: - Published properties

    /// The local port the SSH tunnel forwards to.
    @Published var tunnelPort: UInt16 {
        didSet { save(.tunnelPort, value: Int(tunnelPort)) }
    }

    /// Launchd label for the OpenClaw node service.
    @Published var nodeServiceLabel: String {
        didSet { save(.nodeServiceLabel, value: nodeServiceLabel) }
    }

    /// Launchd label for the SSH tunnel service.
    @Published var tunnelServiceLabel: String {
        didSet { save(.tunnelServiceLabel, value: tunnelServiceLabel) }
    }

    /// Absolute path to the node LaunchAgent plist.
    @Published var nodePlistPath: String {
        didSet { save(.nodePlistPath, value: nodePlistPath) }
    }

    /// Absolute path to the tunnel LaunchAgent plist.
    @Published var tunnelPlistPath: String {
        didSet { save(.tunnelPlistPath, value: tunnelPlistPath) }
    }

    /// Status polling interval in seconds.
    @Published var pollInterval: TimeInterval {
        didSet { save(.pollInterval, value: pollInterval) }
    }

    /// Whether the user has gone through initial setup / auto-detect.
    @Published var hasCompletedSetup: Bool {
        didSet { save(.hasCompletedSetup, value: hasCompletedSetup) }
    }

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard

        let port = d.integer(forKey: Key.tunnelPort.rawValue)
        self.tunnelPort = port > 0 ? UInt16(port) : Self.defaultTunnelPort

        self.nodeServiceLabel = d.string(forKey: Key.nodeServiceLabel.rawValue)
            ?? Self.defaultNodeLabel

        self.tunnelServiceLabel = d.string(forKey: Key.tunnelServiceLabel.rawValue)
            ?? Self.defaultTunnelLabel

        self.nodePlistPath = d.string(forKey: Key.nodePlistPath.rawValue)
            ?? Self.defaultNodePlistPath

        self.tunnelPlistPath = d.string(forKey: Key.tunnelPlistPath.rawValue)
            ?? Self.defaultTunnelPlistPath

        let poll = d.double(forKey: Key.pollInterval.rawValue)
        self.pollInterval = poll > 0 ? poll : Self.defaultPollInterval

        self.hasCompletedSetup = d.bool(forKey: Key.hasCompletedSetup.rawValue)
    }

    // MARK: - Reset

    /// Restore all settings to their default values.
    func resetToDefaults() {
        tunnelPort          = Self.defaultTunnelPort
        nodeServiceLabel    = Self.defaultNodeLabel
        tunnelServiceLabel  = Self.defaultTunnelLabel
        nodePlistPath       = Self.defaultNodePlistPath
        tunnelPlistPath     = Self.defaultTunnelPlistPath
        pollInterval        = Self.defaultPollInterval
    }

    // MARK: - Private

    private func save(_ key: Key, value: Any) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
