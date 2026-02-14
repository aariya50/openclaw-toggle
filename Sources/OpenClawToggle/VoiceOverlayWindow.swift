// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Floating HUD overlay that shows voice assistant state.
//
// Appears near the top-center of the screen when the user holds the
// push-to-talk key.  Shows recording indicator, transcription status, etc.

import Combine
import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - SwiftUI Overlay View
// ---------------------------------------------------------------------------

/// The small pill-shaped HUD shown during voice interactions.
struct VoiceOverlayView: View {
    @ObservedObject var assistant: VoiceAssistant

    var body: some View {
        HStack(spacing: 8) {
            indicator
                .frame(width: 16, height: 16)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    // MARK: Indicator icon

    @ViewBuilder
    private var indicator: some View {
        switch assistant.state {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .modifier(PulseModifier())

        case .transcribing:
            ProgressView()
                .controlSize(.small)

        case .interpreting:
            Image(systemName: "brain")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

        case .executing:
            Image(systemName: "bolt.fill")
                .font(.system(size: 12))
                .foregroundStyle(.yellow)

        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)

        case .conversing:
            Image(systemName: "ear")
                .font(.system(size: 12))
                .foregroundStyle(.blue)

        default:
            EmptyView()
        }
    }

    // MARK: Label text

    private var label: String {
        switch assistant.state {
        case .recording:     return "Listening…"
        case .transcribing:  return "Transcribing…"
        case .interpreting:  return "Thinking…"
        case .executing:     return "Running…"
        case .speaking:      return assistant.lastResponse.prefix(40) + (assistant.lastResponse.count > 40 ? "…" : "")
        case .conversing:    return "Listening…"
        default:             return ""
        }
    }
}

/// Simple pulsing animation for the recording dot.
private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Overlay Window Controller
// ---------------------------------------------------------------------------

/// Manages the floating overlay NSWindow.  Shows/hides automatically based
/// on the VoiceAssistant state.
@MainActor
final class VoiceOverlayController {

    private var window: NSWindow?
    private var cancellable: AnyCancellable?

    /// States that should show the overlay.
    private static let visibleStates: Set<VoiceAssistant.State.RawValue> = [
        "recording", "transcribing", "interpreting", "executing", "speaking", "conversing",
    ]

    func start(assistant: VoiceAssistant) {
        cancellable = assistant.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if Self.visibleStates.contains(state.rawValue) {
                    self.show(assistant: assistant)
                } else {
                    self.hide()
                }
            }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        hide()
    }

    // MARK: Show / Hide

    private func show(assistant: VoiceAssistant) {
        if window == nil {
            let overlayView = VoiceOverlayView(assistant: assistant)
            let hostingView = NSHostingView(rootView: overlayView)
            hostingView.setFrameSize(hostingView.fittingSize)

            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.contentView = hostingView
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .floating
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]

            window = w
        }

        // Position: top center of the main screen, just below the menu bar.
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let size = window!.contentView?.fittingSize ?? CGSize(width: 200, height: 36)
            window!.setContentSize(size)
            let x = screenFrame.midX - size.width / 2
            let y = screenFrame.maxY - 8
            window!.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window?.orderFrontRegardless()
    }

    private func hide() {
        window?.orderOut(nil)
    }
}
