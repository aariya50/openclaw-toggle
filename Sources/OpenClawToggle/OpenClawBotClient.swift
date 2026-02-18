// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Client for sending messages to the OpenClaw bot (Alfred).
//
// Routes voice transcriptions to the OpenClaw agent via the gateway WebSocket API.
// Uses the `openclaw agent` CLI as a subprocess for reliable gateway communication.

import Foundation
import os

private let botLog = Logger(subsystem: "ai.openclaw.toggle", category: "bot")

/// Sends messages to the OpenClaw bot/agent and returns the response.
/// Uses the `openclaw agent` CLI subprocess to handle WebSocket auth and routing.
@MainActor
final class OpenClawBotClient {

    /// The session ID for voice conversations (maintains context across turns).
    private var sessionId: String = "voice-alfred"

    /// Path to the openclaw CLI binary.
    private let openclawPath: String

    /// Whether the bot is reachable (set to false on failures, retried periodically).
    private(set) var isAvailable: Bool = true

    init() {
        // Try to find openclaw in common locations.
        let candidates = [
            NSHomeDirectory() + "/.nvm/versions/node/v22.18.0/bin/openclaw",
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
            NSHomeDirectory() + "/.bun/bin/openclaw",
        ]
        self.openclawPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "openclaw"
        botLog.info("OpenClaw CLI path: \(self.openclawPath, privacy: .public)")
    }

    /// Send a message to the OpenClaw bot and return the text response.
    /// Returns nil if the bot is unavailable or errors out.
    func sendMessage(_ text: String) async -> String? {
        botLog.info("Sending to OpenClaw bot: '\(text, privacy: .public)'")

        let result = await runOpenClawAgent(message: text)

        if let response = result, !Self.isErrorResponse(response) {
            isAvailable = true
            botLog.info("Bot response: '\(response.prefix(200), privacy: .public)'")
            return response
        } else {
            botLog.error("Bot unavailable")
            isAvailable = false
            return nil
        }
    }

    /// Start a new conversation session.
    func newSession() {
        sessionId = "voice-\(Int(Date().timeIntervalSince1970))"
        botLog.info("New bot session: \(self.sessionId, privacy: .public)")
    }

    /// Reset availability flag for retry.
    func resetAvailability() {
        isAvailable = true
    }

    // MARK: - Private

    /// Run `openclaw agent -m <message> --session-id <id> --json` and parse the response.
    private func runOpenClawAgent(message: String) async -> String? {
        // Capture values on the main actor before dispatching.
        let cliBinary = openclawPath
        let session = sessionId

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: cliBinary)
                process.arguments = [
                    "agent",
                    "-m", message,
                    "--session-id", session,
                    "--json",
                    "--timeout", "30",
                ]
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Inherit PATH so openclaw can find its dependencies.
                var env = ProcessInfo.processInfo.environment
                let nvm = NSHomeDirectory() + "/.nvm/versions/node/v22.18.0/bin"
                if let path = env["PATH"] {
                    env["PATH"] = "\(nvm):\(path)"
                } else {
                    env["PATH"] = "\(nvm):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                }
                process.environment = env

                do {
                    try process.run()
                } catch {
                    botLog.error("Failed to launch openclaw: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }

                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus != 0 {
                    botLog.error("openclaw agent failed (exit \(process.terminationStatus, privacy: .public)): \(stderr.prefix(300), privacy: .public)")
                    // Still try to parse stdout — sometimes partial results are returned.
                }

                // Try to parse JSON response.
                if !stdout.isEmpty, let response = Self.parseResponse(stdout) {
                    continuation.resume(returning: response)
                    return
                }

                // If no JSON, try plain text output.
                if !stdout.isEmpty {
                    botLog.info("Non-JSON response: \(stdout.prefix(200), privacy: .public)")
                    continuation.resume(returning: stdout)
                    return
                }

                botLog.error("Empty response from openclaw agent")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Check if the response is an error message rather than a real agent reply.
    private nonisolated static func isErrorResponse(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http 4") || lower.hasPrefix("http 5")
            || lower.contains("authentication_error") || lower.contains("invalid x-api-key")
            || lower.contains("invalid_api_key") || lower.contains("rate_limit_error")
    }

    /// Parse the JSON output from `openclaw agent --json`.
    /// The CLI outputs diagnostic lines on stderr/stdout followed by a multi-line JSON object.
    /// This is nonisolated so it can be called from any thread.
    private nonisolated static func parseResponse(_ jsonString: String) -> String? {
        // The CLI output may have diagnostic lines before the JSON.
        // Find the first '{' and parse everything from there as a single JSON object.
        guard let jsonStart = jsonString.firstIndex(of: "{") else { return nil }
        let jsonSubstring = String(jsonString[jsonStart...])

        guard let data = jsonSubstring.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Extract payloads text from any nesting level.
        if let text = extractPayloadsText(from: json) {
            return text
        }

        // Fallback: try common top-level string fields.
        for key in ["text", "reply", "message", "output", "content"] {
            if let value = json[key] as? String, !value.isEmpty {
                return value
            }
        }

        return nil
    }

    /// Walk the JSON to find payloads[0].text at any nesting depth.
    /// Handles both `{ "payloads": [...] }` and `{ "result": { "payloads": [...] } }`.
    private nonisolated static func extractPayloadsText(from json: [String: Any]) -> String? {
        // Direct: { "payloads": [{ "text": "..." }] }
        if let payloads = json["payloads"] as? [[String: Any]],
           let first = payloads.first,
           let text = first["text"] as? String, !text.isEmpty {
            return text
        }
        // Nested under "result": { "result": { "payloads": [...] } }
        if let result = json["result"] as? [String: Any],
           let payloads = result["payloads"] as? [[String: Any]],
           let first = payloads.first,
           let text = first["text"] as? String, !text.isEmpty {
            return text
        }
        return nil
    }
}
