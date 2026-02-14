// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Sparkle auto-update integration.
//
// Wraps the Sparkle framework's SPUStandardUpdaterController in a
// SwiftUI-friendly observable object so we can expose "Check for Updates"
// in the UI.

import Foundation
import Sparkle
import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - Updater Manager
// ---------------------------------------------------------------------------

/// Manages the Sparkle updater lifecycle.  Created once and kept alive
/// for the duration of the app.
///
/// Usage:
///   let updater = SparkleUpdaterManager()
///   // In a SwiftUI view:
///   Button("Check for Updates…") { updater.checkForUpdates() }
///       .disabled(!updater.canCheckForUpdates)
@MainActor
final class SparkleUpdaterManager: ObservableObject {

    /// The underlying Sparkle updater controller.
    private let controller: SPUStandardUpdaterController

    /// Whether the "Check for Updates" action is currently available.
    @Published var canCheckForUpdates = false

    init() {
        // Create the controller with no delegate — uses defaults
        // from Info.plist (SUFeedURL, etc.).
        // Don't start the updater automatically — the EdDSA public key
        // is not yet configured, so Sparkle would log a fatal error.
        // Update checks are handled via the GitHub Releases API instead.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Observe the updater's `canCheckForUpdates` property via KVO
        // and bridge it to our @Published property.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Trigger a user-initiated update check.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Check for Updates Button
// ---------------------------------------------------------------------------

/// A reusable SwiftUI button that triggers a Sparkle update check.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: SparkleUpdaterManager

    var body: some View {
        Button {
            updater.checkForUpdates()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Check for Updates…")
            }
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
