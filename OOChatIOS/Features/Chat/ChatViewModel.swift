import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var identity: StoredIdentity?
    @Published var conversations: [Conversation]
    @Published var activeID: String?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var agentAddressDraft = ""
    @Published var prompt = ""

    private let store = ConversationStore()
    private let identityStore = IdentityStore()
    private lazy var client = HostedAgentClient(identityStore: identityStore)

    var activeConversation: Conversation? {
        conversations.first { $0.id == activeID } ?? conversations.first
    }

    init() {
        let loaded = store.load()
        self.conversations = loaded.0
        self.activeID = loaded.1 ?? loaded.0.first?.id
        self.agentAddressDraft = loaded.0.first?.agentAddress ?? ""
        do {
            self.identity = try identityStore.loadOrCreateIdentity()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func selectConversation(_ conversation: Conversation) {
        activeID = conversation.id
        agentAddressDraft = conversation.agentAddress
        persist()
    }

    func createConversation() {
        var conversation = Conversation(agentAddress: agentAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        if HostedAgentClient.isHostedAgentAddress(conversation.agentAddress) {
            conversation.title = title(for: conversation.agentAddress)
        }
        conversations.insert(conversation, at: 0)
        activeID = conversation.id
        connectionState = .disconnected
        persist()
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        if activeID == conversation.id {
            activeID = conversations.first?.id
        }
        if conversations.isEmpty {
            conversations = [Conversation()]
            activeID = conversations[0].id
        }
        persist()
    }

    func useAddress() {
        let address = agentAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostedAgentClient.isHostedAgentAddress(address) else {
            errorMessage = "Enter a hosted agent address in 0x-prefixed Ed25519 format."
            return
        }

        if let existing = conversations.first(where: { $0.agentAddress == address }) {
            selectConversation(existing)
        } else {
            var conversation = Conversation(agentAddress: address)
            conversation.title = title(for: address)
            conversations.insert(conversation, at: 0)
            activeID = conversation.id
            persist()
        }

        Task {
            await reconnect()
        }
    }

    func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var conversation = activeConversation, !isProcessing else {
            return
        }
        guard HostedAgentClient.isHostedAgentAddress(conversation.agentAddress) else {
            errorMessage = "Use a hosted agent address before sending a message."
            return
        }

        prompt = ""
        errorMessage = nil
        isProcessing = true
        connectionState = .reconnecting
        conversation.title = conversation.title == "New mobile session" ? titleFromPrompt(text) : conversation.title
        conversation.messages.append(ChatMessage(role: .user, content: text))
        conversation.messages.append(ChatMessage(role: .thinking, content: "Waiting for hosted agent..."))
        upsert(conversation)

        Task {
            do {
                let result = try await client.sendPrompt(agentAddress: conversation.agentAddress, conversation: conversation, prompt: text)
                var updated = self.activeConversation ?? conversation
                updated.messages.removeAll { $0.role == .thinking }
                if let session = result.serverSession {
                    updated.serverSession = session
                }
                updated.messages.append(ChatMessage(role: .agent, content: result.output ?? ""))
                updated.updatedAt = Date()
                self.connectionState = .connected
                self.upsert(updated)
            } catch {
                var updated = self.activeConversation ?? conversation
                updated.messages.removeAll { $0.role == .thinking }
                updated.messages.append(ChatMessage(role: .error, content: error.localizedDescription))
                updated.updatedAt = Date()
                self.errorMessage = error.localizedDescription
                self.connectionState = .disconnected
                self.upsert(updated)
            }
            self.isProcessing = false
        }
    }

    func reconnect() async {
        guard let conversation = activeConversation,
              HostedAgentClient.isHostedAgentAddress(conversation.agentAddress) else {
            return
        }
        errorMessage = nil
        connectionState = .reconnecting
        do {
            let result = try await client.connect(agentAddress: conversation.agentAddress, conversation: conversation)
            if let session = result.serverSession {
                var updated = self.activeConversation ?? conversation
                updated.serverSession = session
                self.upsert(updated)
            }
            connectionState = .connected
        } catch {
            connectionState = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    private func upsert(_ conversation: Conversation) {
        var next = conversation
        next.updatedAt = Date()
        conversations.removeAll { $0.id == next.id }
        conversations.insert(next, at: 0)
        activeID = next.id
        persist()
    }

    private func persist() {
        store.save(conversations, activeID: activeID)
    }

    private func title(for address: String) -> String {
        "Agent \(address.prefix(8))...\(address.suffix(6))"
    }

    private func titleFromPrompt(_ text: String) -> String {
        if text.count > 38 {
            return String(text.prefix(35)) + "..."
        }
        return text
    }
}
