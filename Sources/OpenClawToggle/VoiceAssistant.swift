// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Voice assistant orchestrator (state machine).
//
// Simplified pipeline: Push-to-Talk → WhisperClient → OpenClaw Agent → TTS
// Uses hold-to-record (Shift + Delete) to capture audio, sends transcribed
// text directly to the OpenClaw agent via gateway, speaks the response.

import AppKit
import AVFoundation
import Foundation
import os

private let voiceLog = Logger(subsystem: "ai.openclaw.toggle", category: "voice")

/// Central voice assistant coordinator. Manages the full pipeline from
/// push-to-talk activation through agent response and TTS.
///
/// **Push-to-talk**: Hold Shift + Delete to record. Release to send.
/// No always-on microphone — the mic is only active while the key is held.
@MainActor
final class VoiceAssistant: ObservableObject {

    enum State: String {
        case disabled       // voice feature is off
        case idle           // ready for push-to-talk (mic OFF)
        case recording      // holding key, capturing command
        case transcribing   // sending audio to Whisper
        case executing      // sending text to OpenClaw agent
        case speaking       // TTS playing response
        case error          // something went wrong
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastResponse: String = ""
    @Published private(set) var errorMessage: String?

    /// Audio engine — owned here, started only when needed.
    let audioEngine = AVAudioEngine()

    private let whisperClient = WhisperClient()
    private let gatewayClient = OpenClawBotClient()
    private let executor: CommandExecutor
    private let settings: AppSettings

    /// Whether mic permissions have been granted.
    private var permissionsGranted = false

    init(monitor: StatusMonitor, settings: AppSettings) {
        self.settings = settings
        self.executor = CommandExecutor(settings: settings)
    }

    // MARK: - Lifecycle

    func start() async {
        voiceLog.info("start() called — voiceEnabled=\(self.settings.voiceEnabled)")
        guard settings.voiceEnabled else {
            state = .disabled
            voiceLog.info("Disabled, returning")
            return
        }

        guard !settings.openAIAPIKey.isEmpty else {
            state = .error
            errorMessage = "No OpenAI API key. Add one in Preferences."
            voiceLog.info("No API key, returning")
            return
        }

        // Request permissions but do NOT start the audio engine.
        // The engine starts on-demand when the user holds the hotkey.
        voiceLog.info("Requesting mic permission...")
        permissionsGranted = await requestMicPermission()
        voiceLog.info("Mic permission granted: \(self.permissionsGranted)")

        guard permissionsGranted else {
            state = .error
            errorMessage = "Microphone permission denied."
            return
        }

        state = .idle
        errorMessage = nil
        voiceLog.info("Voice ready (push-to-talk) — state=idle, mic OFF")
    }

    func stop() {
        stopAudioEngine()
        executor.stopPlayback()
        state = .disabled
        errorMessage = nil
    }

    /// Restart the voice assistant (e.g. after settings change).
    func restart() async {
        stop()
        try? await Task.sleep(for: .milliseconds(300))
        await start()
    }

    // MARK: - Push-to-Talk (Hold to Record)

    /// Called when the push-to-talk key is pressed DOWN.
    /// Starts recording immediately.
    func startRecording() {
        voiceLog.info("Key DOWN — state: \(self.state.rawValue, privacy: .public)")

        switch state {
        case .disabled:
            Task { await start() }
            return

        case .idle:
            NSSound.beep()
            gatewayClient.newSession()
            gatewayClient.resetAvailability()
            voiceLog.info("Hold-to-record: starting...")
            Task { await beginRecording() }

        case .speaking, .executing:
            voiceLog.info("Key pressed while speaking — cancelling")
            cancelAll()

        case .recording:
            break

        case .transcribing:
            break

        case .error:
            cancelAll()
        }
    }

    /// Called when the push-to-talk key is released UP.
    /// Signals WhisperClient to finish recording.
    func stopRecordingKey() {
        voiceLog.info("Key UP — state: \(self.state.rawValue, privacy: .public)")
        guard state == .recording else { return }
        whisperClient.stopRecording()
    }

    /// Cancel all active operations and return to idle (mic OFF).
    func cancelAll() {
        executor.stopPlayback()
        whisperClient.stopRecording()
        stopAudioEngine()
        state = .idle
        errorMessage = nil
        voiceLog.info("All cancelled — idle (mic OFF)")
    }

    // MARK: - Audio Engine (on-demand)

    /// Start the audio engine if not already running.
    private func ensureAudioEngineRunning() throws {
        guard !audioEngine.isRunning else { return }

        let inputNode = audioEngine.inputNode
        // Disable voice processing to prevent Voice Isolation DSP.
        if inputNode.isVoiceProcessingEnabled {
            try? inputNode.setVoiceProcessingEnabled(false)
        }

        audioEngine.prepare()
        try audioEngine.start()
        voiceLog.info("Audio engine started")
    }

    /// Stop the audio engine and clean up.
    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            voiceLog.info("Audio engine stopped")
        }
    }

    // MARK: - Permissions

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Pipeline

    /// Record → Transcribe → Send to agent → Speak response.
    private func beginRecording() async {
        state = .recording
        lastTranscript = ""
        lastResponse = ""

        do {
            try ensureAudioEngineRunning()
        } catch {
            voiceLog.error("Audio engine error: \(error.localizedDescription, privacy: .public)")
            state = .error
            errorMessage = "Audio error: \(error.localizedDescription)"
            return
        }

        voiceLog.info("Recording...")

        do {
            // 1. Record — stops on key release, silence, or max duration.
            let audioData = try await whisperClient.recordCommand(
                audioEngine: audioEngine,
                maxDuration: 30.0,
                silenceTimeout: 2.0
            )

            // Stop the audio engine — mic OFF immediately after recording.
            stopAudioEngine()

            voiceLog.info("Recorded \(audioData.count, privacy: .public) bytes")

            // Minimum audio size check.
            guard audioData.count > 3300 else {
                voiceLog.info("Recording too short (\(audioData.count, privacy: .public) bytes)")
                lastResponse = "I didn't catch that."
                state = .speaking
                await executor.speakAsync(lastResponse)
                state = .idle
                return
            }

            let apiKey = settings.openAIAPIKey
            guard !apiKey.isEmpty else { throw VoiceError.noAPIKey }

            // 2. Transcribe with Whisper.
            state = .transcribing
            voiceLog.info("Transcribing...")
            let transcription = try await whisperClient.transcribe(audioData: audioData, apiKey: apiKey)
            lastTranscript = transcription.text
            voiceLog.info("Whisper: '\(transcription.text, privacy: .public)'")

            guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                voiceLog.info("Empty transcription")
                lastResponse = "I didn't catch that."
                state = .speaking
                await executor.speakAsync(lastResponse)
                state = .idle
                return
            }

            // 3. Send to OpenClaw agent.
            state = .executing
            voiceLog.info("Sending to agent...")
            guard let response = await gatewayClient.sendMessage(transcription.text) else {
                lastResponse = "Couldn't reach the agent."
                state = .speaking
                await executor.speakAsync(lastResponse)
                state = .idle
                return
            }
            lastResponse = response
            voiceLog.info("Agent response: '\(response.prefix(200), privacy: .public)'")

            // 4. Speak response.
            state = .speaking
            await executor.speakAsync(response)
            state = .idle

        } catch {
            state = .error
            errorMessage = error.localizedDescription
            lastResponse = "Sorry, something went wrong."
            voiceLog.error("Pipeline error: \(error.localizedDescription, privacy: .public)")
            stopAudioEngine()
            await executor.speakAsync(lastResponse)
            state = .idle
        }
    }

    // MARK: - Text Chat (for ChatWindowView)

    /// Whether the assistant is currently processing (for UI state).
    var isProcessing: Bool {
        switch state {
        case .transcribing, .executing, .speaking:
            return true
        default:
            return false
        }
    }

    /// Process a text message directly (bypasses voice recording/transcription).
    /// Used by the chat window interface.
    func processTextMessage(_ text: String) async -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        lastTranscript = trimmedText
        voiceLog.info("Text message: '\(trimmedText, privacy: .public)'")

        // Send to OpenClaw agent.
        state = .executing
        guard let response = await gatewayClient.sendMessage(trimmedText) else {
            state = .idle
            return "Couldn't reach the agent."
        }
        lastResponse = response
        voiceLog.info("Agent response: '\(response.prefix(200), privacy: .public)'")

        state = .idle
        return response
    }

    // MARK: - Errors

    enum VoiceError: LocalizedError {
        case noAPIKey
        var errorDescription: String? { "No OpenAI API key configured." }
    }
}
