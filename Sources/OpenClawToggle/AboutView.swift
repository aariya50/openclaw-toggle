// SPDX-License-Identifier: MIT
// OpenClaw Toggle — About window view.

import SwiftUI

/// A macOS-native About window with the real app icon, version info, and links.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 24)

            // App icon — use the actual bundled icon
            appIconImage
                .frame(width: 96, height: 96)

            Spacer()
                .frame(height: 16)

            // App name
            Text("OpenClaw Toggle")
                .font(.system(size: 20, weight: .bold))

            Spacer()
                .frame(height: 4)

            // Version
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()
                .frame(height: 16)

            // Description
            Text("A lightweight macOS menu bar app for\nmonitoring and controlling OpenClaw services.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Spacer()
                .frame(height: 20)

            Divider()
                .padding(.horizontal, 48)

            Spacer()
                .frame(height: 16)

            // Links
            VStack(spacing: 8) {
                Link(destination: URL(string: "https://github.com/aariya50/OpenClawToggle")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                        Text("GitHub Repository")
                            .font(.callout)
                    }
                }

                Link(destination: URL(string: "https://openclaw.ai")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.caption)
                        Text("OpenClaw Website")
                            .font(.callout)
                    }
                }
            }

            Spacer()
                .frame(height: 20)

            // Copyright
            Text("© 2026 OpenClaw Contributors. MIT License.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()
                .frame(height: 16)
        }
        .frame(width: 340, height: 380)
    }

    // MARK: - App Icon

    /// Attempts to load the real app icon from the bundle.
    /// Falls back to NSApp's applicationIconImage, then to an SF Symbol.
    @ViewBuilder
    private var appIconImage: some View {
        if let iconImage = loadBundleIcon() {
            Image(nsImage: iconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }

    /// Loads the app icon from the bundle's Resources directory.
    private func loadBundleIcon() -> NSImage? {
        // Try the .icns file first
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: icnsURL) {
            return img
        }
        // Fall back to alfred-icon.png
        if let pngURL = Bundle.main.url(forResource: "alfred-icon", withExtension: "png"),
           let img = NSImage(contentsOf: pngURL) {
            return img
        }
        return nil
    }
}

/// Static app metadata read from the Info.plist or compile-time defaults.
enum AppInfo {
    static let version: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.0"
    }()

    static let build: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }()

    static let bundleIdentifier: String = {
        Bundle.main.bundleIdentifier ?? "ai.openclaw.toggle"
    }()
}
