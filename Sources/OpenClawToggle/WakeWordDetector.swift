// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Always-listening wake word detector using on-device speech recognition.

import AVFoundation
import os
import Speech

private let wakeLog = Logger(subsystem: "ai.openclaw.toggle", category: "wakeword")

/// Listens continuously for a wake word using Apple's on-device SFSpeechRecognizer.
/// Recognition runs continuously and restarts every ~50s to stay under Apple's 60s limit.
@MainActor
final class WakeWordDetector: ObservableObject {

    @Published private(set) var isListening = false
    @Published private(set) var micPermissionGranted = false

    /// Called when the wake word is detected.
    var onWakeWordDetected: (() -> Void)?

    /// The wake word to listen for (case-insensitive match).
    var wakeWord: String = "hey alfred"

    // Audio engine shared with the rest of the voice pipeline.
    let audioEngine = AVAudioEngine()

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Periodic restart to avoid Apple's ~60s recognition limit.
    private var restartTimer: Timer?

    // Audio buffer counter for diagnostics.
    private var bufferCount: Int = 0

    // Consecutive error counter to prevent rapid restart loops.
    private var consecutiveErrors: Int = 0
    private static let maxConsecutiveErrors = 5

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
        guard micGranted else {
            micPermissionGranted = false
            return false
        }

        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        micPermissionGranted = speechStatus == .authorized
        return micPermissionGranted
    }

    // MARK: - Start / Stop

    func startListening() throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw WakeWordError.recognizerUnavailable
        }
        guard !isListening else { return }

        speechRecognizer.supportsOnDeviceRecognition = true

        // Disable voice processing to prevent Voice Isolation DSP from eating audio.
        let inputNode = audioEngine.inputNode
        if inputNode.isVoiceProcessingEnabled {
            wakeLog.info("Disabling voice processing on input node...")
            do {
                try inputNode.setVoiceProcessingEnabled(false)
            } catch {
                wakeLog.error("Failed to disable voice processing: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Install audio tap.
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        wakeLog.info("Audio format: sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)")

        bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            self.bufferCount += 1
            // Log every 100th buffer (~every 2s at 48kHz/1024) so we know audio is flowing.
            if self.bufferCount % 100 == 0 {
                // Compute RMS of the buffer to see if there's actual signal.
                let channelData = buffer.floatChannelData?[0]
                let frameLength = Int(buffer.frameLength)
                var rms: Float = 0
                if let data = channelData, frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<frameLength {
                        sum += data[i] * data[i]
                    }
                    rms = sqrt(sum / Float(frameLength))
                }
                wakeLog.info("Audio flowing: buffer #\(self.bufferCount, privacy: .public), RMS=\(rms, privacy: .public)")
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
        wakeLog.info("✅ Audio engine started, listening...")

        // Start recognition immediately.
        startRecognition()

        // Schedule periodic restart every 50 seconds (Apple limit is ~60s).
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartRecognition()
            }
        }
    }

    func stopListening() {
        restartTimer?.invalidate()
        restartTimer = nil

        isListening = false
        cancelRecognition()

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    /// Temporarily pause wake word detection (e.g. while recording a command).
    /// Removes the audio tap so WhisperClient can install its own.
    func pause() {
        cancelRecognition()
        restartTimer?.invalidate()
        restartTimer = nil

        // Remove the wake word tap to free bus 0 for the recording tap.
        audioEngine.inputNode.removeTap(onBus: 0)
        wakeLog.info("Paused: removed audio tap for recording")
    }

    /// Resume wake word detection after a pause.
    /// Reinstalls the audio tap and starts recognition again.
    func resume() {
        guard isListening else { return }

        // Reinstall the audio tap (was removed during pause).
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            self.bufferCount += 1
            if self.bufferCount % 100 == 0 {
                let channelData = buffer.floatChannelData?[0]
                let frameLength = Int(buffer.frameLength)
                var rms: Float = 0
                if let data = channelData, frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<frameLength {
                        sum += data[i] * data[i]
                    }
                    rms = sqrt(sum / Float(frameLength))
                }
                wakeLog.info("Audio flowing: buffer #\(self.bufferCount, privacy: .public), RMS=\(rms, privacy: .public)")
            }
        }
        wakeLog.info("Resumed: reinstalled audio tap")

        consecutiveErrors = 0
        startRecognition()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartRecognition()
            }
        }
    }

    // MARK: - Speech Recognition

    private func startRecognition() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            wakeLog.error("Speech recognizer unavailable!")
            return
        }

        cancelRecognition()
        wakeLog.info("Starting new recognition task...")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        // Don't let the recognizer auto-end on silence — we want continuous listening.
        request.taskHint = .dictation
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString.lowercased()
                    wakeLog.info("Heard: '\(transcript, privacy: .public)' — looking for '\(self.wakeWord.lowercased(), privacy: .public)'")
                    // Reset consecutive errors on any successful recognition.
                    self.consecutiveErrors = 0
                    if transcript.contains(self.wakeWord.lowercased()) {
                        wakeLog.info("⚡ WAKE WORD MATCHED!")
                        self.cancelRecognition()
                        self.onWakeWordDetected?()
                    }
                }
                if let error {
                    self.consecutiveErrors += 1
                    let delay = min(Double(self.consecutiveErrors) * 2.0, 10.0) // 2s, 4s, 6s, 8s, 10s max
                    wakeLog.debug("Recognition ended (\(self.consecutiveErrors, privacy: .public)/\(Self.maxConsecutiveErrors, privacy: .public)): \(error.localizedDescription, privacy: .public) — retry in \(delay, privacy: .public)s")

                    if self.consecutiveErrors >= Self.maxConsecutiveErrors {
                        wakeLog.error("Too many consecutive recognition failures — stopping retries. Periodic restart timer will retry.")
                        // Don't restart — the periodic timer (every 50s) will try again.
                        return
                    }

                    if self.isListening {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(delay))
                            guard let self, self.isListening else { return }
                            self.startRecognition()
                        }
                    }
                }
            }
        }
    }

    private func cancelRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    private func restartRecognition() {
        guard isListening else { return }
        wakeLog.debug("Periodic restart of recognition")
        consecutiveErrors = 0  // Reset error counter on periodic restart.
        startRecognition()
    }

    // MARK: - Errors

    enum WakeWordError: LocalizedError {
        case recognizerUnavailable
        var errorDescription: String? {
            "Speech recognizer is not available on this device."
        }
    }
}
