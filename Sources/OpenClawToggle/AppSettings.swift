// SPDX-License-Identifier: MIT
// OpenClaw Toggle — persistent user settings backed by UserDefaults.

import Foundation
import ServiceManagement

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
        case gatewayHost         = "gatewayHost"
        case launchAtLogin       = "launchAtLogin"
        case menuBarIconName     = "menuBarIconName"
        case voiceEnabled        = "voiceEnabled"
        case wakeWord            = "wakeWord"
        case openAIModel         = "openAIModel"
        case openAIAPIKey        = "openAIAPIKey"
    }

    // MARK: - Defaults

    private static let defaultTunnelPort: UInt16        = 18789
    private static let defaultNodeLabel: String         = "ai.openclaw.node"
    private static let defaultTunnelLabel: String       = "ai.openclaw.ssh-tunnel"
    private static let defaultPollInterval: TimeInterval = 3
    private static let defaultGatewayHost: String       = ""
    static let defaultMenuBarIconName: String            = "circle.hexagongrid.fill"
    private static let defaultVoiceEnabled: Bool          = false
    private static let defaultWakeWord: String            = "hey alfred"
    private static let defaultOpenAIModel: String         = "gpt-4o-mini"
    private static let defaultOpenAIAPIKey: String        = ""

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

    /// SSH gateway host (e.g. "gateway.openclaw.ai" or user@host).
    @Published var gatewayHost: String {
        didSet { save(.gatewayHost, value: gatewayHost) }
    }

    /// Whether the app should launch at login.
    @Published var launchAtLogin: Bool {
        didSet {
            save(.launchAtLogin, value: launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    /// SF Symbol name used for the menu bar icon overlay.
    @Published var menuBarIconName: String {
        didSet { save(.menuBarIconName, value: menuBarIconName) }
    }

    /// Whether voice assistant is enabled.
    @Published var voiceEnabled: Bool {
        didSet { save(.voiceEnabled, value: voiceEnabled) }
    }

    /// Wake word phrase for always-listening mode.
    @Published var wakeWord: String {
        didSet { save(.wakeWord, value: wakeWord) }
    }

    /// OpenAI model for command interpretation.
    @Published var openAIModel: String {
        didSet { save(.openAIModel, value: openAIModel) }
    }

    /// OpenAI API key.
    @Published var openAIAPIKey: String {
        didSet { save(.openAIAPIKey, value: openAIAPIKey) }
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

        self.gatewayHost = d.string(forKey: Key.gatewayHost.rawValue)
            ?? Self.defaultGatewayHost

        self.launchAtLogin = d.bool(forKey: Key.launchAtLogin.rawValue)

        self.menuBarIconName = d.string(forKey: Key.menuBarIconName.rawValue)
            ?? Self.defaultMenuBarIconName

        self.voiceEnabled = d.bool(forKey: Key.voiceEnabled.rawValue)

        self.wakeWord = d.string(forKey: Key.wakeWord.rawValue)
            ?? Self.defaultWakeWord

        self.openAIModel = d.string(forKey: Key.openAIModel.rawValue)
            ?? Self.defaultOpenAIModel

        self.openAIAPIKey = d.string(forKey: Key.openAIAPIKey.rawValue)
            ?? Self.defaultOpenAIAPIKey
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
        gatewayHost         = Self.defaultGatewayHost
        menuBarIconName     = Self.defaultMenuBarIconName
    }

    // MARK: - Launch at Login

    /// Applies the current `launchAtLogin` preference using SMAppService.
    /// Available on macOS 13+ (Ventura). Since we target macOS 14+ this is safe.
    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // If registration fails (e.g. sandboxing issues), log and revert.
            print("[OpenClawToggle] Launch at Login error: \(error.localizedDescription)")
        }
    }

    /// Reads the actual system state of launch-at-login for this app.
    var isRegisteredForLaunchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Private

    private func save(_ key: Key, value: Any) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
