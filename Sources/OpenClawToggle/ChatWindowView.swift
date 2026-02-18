// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Chat window interface (Telegram/Slack style).

import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp: Date
}

struct ChatWindowView: View {
    let assistant: VoiceAssistant
    @State private var inputText = ""
    @State private var messages: [ChatMessage] = []
    @State private var isProcessing = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        
                        // Typing indicator
                        if isProcessing {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.leading, 12)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Input field
            HStack(spacing: 8) {
                TextField("Type a message...", text: $inputText)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }
                
                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(inputText.isEmpty ? .gray : .blue)
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty || isProcessing)
            }
            .padding(12)
        }
        .frame(width: 500, height: 600)
        .onAppear {
            isInputFocused = true
        }
    }
    
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isProcessing else { return }
        
        // Add user message
        messages.append(ChatMessage(role: "user", content: text, timestamp: Date()))
        inputText = ""
        isProcessing = true
        
        // Send to assistant
        Task {
            if let response = await assistant.processTextMessage(text) {
                await MainActor.run {
                    messages.append(ChatMessage(role: "assistant", content: response, timestamp: Date()))
                    isProcessing = false
                }
            } else {
                await MainActor.run {
                    isProcessing = false
                }
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer()
            }
            
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(10)
                    .background(
                        message.role == "user" ? Color.blue : Color.gray.opacity(0.2)
                    )
                    .foregroundColor(message.role == "user" ? .white : .primary)
                    .cornerRadius(12)
                    .frame(maxWidth: 350, alignment: message.role == "user" ? .trailing : .leading)
                
                Text(timeString(from: message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if message.role == "assistant" {
                Spacer()
            }
        }
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
