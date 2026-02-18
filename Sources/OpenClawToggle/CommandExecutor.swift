// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Executes parsed voice command intents and speaks results.

import AVFoundation
import Foundation
import os

private let ttsLog = Logger(subsystem: "ai.openclaw.toggle", category: "tts")

/// Provides TTS (text-to-speech) feedback for the voice assistant pipeline.
@MainActor
final class CommandExecutor: NSObject, ObservableObject, AVAudioPlayerDelegate {

    private let settings: AppSettings

    /// AVAudioPlayer for OpenAI TTS playback (must be retained).
    private var audioPlayer: AVAudioPlayer?

    /// Continuation to signal when audio playback finishes.
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    /// Fallback synthesizer for when OpenAI TTS is unavailable.
    private let fallbackSynthesizer = AVSpeechSynthesizer()

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    /// Stop any active TTS playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
        fallbackSynthesizer.stopSpeaking(at: .immediate)
        ttsLog.info("TTS playback stopped")
    }

    // MARK: - Text-to-Speech

    /// Speak text aloud using OpenAI TTS API ("echo" voice).
    /// Falls back to macOS AVSpeechSynthesizer if the API call fails.
    func speak(_ text: String) {
        Task {
            await speakAsync(text)
        }
    }

    /// Async version that tries OpenAI TTS first, then falls back to system TTS.
    /// **Waits for playback to complete** before returning, so the caller knows
    /// when it's safe to start recording again.
    func speakAsync(_ text: String) async {
        // OpenAI TTS has a 4096-char limit; truncate at a sentence boundary.
        let text = Self.truncateForTTS(text, maxLength: 4000)
        let apiKey = settings.openAIAPIKey
        guard !apiKey.isEmpty else {
            ttsLog.info("No API key — using fallback TTS")
            await speakFallbackAsync(text)
            return
        }

        do {
            let audioData = try await openAITTS(text: text, apiKey: apiKey)
            ttsLog.info("OpenAI TTS returned \(audioData.count, privacy: .public) bytes")
            await playAudioAndWait(audioData)
        } catch {
            ttsLog.error("OpenAI TTS failed: \(error.localizedDescription, privacy: .public) — using fallback")
            await speakFallbackAsync(text)
        }
    }

    /// Call OpenAI TTS API with the "echo" voice.
    private func openAITTS(text: String, apiKey: String) async throws -> Data {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let payload: [String: Any] = [
            "model": "tts-1-hd",
            "input": text,
            "voice": "echo",            // Smooth, clear male
            "response_format": "mp3",
            "speed": 1.0,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TTSError.noResponse
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw TTSError.apiError(statusCode: http.statusCode, message: msg)
        }

        return data
    }

    /// Play MP3 audio data and **wait** for playback to complete.
    private func playAudioAndWait(_ data: Data) async {
        // Stop any existing playback.
        audioPlayer?.stop()
        playbackContinuation?.resume()
        playbackContinuation = nil

        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            self.audioPlayer = player

            ttsLog.info("Playing TTS audio (\(player.duration, privacy: .public)s)")

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.playbackContinuation = continuation
                player.play()
            }

            ttsLog.info("TTS playback finished")
        } catch {
            ttsLog.error("Failed to create audio player: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// AVAudioPlayerDelegate — called when playback finishes.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playbackContinuation?.resume()
            self.playbackContinuation = nil
        }
    }

    /// AVAudioPlayerDelegate — called on decode error.
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            ttsLog.error("Audio decode error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            self.playbackContinuation?.resume()
            self.playbackContinuation = nil
        }
    }

    /// Fallback: use macOS system TTS with Daniel (British) voice.
    /// Waits an estimated duration for the speech to finish.
    private func speakFallbackAsync(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        // Try Daniel (British) for Alfred feel; fall back to any en-GB, then default.
        if let daniel = AVSpeechSynthesisVoice(identifier: "com.apple.voice.super-compact.en-GB.Daniel") {
            utterance.voice = daniel
        } else if let british = AVSpeechSynthesisVoice(language: "en-GB") {
            utterance.voice = british
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        fallbackSynthesizer.speak(utterance)

        // Estimate speech duration: ~150ms per word.
        let wordCount = text.components(separatedBy: .whitespaces).count
        let estimatedDuration = Double(wordCount) * 0.15 + 0.5
        ttsLog.info("Fallback TTS: ~\(estimatedDuration, privacy: .public)s estimated for \(wordCount, privacy: .public) words")
        try? await Task.sleep(for: .seconds(estimatedDuration))
    }

    // MARK: - Helpers

    /// Truncate text to fit TTS limits, cutting at the last sentence boundary.
    private static func truncateForTTS(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let truncated = String(text.prefix(maxLength))
        // Try to cut at the last sentence-ending punctuation.
        if let range = truncated.range(of: #"[.!?]"#, options: [.regularExpression, .backwards]) {
            return String(truncated[...range.lowerBound])
        }
        return truncated + "..."
    }

    // MARK: - Errors

    enum TTSError: LocalizedError {
        case noResponse
        case apiError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .noResponse: return "No response from TTS API."
            case .apiError(let code, let msg): return "TTS API error \(code): \(msg)"
            }
        }
    }
}
