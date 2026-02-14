// SPDX-License-Identifier: MIT
// OpenClaw Toggle — WebSocket client for the OpenClaw gateway.
//
// Connects to the local gateway (via SSH tunnel) using the Ed25519 device
// identity for challenge-response auth, then sends chat messages via the
// "chat.send" RPC method.

import CryptoKit
import Foundation
import os

private let gwLog = Logger(subsystem: "ai.openclaw.toggle", category: "gateway")

/// Sends chat messages to the OpenClaw bot via the gateway WebSocket API.
@MainActor
final class OpenClawGatewayClient {

    /// Whether the gateway is reachable.
    private(set) var isAvailable: Bool = true

    /// Session key for conversation context.
    private var sessionKey: String = "voice-alfred"

    /// Device identity.
    private var deviceId: String?
    private var privateKey: Curve25519.Signing.PrivateKey?
    private var deviceToken: String?

    /// Gateway auth token.
    private var gatewayToken: String?

    /// The gateway WebSocket URL.
    private let gatewayURL: URL

    /// Request ID counter.
    private var requestId: Int = 0

    init(port: UInt16 = 18789) {
        self.gatewayURL = URL(string: "ws://localhost:\(port)")!
        loadIdentity()
    }

    // MARK: - Public API

    /// Send a message to the OpenClaw bot and return the response.
    func sendMessage(_ text: String) async -> String? {
        guard deviceId != nil, privateKey != nil else {
            gwLog.error("No device identity loaded — cannot connect to gateway")
            isAvailable = false
            return nil
        }

        gwLog.info("Sending to gateway: '\(text.prefix(100), privacy: .public)'")

        do {
            let response = try await sendViaWebSocket(message: text)
            isAvailable = true
            gwLog.info("Gateway response: '\(response.prefix(200), privacy: .public)'")
            return response
        } catch {
            gwLog.error("Gateway error: \(error.localizedDescription, privacy: .public)")
            isAvailable = false
            return nil
        }
    }

    /// Start a new conversation session.
    func newSession() {
        sessionKey = "voice-\(Int(Date().timeIntervalSince1970))"
        gwLog.info("New gateway session: \(self.sessionKey, privacy: .public)")
    }

    /// Reset availability for retry.
    func resetAvailability() {
        isAvailable = true
    }

    // MARK: - Identity Loading

    private func loadIdentity() {
        let stateDir = NSHomeDirectory() + "/.openclaw"

        // Load device keys.
        let devicePath = stateDir + "/identity/device.json"
        guard let deviceData = FileManager.default.contents(atPath: devicePath),
              let deviceJson = try? JSONSerialization.jsonObject(with: deviceData) as? [String: Any] else {
            gwLog.error("Cannot read device.json")
            return
        }

        deviceId = deviceJson["deviceId"] as? String

        // Parse Ed25519 private key from PEM.
        if let pemString = deviceJson["privateKeyPem"] as? String {
            privateKey = parseEd25519PrivateKey(pem: pemString)
        }

        // Load device auth token.
        let authPath = stateDir + "/identity/device-auth.json"
        if let authData = FileManager.default.contents(atPath: authPath),
           let authJson = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
           let tokens = authJson["tokens"] as? [String: Any] {
            // Use the node token — it's the one that's paired.
            for (_, tokenInfo) in tokens {
                if let info = tokenInfo as? [String: Any],
                   let token = info["token"] as? String {
                    deviceToken = token
                    break
                }
            }
        }

        // Load gateway auth token.
        let configPath = stateDir + "/openclaw.json"
        if let configData = FileManager.default.contents(atPath: configPath),
           let configJson = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
           let gateway = configJson["gateway"] as? [String: Any],
           let auth = gateway["auth"] as? [String: Any],
           let token = auth["token"] as? String {
            gatewayToken = token
        }

        gwLog.info("Identity loaded: deviceId=\(self.deviceId?.prefix(12) ?? "nil", privacy: .public) hasKey=\(self.privateKey != nil) hasToken=\(self.deviceToken != nil) hasGwToken=\(self.gatewayToken != nil)")
    }

    /// Parse an Ed25519 private key from PEM format.
    private func parseEd25519PrivateKey(pem: String) -> Curve25519.Signing.PrivateKey? {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let derData = Data(base64Encoded: base64) else {
            gwLog.error("Failed to decode private key base64")
            return nil
        }

        // PKCS#8 wrapping for Ed25519: the raw 32-byte key starts at offset 16.
        // DER structure: SEQUENCE { SEQUENCE { OID }, OCTET STRING { OCTET STRING { key } } }
        guard derData.count >= 48 else {
            gwLog.error("Private key DER too short: \(derData.count) bytes")
            return nil
        }

        let rawKeyBytes = derData.suffix(32)
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: rawKeyBytes)
        } catch {
            gwLog.error("Failed to create Ed25519 key: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - WebSocket Communication

    /// Connect to the gateway, authenticate, send a chat message, collect the response.
    private nonisolated func sendViaWebSocket(message: String) async throws -> String {
        let session = URLSession(configuration: .default)
        var request = URLRequest(url: gatewayURL)
        if let token = await MainActor.run(body: { self.gatewayToken }) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let ws = session.webSocketTask(with: request)
        ws.resume()

        defer {
            ws.cancel(with: .goingAway, reason: nil)
        }

        // 1. Receive challenge.
        let challengeMsg = try await ws.receive()
        guard let challengeJson = parseWSMessage(challengeMsg),
              let event = challengeJson["event"] as? String,
              event == "connect.challenge",
              let payload = challengeJson["payload"] as? [String: Any],
              let nonce = payload["nonce"] as? String else {
            throw GatewayError.noChallenge
        }
        gwLog.info("Got challenge nonce: \(nonce.prefix(12), privacy: .public)...")

        // 2. Sign and send connect.
        let deviceId = await MainActor.run { self.deviceId ?? "" }
        let privateKey = await MainActor.run { self.privateKey }
        let deviceToken = await MainActor.run { self.deviceToken }
        let sessionKey = await MainActor.run { self.sessionKey }

        guard let privateKey else { throw GatewayError.noIdentity }

        let signedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        let signPayload = "\(nonce):\(signedAtMs):\(deviceToken ?? "")"
        let signData = Data(signPayload.utf8)
        let signature = try privateKey.signature(for: signData)
        let signatureHex = signature.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }

        let connectPayload: [String: Any] = [
            "type": "request",
            "id": nextRequestId(),
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "client": [
                    "id": "openclaw-toggle",
                    "version": "4.0.0",
                    "platform": "macOS",
                ],
                "auth": [
                    "deviceId": deviceId,
                    "signature": signatureHex,
                    "signedAt": signedAtMs,
                    "nonce": nonce,
                    "token": deviceToken as Any,
                ],
                "sessionKey": sessionKey,
            ] as [String: Any],
        ]

        let connectData = try JSONSerialization.data(withJSONObject: connectPayload)
        try await ws.send(.string(String(data: connectData, encoding: .utf8)!))

        // 3. Receive connect response.
        let connectResp = try await ws.receive()
        let connectJson = parseWSMessage(connectResp)
        if let error = (connectJson?["error"] as? [String: Any])?["message"] as? String {
            throw GatewayError.connectFailed(error)
        }
        gwLog.info("Connected to gateway!")

        // 4. Send chat.send request.
        let chatRequestId = nextRequestId()
        let chatPayload: [String: Any] = [
            "type": "request",
            "id": chatRequestId,
            "method": "chat.send",
            "params": [
                "message": message,
                "sessionKey": sessionKey,
            ],
        ]

        let chatData = try JSONSerialization.data(withJSONObject: chatPayload)
        try await ws.send(.string(String(data: chatData, encoding: .utf8)!))
        gwLog.info("Sent chat.send request (id=\(chatRequestId, privacy: .public))")

        // 5. Collect response events until we get the final response.
        // The gateway streams events like "chat.turn.start", "chat.chunk", "chat.turn.end".
        var responseText = ""
        let timeout = Date().addingTimeInterval(60)

        while Date() < timeout {
            let msg = try await ws.receive()
            guard let json = parseWSMessage(msg) else { continue }

            let type = json["type"] as? String ?? ""

            // Check for response to our chat.send request.
            if type == "response", let id = json["id"] as? Int, id == chatRequestId {
                // The chat.send response may contain the result directly.
                if let result = json["result"] as? [String: Any],
                   let text = result["text"] as? String {
                    return text
                }
                // Or it might just acknowledge — we need to wait for events.
                continue
            }

            // Handle streaming events.
            if type == "event" {
                let eventName = json["event"] as? String ?? ""
                let eventPayload = json["payload"] as? [String: Any] ?? [:]

                switch eventName {
                case "chat.chunk":
                    if let chunk = eventPayload["text"] as? String {
                        responseText += chunk
                    }
                    if let chunk = eventPayload["content"] as? String {
                        responseText += chunk
                    }

                case "chat.turn.end", "agent.turn.end":
                    // Final response.
                    if let text = eventPayload["text"] as? String, !text.isEmpty {
                        return text
                    }
                    if let reply = eventPayload["reply"] as? String, !reply.isEmpty {
                        return reply
                    }
                    if let result = eventPayload["result"] as? [String: Any],
                       let text = result["text"] as? String {
                        return text
                    }
                    // Return accumulated chunks.
                    if !responseText.isEmpty {
                        return responseText
                    }

                case "chat.message":
                    // Might contain the full response.
                    if let text = eventPayload["text"] as? String, !text.isEmpty {
                        return text
                    }
                    if let content = eventPayload["content"] as? String, !content.isEmpty {
                        return content
                    }

                default:
                    // Skip other events.
                    gwLog.debug("Gateway event: \(eventName, privacy: .public)")
                }
            }
        }

        // If we accumulated text, return it.
        if !responseText.isEmpty {
            return responseText
        }

        throw GatewayError.timeout
    }

    // MARK: - Helpers

    private nonisolated func nextRequestId() -> Int {
        // Simple incrementing ID (not thread-safe, but OK for sequential use).
        return Int(Date().timeIntervalSince1970 * 1000) % 1_000_000
    }

    private nonisolated func parseWSMessage(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json
        case .data(let data):
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        @unknown default:
            return nil
        }
    }

    // MARK: - Errors

    enum GatewayError: LocalizedError {
        case noChallenge
        case noIdentity
        case connectFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .noChallenge: return "No challenge received from gateway"
            case .noIdentity: return "No device identity configured"
            case .connectFailed(let msg): return "Gateway connect failed: \(msg)"
            case .timeout: return "Gateway response timed out"
            }
        }
    }
}
