// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Voice assistant orchestrator (state machine).
//
// Pipeline: Push-to-Talk → WhisperClient → CommandInterpreter → CommandExecutor
// Uses hold-to-record (Shift + Delete) to capture audio.
// Supports conversation mode: after activation, stays active for follow-up
// commands without requiring the hotkey again.

import AppKit
import AVFoundation
import Foundation
import os

private let voiceLog = Logger(subsystem: "ai.openclaw.toggle", category: "voice")

/// Central voice assistant coordinator. Manages the full pipeline from
/// push-to-talk activation through command execution and TTS response.
///
/// **Push-to-talk**: Hold Shift + Delete to record. Release to send.
/// No always-on microphone — the mic is only active while the key is held.
///
/// **Conversation mode**: After the first command, the assistant stays
/// in a conversational state where it keeps listening for follow-up commands
/// without requiring the hotkey again. After `conversationTimeout` seconds of
/// inactivity, it returns to idle.
@MainActor
final class VoiceAssistant: ObservableObject {

    enum State: String {
        case disabled       // voice feature is off
        case idle           // ready for push-to-talk (mic OFF)
        case recording      // holding key, capturing command
        case transcribing   // sending audio to Whisper
        case interpreting   // sending text to GPT
        case executing      // running the command
        case speaking       // TTS playing response
        case conversing     // waiting for follow-up (conversation mode)
        case error          // something went wrong
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastResponse: String = ""
    @Published private(set) var errorMessage: String?

    /// Audio engine — owned here, started only when needed.
    let audioEngine = AVAudioEngine()

    private let whisperClient = WhisperClient()
    private let interpreter = CommandInterpreter()
    private let executor: CommandExecutor
    private let monitor: StatusMonitor
    private let settings: AppSettings

    /// Whether mic permissions have been granted.
    private var permissionsGranted = false

    /// How long to wait for a follow-up command before returning to idle (mic OFF).
    private let conversationTimeout: TimeInterval = 12.0

    /// Timer that fires when conversation mode times out.
    private var conversationTimer: Task<Void, Never>?

    /// Tracks conversation history for multi-turn context.
    private var conversationHistory: [(role: String, content: String)] = []

    /// Maximum conversation turns before auto-resetting.
    private static let maxConversationTurns = 10

    init(monitor: StatusMonitor, settings: AppSettings) {
        self.monitor = monitor
        self.settings = settings
        self.executor = CommandExecutor(monitor: monitor, settings: settings)
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
        voiceLog.info("✅ Voice ready (push-to-talk) — state=idle, mic OFF")
    }

    func stop() {
        stopAudioEngine()
        conversationTimer?.cancel()
        conversationTimer = nil
        conversationHistory.removeAll()
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
        voiceLog.info("🎤 Key DOWN — state: \(self.state.rawValue, privacy: .public)")

        switch state {
        case .disabled:
            Task { await start() }
            return

        case .idle:
            // Start recording.
            NSSound.beep()
            conversationHistory.removeAll()
            interpreter.botClient.newSession()
            interpreter.botClient.resetAvailability()
            voiceLog.info("🎤 Hold-to-record: starting...")
            Task { await beginRecording() }

        case .speaking, .executing:
            // Cancel TTS/execution — go back to idle.
            voiceLog.info("⏹️ Key pressed while speaking — cancelling")
            cancelAll()

        case .recording:
            // Already recording — ignore.
            break

        case .transcribing, .interpreting:
            // Pipeline in progress — ignore.
            break

        case .conversing:
            // In conversation mode — start a new recording (follow-up via hotkey).
            voiceLog.info("🎤 Key DOWN in conversation — recording follow-up...")
            conversationTimer?.cancel()
            conversationTimer = nil
            Task { await beginRecording() }

        case .error:
            cancelAll()
        }
    }

    /// Called when the push-to-talk key is released UP.
    /// Signals WhisperClient to finish recording.
    func stopRecordingKey() {
        voiceLog.info("🎤 Key UP — state: \(self.state.rawValue, privacy: .public)")
        guard state == .recording else { return }
        whisperClient.stopRecording()
    }

    /// Cancel all active operations and return to idle (mic OFF).
    func cancelAll() {
        executor.stopPlayback()
        whisperClient.stopRecording()
        conversationTimer?.cancel()
        conversationTimer = nil
        conversationHistory.removeAll()
        stopAudioEngine()
        state = .idle
        errorMessage = nil
        voiceLog.info("⏹️ All cancelled — idle (mic OFF)")
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
        voiceLog.info("🔊 Audio engine started")
    }

    /// Stop the audio engine and clean up.
    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            voiceLog.info("🔇 Audio engine stopped")
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

    /// Start recording audio (engine started on-demand).
    private func beginRecording() async {
        state = .recording
        lastTranscript = ""
        lastResponse = ""

        do {
            try ensureAudioEngineRunning()
        } catch {
            voiceLog.error("❌ Audio engine error: \(error.localizedDescription, privacy: .public)")
            state = .error
            errorMessage = "Audio error: \(error.localizedDescription)"
            return
        }

        voiceLog.info("🎤 Recording...")

        do {
            // 1. Record — stops on key release, silence, or max duration.
            let audioData = try await whisperClient.recordCommand(
                audioEngine: audioEngine,
                maxDuration: 30.0,
                silenceTimeout: 2.0
            )

            // Stop the audio engine — mic OFF immediately after recording.
            stopAudioEngine()

            voiceLog.info("📝 Recorded \(audioData.count, privacy: .public) bytes")

            // Minimum audio size check.
            guard audioData.count > 3300 else {
                voiceLog.info("⚠️ Recording too short (\(audioData.count, privacy: .public) bytes)")
                lastResponse = "I didn't catch that."
                await executor.speakAsync(lastResponse)
                enterConversationMode()
                return
            }

            let apiKey = settings.openAIAPIKey
            guard !apiKey.isEmpty else { throw VoiceError.noAPIKey }

            // 2. Transcribe with Whisper.
            state = .transcribing
            voiceLog.info("🔊 Transcribing...")
            let transcription = try await whisperClient.transcribe(audioData: audioData, apiKey: apiKey)
            lastTranscript = transcription.text
            voiceLog.info("📝 Whisper: '\(transcription.text, privacy: .public)'")

            guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                voiceLog.info("⚠️ Empty transcription")
                lastResponse = "I didn't catch that."
                await executor.speakAsync(lastResponse)
                enterConversationMode()
                return
            }

            // Check for exit phrases.
            let lowerText = transcription.text.lowercased()
            if lowerText.contains("goodbye") || lowerText.contains("that's all")
                || lowerText.contains("never mind") || lowerText.contains("go to sleep")
                || lowerText.contains("thank you alfred") || lowerText.contains("thanks alfred") {
                voiceLog.info("👋 Exit phrase — ending conversation")
                lastResponse = "Very good. I'll be here if you need me."
                state = .speaking
                await executor.speakAsync(lastResponse)
                endConversation()
                return
            }

            conversationHistory.append((role: "user", content: transcription.text))

            // 3. Interpret with GPT.
            state = .interpreting
            voiceLog.info("🤖 Interpreting...")
            let intent = try await interpreter.interpret(
                transcript: transcription.text,
                tunnelActive: monitor.tunnelActive,
                nodeRunning: monitor.nodeRunning,
                apiKey: apiKey,
                model: settings.openAIModel,
                conversationHistory: conversationHistory
            )
            voiceLog.info("🎯 Intent: \(String(describing: intent), privacy: .public)")

            // 4. Execute.
            state = .executing
            let result = await executor.execute(intent)
            lastResponse = result.spokenResponse
            voiceLog.info("✅ '\(result.spokenResponse, privacy: .public)'")

            conversationHistory.append((role: "assistant", content: result.spokenResponse))
            if conversationHistory.count > Self.maxConversationTurns * 2 {
                conversationHistory = Array(conversationHistory.suffix(Self.maxConversationTurns * 2))
            }

            // 5. Speak response.
            state = .speaking
            await executor.speakAsync(result.spokenResponse)

        } catch {
            state = .error
            errorMessage = error.localizedDescription
            lastResponse = "Sorry, something went wrong."
            voiceLog.error("❌ Pipeline error: \(error.localizedDescription, privacy: .public)")
            stopAudioEngine()
            await executor.speakAsync(lastResponse)
        }

        // Enter conversation mode — wait for follow-up.
        enterConversationMode()
    }

    /// Enter conversation mode: listen for follow-up without requiring the hotkey.
    private func enterConversationMode() {
        state = .conversing
        voiceLog.info("💬 Conversation mode (timeout: \(self.conversationTimeout)s)")

        conversationTimer?.cancel()
        conversationTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.conversationTimeout ?? 12.0))
                guard let self, self.state == .conversing else { return }
                voiceLog.info("⏰ Conversation timed out — idle (mic OFF)")
                self.endConversation()
            } catch {
                // Cancelled — follow-up received.
            }
        }

        // After a pause (avoid TTS echo), record follow-up.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard let self, self.state == .conversing else { return }

            voiceLog.info("👂 Listening for follow-up...")

            do {
                try self.ensureAudioEngineRunning()

                let audioData = try await self.whisperClient.recordCommand(
                    audioEngine: self.audioEngine,
                    maxDuration: 8.0,
                    silenceTimeout: 3.0
                )

                self.stopAudioEngine()

                self.conversationTimer?.cancel()
                self.conversationTimer = nil

                let apiKey = self.settings.openAIAPIKey
                guard !apiKey.isEmpty else {
                    self.endConversation()
                    return
                }

                let transcription = try await self.whisperClient.transcribe(audioData: audioData, apiKey: apiKey)
                let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)

                if text.isEmpty {
                    voiceLog.info("🤫 Silence — ending conversation")
                    self.endConversation()
                    return
                }

                voiceLog.info("📝 Follow-up: '\(text, privacy: .public)'")
                self.lastTranscript = text

                let lowerText = text.lowercased()
                if lowerText.contains("goodbye") || lowerText.contains("that's all")
                    || lowerText.contains("never mind") || lowerText.contains("go to sleep")
                    || lowerText.contains("thank you alfred") || lowerText.contains("thanks alfred") {
                    self.lastResponse = "Very good. I'll be here if you need me."
                    self.state = .speaking
                    await self.executor.speakAsync(self.lastResponse)
                    self.endConversation()
                    return
                }

                self.conversationHistory.append((role: "user", content: text))

                self.state = .interpreting
                let intent = try await self.interpreter.interpret(
                    transcript: text,
                    tunnelActive: self.monitor.tunnelActive,
                    nodeRunning: self.monitor.nodeRunning,
                    apiKey: apiKey,
                    model: self.settings.openAIModel,
                    conversationHistory: self.conversationHistory
                )

                self.state = .executing
                let result = await self.executor.execute(intent)
                self.lastResponse = result.spokenResponse
                self.conversationHistory.append((role: "assistant", content: result.spokenResponse))

                if self.conversationHistory.count > Self.maxConversationTurns * 2 {
                    self.conversationHistory = Array(self.conversationHistory.suffix(Self.maxConversationTurns * 2))
                }

                self.state = .speaking
                await self.executor.speakAsync(result.spokenResponse)

                self.enterConversationMode()

            } catch {
                voiceLog.error("❌ Follow-up error: \(error.localizedDescription, privacy: .public)")
                self.stopAudioEngine()
                self.endConversation()
            }
        }
    }

    /// End conversation mode and return to idle (mic OFF).
    private func endConversation() {
        conversationTimer?.cancel()
        conversationTimer = nil
        conversationHistory.removeAll()
        stopAudioEngine()
        state = .idle
        errorMessage = nil
        voiceLog.info("🔄 Conversation ended — idle (mic OFF)")
    }

    // MARK: - Errors

    enum VoiceError: LocalizedError {
        case noAPIKey
        var errorDescription: String? { "No OpenAI API key configured." }
    }
}
