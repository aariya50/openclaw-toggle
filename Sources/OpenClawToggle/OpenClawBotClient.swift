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

        if let response = result {
            isAvailable = true
            botLog.info("Bot response: '\(response.prefix(200), privacy: .public)'")
            return response
        } else {
            botLog.error("Bot unavailable — will fall back to GPT")
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

    /// Parse the JSON output from `openclaw agent --json`.
    /// This is nonisolated so it can be called from any thread.
    private nonisolated static func parseResponse(_ jsonString: String) -> String? {
        // The JSON output may have multiple lines — find the last valid JSON object.
        let lines = jsonString.components(separatedBy: "\n")
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }

            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Try common response fields.
            if let text = json["text"] as? String, !text.isEmpty {
                return text
            }
            if let reply = json["reply"] as? String, !reply.isEmpty {
                return reply
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
            if let output = json["output"] as? String, !output.isEmpty {
                return output
            }
            if let content = json["content"] as? String, !content.isEmpty {
                return content
            }
            // Check nested response structure.
            if let response = json["response"] as? [String: Any] {
                if let text = response["text"] as? String { return text }
                if let content = response["content"] as? String { return content }
            }
            if let result = json["result"] as? String, !result.isEmpty {
                return result
            }
        }

        // If no JSON field found, try the raw text minus any diagnostic lines.
        let cleanLines = lines.filter { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return !l.isEmpty && !l.hasPrefix("[diagnostic]") && !l.hasPrefix("Gateway")
                && !l.hasPrefix("gateway") && !l.hasPrefix("Error:") && !l.hasPrefix("Source:")
                && !l.hasPrefix("Config:")
        }
        let cleaned = cleanLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
