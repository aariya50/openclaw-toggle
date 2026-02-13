// SPDX-License-Identifier: MIT
// OpenClaw Toggle — About window view.

import SwiftUI

/// A simple About window with app name, version, and links.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            // App icon area
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .padding(.top, 8)

            // App name
            Text("OpenClaw Toggle")
                .font(.title2.bold())

            // Version
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Description
            Text("A lightweight macOS menu bar app for\nmonitoring and controlling OpenClaw services.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Divider()
                .padding(.horizontal, 40)

            // Links
            VStack(spacing: 6) {
                Link("GitHub Repository",
                     destination: URL(string: "https://github.com/AriGlockworx/OpenClawToggle")!)
                    .font(.caption)
                Link("OpenClaw Website",
                     destination: URL(string: "https://openclaw.ai")!)
                    .font(.caption)
            }

            // Copyright
            Text("© 2026 OpenClaw Contributors")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(width: 320, height: 340)
    }
}

/// Static app metadata read from the Info.plist or compile-time defaults.
enum AppInfo {
    static let version: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()

    static let build: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }()

    static let bundleIdentifier: String = {
        Bundle.main.bundleIdentifier ?? "ai.openclaw.toggle"
    }()
}
