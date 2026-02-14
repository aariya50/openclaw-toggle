// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Records audio post-wake-word and transcribes via OpenAI Whisper API.

import AVFoundation
import Foundation

/// Records a voice command from the microphone and transcribes it using the Whisper API.
@MainActor
final class WhisperClient {

    struct TranscriptionResult {
        let text: String
    }

    /// Set to true externally to signal the current recording should stop
    /// (e.g. when the push-to-talk key is released).
    var shouldStopRecording = false

    // MARK: - Record

    /// Record audio from the given audio engine until silence, max duration, or `shouldStopRecording`.
    /// The engine must already be running. The tap slot on bus 0 must be free.
    func recordCommand(
        audioEngine: AVAudioEngine,
        maxDuration: TimeInterval = 8.0,
        silenceTimeout: TimeInterval = 2.0
    ) async throws -> Data {
        shouldStopRecording = false

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let sampleRate = nativeFormat.sampleRate
        let maxFrames = Int(sampleRate * maxDuration)
        let silenceFrames = Int(sampleRate * silenceTimeout)

        return try await withCheckedThrowingContinuation { continuation in
            var pcmBuffers: [AVAudioPCMBuffer] = []
            var totalFrames = 0
            var silentFrameCount = 0
            var finished = false
            let silenceThreshold: Float = 0.008

            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                guard !finished else { return }

                let rms = Self.calculateRMS(buffer)
                let frameCount = Int(buffer.frameLength)
                totalFrames += frameCount

                pcmBuffers.append(buffer)

                if rms < silenceThreshold {
                    silentFrameCount += frameCount
                } else {
                    silentFrameCount = 0
                }

                let externalStop = self?.shouldStopRecording ?? false
                if silentFrameCount >= silenceFrames || totalFrames >= maxFrames || externalStop {
                    finished = true
                    inputNode.removeTap(onBus: 0)
                    let wavData = Self.encodeToWAV(buffers: pcmBuffers, format: recordingFormat)
                    continuation.resume(returning: wavData)
                }
            }

            // Safety timeout
            Task {
                try? await Task.sleep(for: .seconds(maxDuration + 1))
                guard !finished else { return }
                finished = true
                inputNode.removeTap(onBus: 0)
                let wavData = Self.encodeToWAV(buffers: pcmBuffers, format: recordingFormat)
                continuation.resume(returning: wavData)
            }
        }
    }

    /// Signal the current recording to stop (called on key release).
    func stopRecording() {
        shouldStopRecording = true
    }

    // MARK: - Transcribe

    /// Send audio data to OpenAI Whisper API.
    func transcribe(audioData: Data, apiKey: String) async throws -> TranscriptionResult {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // model field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("whisper-1\r\n")
        // language field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        body.append("en\r\n")
        // audio file
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WhisperError.noResponse
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw WhisperError.apiError(statusCode: http.statusCode, message: msg)
        }

        struct WhisperResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return TranscriptionResult(text: result.text)
    }

    // MARK: - WAV Encoding

    /// Convert collected PCM buffers into a WAV file (16kHz mono 16-bit).
    private static func encodeToWAV(buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> Data {
        // Collect all float samples from channel 0.
        var allSamples: [Float] = []
        for buffer in buffers {
            guard let channelData = buffer.floatChannelData else { continue }
            let count = Int(buffer.frameLength)
            allSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))
        }

        // Resample to 16kHz if needed.
        let sourceSampleRate = format.sampleRate
        let targetSampleRate: Double = 16000
        let resampledSamples: [Float]
        if abs(sourceSampleRate - targetSampleRate) > 1 {
            let ratio = targetSampleRate / sourceSampleRate
            let newCount = Int(Double(allSamples.count) * ratio)
            resampledSamples = (0..<newCount).map { i in
                let srcIndex = Double(i) / ratio
                let idx = Int(srcIndex)
                return idx < allSamples.count ? allSamples[idx] : 0
            }
        } else {
            resampledSamples = allSamples
        }

        // Convert float [-1, 1] to Int16.
        let int16Samples = resampledSamples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        // Build WAV.
        var data = Data()
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleRate: UInt32 = 16000
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.appendUInt32(fileSize)
        data.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.appendUInt32(16) // chunk size
        data.appendUInt16(1)  // PCM format
        data.appendUInt16(numChannels)
        data.appendUInt32(sampleRate)
        data.appendUInt32(byteRate)
        data.appendUInt16(blockAlign)
        data.appendUInt16(bitsPerSample)
        // data chunk
        data.append(contentsOf: "data".utf8)
        data.appendUInt32(dataSize)
        for sample in int16Samples {
            var s = sample
            data.append(Data(bytes: &s, count: 2))
        }

        return data
    }

    private static func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames {
            let s = channelData[0][i]
            sum += s * s
        }
        return sqrt(sum / Float(frames))
    }

    // MARK: - Errors

    enum WhisperError: LocalizedError {
        case noResponse
        case apiError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .noResponse: return "No response from Whisper API."
            case .apiError(let code, let msg): return "Whisper API error \(code): \(msg)"
            }
        }
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}
