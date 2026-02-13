// SPDX-License-Identifier: MIT
// OpenClaw Toggle — First-run Setup Wizard.
//
// A multi-step guided setup that walks new users through:
//   1. Welcome — introduces the app
//   2. Detect  — auto-scans for existing OpenClaw LaunchAgent plists
//   3. Configure — lets user edit service labels, plist paths, gateway, port
//   4. Diagnostics — runs health checks to verify the stack
//   5. Finish — marks setup complete, optional Launch at Login

import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - Wizard Step
// ---------------------------------------------------------------------------

/// The steps of the first-run setup wizard.
enum SetupWizardStep: Int, CaseIterable {
    case welcome = 0
    case detect
    case configure
    case diagnostics
    case finish

    var title: String {
        switch self {
        case .welcome:     return "Welcome"
        case .detect:      return "Detect Services"
        case .configure:   return "Configure"
        case .diagnostics: return "Diagnostics"
        case .finish:      return "All Set!"
        }
    }

    var icon: String {
        switch self {
        case .welcome:     return "hand.wave.fill"
        case .detect:      return "magnifyingglass"
        case .configure:   return "gearshape.2.fill"
        case .diagnostics: return "stethoscope"
        case .finish:      return "checkmark.seal.fill"
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Setup Wizard View
// ---------------------------------------------------------------------------

/// The main wizard view.  Manages step navigation and passes settings down.
struct SetupWizardView: View {
    @ObservedObject var settings: AppSettings
    var onComplete: () -> Void

    @State private var currentStep: SetupWizardStep = .welcome
    @State private var detectedServices: [ServiceDetector.DetectedService] = []
    @State private var detectMessage = ""

    // Local editable copies for the configure step
    @State private var portText = ""
    @State private var gatewayText = ""

    var body: some View {
        VStack(spacing: 0) {
            // ── Progress indicator ──────────────────────────────────
            wizardProgress
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            // ── Step content ────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch currentStep {
                    case .welcome:
                        welcomeStep
                    case .detect:
                        detectStep
                    case .configure:
                        configureStep
                    case .diagnostics:
                        diagnosticsStep
                    case .finish:
                        finishStep
                    }
                }
                .padding(24)
            }

            Divider()

            // ── Navigation buttons ──────────────────────────────────
            HStack {
                if currentStep != .welcome {
                    Button("Back") {
                        withAnimation {
                            goBack()
                        }
                    }
                    .controlSize(.large)
                }

                Spacer()

                if currentStep == .finish {
                    Button("Finish Setup") {
                        completeSetup()
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") {
                        withAnimation {
                            goForward()
                        }
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 540)
        .onAppear {
            syncFromSettings()
        }
    }

    // MARK: - Progress Indicator

    private var wizardProgress: some View {
        HStack(spacing: 0) {
            ForEach(SetupWizardStep.allCases, id: \.rawValue) { step in
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(step.rawValue <= currentStep.rawValue
                                  ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(width: 28, height: 28)

                        Image(systemName: step.icon)
                            .font(.caption2)
                            .foregroundStyle(step.rawValue <= currentStep.rawValue
                                             ? .white : .secondary)
                    }
                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)

                if step != SetupWizardStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < currentStep.rawValue
                              ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 2)
                        .frame(maxWidth: 30)
                        .padding(.bottom, 16)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .center, spacing: 16) {
            Spacer().frame(height: 8)

            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Welcome to OpenClaw Toggle")
                .font(.title2.bold())

            Text("This wizard will help you set up your OpenClaw services.\nWe'll detect existing configurations, let you customize settings,\nand verify everything is working.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 2: Detect

    private var detectStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Auto-Detect Services", systemImage: "magnifyingglass")
                .font(.title3.bold())

            Text("We'll scan ~/Library/LaunchAgents/ for OpenClaw plist files and auto-configure your settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    runDetection()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Scan Now")
                    }
                }
                .controlSize(.large)

                if !detectMessage.isEmpty {
                    Text(detectMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !detectedServices.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(detectedServices) { svc in
                            HStack(spacing: 8) {
                                Image(systemName: svc.role == .tunnel ? "network" : "server.rack")
                                    .foregroundStyle(svc.role == .unknown ? Color.secondary : Color.green)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(svc.label)
                                        .font(.subheadline.monospaced())
                                    HStack(spacing: 4) {
                                        Text(svc.role.rawValue)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("·")
                                            .foregroundStyle(.tertiary)
                                        Text(svc.plistPath)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button("Apply Detected Settings") {
                    ServiceDetector.detectAndApply(to: settings)
                    syncFromSettings()
                    detectMessage = "✓ Settings applied!"
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step 3: Configure

    private var configureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Service Configuration", systemImage: "gearshape.2.fill")
                .font(.title3.bold())

            Text("Review and adjust your service settings. These can always be changed later in Preferences.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox(label: Label("SSH Tunnel", systemImage: "network")) {
                VStack(alignment: .leading, spacing: 10) {
                    configField(label: "Gateway Host:", text: $gatewayText,
                                help: "e.g. gateway.openclaw.ai or user@host")
                    configField(label: "Local Port:", text: $portText,
                                help: "Port the tunnel forwards to (default: 18789)")
                    configField(label: "Service Label:", text: $settings.tunnelServiceLabel,
                                help: "launchd label")
                    configField(label: "Plist Path:", text: $settings.tunnelPlistPath,
                                help: "Full path to LaunchAgent plist")
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Label("Node Service", systemImage: "server.rack")) {
                VStack(alignment: .leading, spacing: 10) {
                    configField(label: "Service Label:", text: $settings.nodeServiceLabel,
                                help: "launchd label")
                    configField(label: "Plist Path:", text: $settings.nodePlistPath,
                                help: "Full path to LaunchAgent plist")
                }
                .padding(.vertical, 4)
            }
        }
        .onChange(of: portText) { _, newValue in
            if let p = UInt16(newValue), p > 0 {
                settings.tunnelPort = p
            }
        }
        .onChange(of: gatewayText) { _, newValue in
            settings.gatewayHost = newValue
        }
    }

    // MARK: - Step 4: Diagnostics

    private var diagnosticsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Health Check", systemImage: "stethoscope")
                .font(.title3.bold())

            Text("Let's verify your OpenClaw services are correctly configured and running.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox {
                HealthDiagnosticsView(settings: settings)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Step 5: Finish

    private var finishStep: some View {
        VStack(alignment: .center, spacing: 16) {
            Spacer().frame(height: 8)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title2.bold())

            Text("OpenClaw Toggle is configured and ready to go.\nYou can adjust settings anytime from the menu bar icon → Preferences.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Divider()
                .padding(.horizontal, 40)

            // Launch at Login toggle
            Toggle(isOn: $settings.launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login")
                        .font(.subheadline.weight(.medium))
                    Text("Start OpenClaw Toggle automatically when you log in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Navigation

    private func goForward() {
        guard let next = SetupWizardStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    private func goBack() {
        guard let prev = SetupWizardStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    private func completeSetup() {
        settings.hasCompletedSetup = true
        onComplete()
    }

    // MARK: - Helpers

    private func syncFromSettings() {
        portText = String(settings.tunnelPort)
        gatewayText = settings.gatewayHost
    }

    private func runDetection() {
        detectedServices = ServiceDetector.detect()
        if detectedServices.isEmpty {
            detectMessage = "No OpenClaw services found."
        } else {
            detectMessage = "Found \(detectedServices.count) service(s)"
        }
    }

    @ViewBuilder
    private func configField(
        label: String,
        text: Binding<String>,
        help: String
    ) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 100, alignment: .trailing)
            TextField(help, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
        }
    }
}
