// SPDX-License-Identifier: MIT
// OpenClaw Toggle — GPT-based voice command interpreter using tool/function calling.
//
// Two-tier routing:
//   1. Service commands (start/stop/restart tunnel/node, status, diagnostics)
//      are handled locally by GPT with tool calling.
//   2. Conversational messages are routed to the OpenClaw bot (Alfred) via the
//      gateway. If the bot is unavailable, GPT handles them as a fallback.

import Foundation
import os

private let interpLog = Logger(subsystem: "ai.openclaw.toggle", category: "interpreter")

/// Interprets transcribed voice commands using OpenAI GPT with tool calling.
/// Routes conversational messages to the OpenClaw bot when available.
@MainActor
final class CommandInterpreter {

    /// Parsed intent from a voice command.
    enum Intent {
        case startTunnel
        case stopTunnel
        case startNode
        case stopNode
        case restartTunnel
        case restartNode
        case getStatus
        case runDiagnostics
        case chat(response: String)
        case unknown
    }

    /// Client for sending conversational messages to the OpenClaw bot via gateway WebSocket.
    let botClient = OpenClawGatewayClient()

    /// Interpret a transcript given the current system state.
    /// Supports optional conversation history for multi-turn context.
    func interpret(
        transcript: String,
        tunnelActive: Bool,
        nodeRunning: Bool,
        apiKey: String,
        model: String,
        conversationHistory: [(role: String, content: String)] = []
    ) async throws -> Intent {
        // First, use GPT to determine if this is a service command or conversational.
        let intent = try await classifyWithGPT(
            transcript: transcript,
            tunnelActive: tunnelActive,
            nodeRunning: nodeRunning,
            apiKey: apiKey,
            model: model,
            conversationHistory: conversationHistory
        )

        // If it's a service command, return it directly.
        switch intent {
        case .chat(let gptResponse):
            // For conversational messages, try routing through the OpenClaw bot.
            interpLog.info("Chat intent — routing to OpenClaw bot...")
            if botClient.isAvailable {
                if let botResponse = await botClient.sendMessage(transcript) {
                    interpLog.info("Bot response received (\(botResponse.count, privacy: .public) chars)")
                    return .chat(response: botResponse)
                }
            }
            // Bot unavailable — use GPT's response as fallback.
            interpLog.info("Bot unavailable — using GPT fallback response")
            return .chat(response: gptResponse)

        default:
            return intent
        }
    }

    // MARK: - GPT Classification

    /// Use GPT with tool calling to classify the transcript as a service command
    /// or conversational message.
    private func classifyWithGPT(
        transcript: String,
        tunnelActive: Bool,
        nodeRunning: Bool,
        apiKey: String,
        model: String,
        conversationHistory: [(role: String, content: String)]
    ) async throws -> Intent {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let systemPrompt = """
        You are Alfred, the voice assistant for OpenClaw Toggle, a macOS menu bar app \
        that manages an SSH tunnel and a Node service via launchd. \
        Current state: SSH tunnel is \(tunnelActive ? "running" : "stopped"), \
        Node service is \(nodeRunning ? "running" : "stopped"). \
        Interpret the user's voice command and call the appropriate function. \
        If the user is asking a general question or making conversation, respond \
        conversationally in one or two short sentences with a warm, butler-like tone. \
        Speak as a refined, helpful British butler named Alfred.
        """

        // Build messages array with conversation history.
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
        ]

        // Add conversation history (skip the current message — it's added separately).
        for entry in conversationHistory.dropLast(1) {
            messages.append(["role": entry.role, "content": entry.content])
        }

        // Add the current transcript.
        messages.append(["role": "user", "content": transcript])

        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": Self.toolDefinitions,
            "tool_choice": "auto",
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw InterpreterError.apiError(message: msg)
        }

        return try parseResponse(data: data)
    }

    // MARK: - Response Parsing

    private func parseResponse(data: Data) throws -> Intent {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return .unknown
        }

        // Check for tool calls first.
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let firstCall = toolCalls.first,
           let function = firstCall["function"] as? [String: Any],
           let name = function["name"] as? String {

            let argsString = function["arguments"] as? String ?? "{}"
            let args = (try? JSONSerialization.jsonObject(with: Data(argsString.utf8))) as? [String: Any] ?? [:]

            switch name {
            case "toggle_tunnel":
                let action = args["action"] as? String ?? "start"
                return action == "stop" ? .stopTunnel : .startTunnel
            case "toggle_node":
                let action = args["action"] as? String ?? "start"
                return action == "stop" ? .stopNode : .startNode
            case "restart_tunnel":
                return .restartTunnel
            case "restart_node":
                return .restartNode
            case "get_status":
                return .getStatus
            case "run_diagnostics":
                return .runDiagnostics
            default:
                return .unknown
            }
        }

        // No tool call — treat as conversational chat.
        if let content = message["content"] as? String, !content.isEmpty {
            return .chat(response: content)
        }

        return .unknown
    }

    // MARK: - Tool Definitions

    private static let toolDefinitions: [[String: Any]] = [
        makeTool(
            name: "toggle_tunnel",
            description: "Start or stop the SSH tunnel service",
            parameters: [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["start", "stop"]],
                ],
                "required": ["action"],
            ]
        ),
        makeTool(
            name: "toggle_node",
            description: "Start or stop the Node service",
            parameters: [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["start", "stop"]],
                ],
                "required": ["action"],
            ]
        ),
        makeTool(
            name: "restart_tunnel",
            description: "Restart the SSH tunnel service",
            parameters: ["type": "object", "properties": [:]]
        ),
        makeTool(
            name: "restart_node",
            description: "Restart the Node service",
            parameters: ["type": "object", "properties": [:]]
        ),
        makeTool(
            name: "get_status",
            description: "Get the current status of all services",
            parameters: ["type": "object", "properties": [:]]
        ),
        makeTool(
            name: "run_diagnostics",
            description: "Run health diagnostics on the OpenClaw stack",
            parameters: ["type": "object", "properties": [:]]
        ),
    ]

    private static func makeTool(name: String, description: String, parameters: [String: Any]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }

    // MARK: - Errors

    enum InterpreterError: LocalizedError {
        case apiError(message: String)
        var errorDescription: String? {
            switch self {
            case .apiError(let msg): return "GPT error: \(msg)"
            }
        }
    }
}
