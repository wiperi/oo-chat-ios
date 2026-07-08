import Foundation
import SwiftData

final class SwiftDataConversationRepository: ConversationRepository {
    private let container: ModelContainer
    private let defaults: UserDefaults
    private let activeAgentKey = "connectonion.native-ios.swiftdata.activeAgent"
    private let activeConversationKey = "connectonion.native-ios.swiftdata.activeConversation"

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(
            for: StoredAgent.self, StoredConversation.self, StoredMessage.self,
            configurations: configuration
        )
    }

    func load() -> ChatSnapshot {
        let context = ModelContext(container)
        let agents = (try? context.fetch(FetchDescriptor<StoredAgent>())) ?? []
        let conversations = (try? context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        return ChatSnapshot(
            agents: agents.map(toAgent).sorted { $0.updatedAt > $1.updatedAt },
            conversations: conversations.map(toConversation).sorted { $0.updatedAt > $1.updatedAt },
            activeAgentID: defaults.string(forKey: activeAgentKey),
            activeConversationID: defaults.string(forKey: activeConversationKey)
        )
    }

    func save(_ snapshot: ChatSnapshot) {
        let context = ModelContext(container)
        syncAgents(snapshot.agents, in: context)
        syncConversations(snapshot.conversations, in: context)
        try? context.save()
        saveActive(agentID: snapshot.activeAgentID, conversationID: snapshot.activeConversationID)
    }

    func upsertConversation(_ conversation: Conversation) {
        let context = ModelContext(container)
        let id = conversation.id
        let existing = (try? context.fetch(FetchDescriptor<StoredConversation>(predicate: #Predicate { $0.id == id })))?.first
        if let stored = existing {
            apply(conversation, to: stored, in: context)
        } else {
            context.insert(toStoredConversation(conversation))
        }
        try? context.save()
    }

    func deleteConversation(id: String) {
        let context = ModelContext(container)
        let stored = (try? context.fetch(FetchDescriptor<StoredConversation>(predicate: #Predicate { $0.id == id })))?.first
        guard let stored else { return }
        context.delete(stored)
        try? context.save()
    }

    func upsertAgent(_ agent: AgentConnection) {
        let context = ModelContext(container)
        let id = agent.id
        let existing = (try? context.fetch(FetchDescriptor<StoredAgent>(predicate: #Predicate { $0.id == id })))?.first
        if let stored = existing {
            apply(agent, to: stored)
        } else {
            context.insert(toStoredAgent(agent))
        }
        try? context.save()
    }

    func deleteAgent(id: String) {
        let context = ModelContext(container)
        if let stored = (try? context.fetch(FetchDescriptor<StoredAgent>(predicate: #Predicate { $0.id == id })))?.first {
            context.delete(stored)
        }
        let conversations = (try? context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        conversations.filter { $0.agentID == id }.forEach { context.delete($0) }
        try? context.save()
    }

    func saveActive(agentID: String?, conversationID: String?) {
        setActive(agentID, forKey: activeAgentKey)
        setActive(conversationID, forKey: activeConversationKey)
    }

    private func syncAgents(_ agents: [AgentConnection], in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<StoredAgent>())) ?? []
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keep = Set(agents.map(\.id))
        for stored in existing where !keep.contains(stored.id) {
            context.delete(stored)
        }
        for agent in agents {
            if let stored = byID[agent.id] {
                apply(agent, to: stored)
            } else {
                context.insert(toStoredAgent(agent))
            }
        }
    }

    private func syncConversations(_ conversations: [Conversation], in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keep = Set(conversations.map(\.id))
        for stored in existing where !keep.contains(stored.id) {
            context.delete(stored)
        }
        for conversation in conversations {
            if let stored = byID[conversation.id] {
                apply(conversation, to: stored, in: context)
            } else {
                context.insert(toStoredConversation(conversation))
            }
        }
    }

    private func apply(_ agent: AgentConnection, to stored: StoredAgent) {
        stored.name = agent.name
        stored.address = agent.address
        stored.createdAt = agent.createdAt
        stored.updatedAt = agent.updatedAt
    }

    private func apply(_ conversation: Conversation, to stored: StoredConversation, in context: ModelContext) {
        stored.title = conversation.title
        stored.agentID = conversation.agentID
        stored.agentAddress = conversation.agentAddress
        stored.modeRaw = conversation.mode.rawValue
        stored.createdAt = conversation.createdAt
        stored.updatedAt = conversation.updatedAt
        stored.serverSessionData = encodeSession(conversation.serverSession)
        syncMessages(conversation.messages, of: stored, in: context)
    }

    private func syncMessages(_ messages: [ChatMessage], of stored: StoredConversation, in context: ModelContext) {
        let keep = Set(messages.map(\.id))
        for message in stored.messages where !keep.contains(message.id) {
            context.delete(message)
        }
        let existing = Set(stored.messages.map(\.id))
        for message in messages where !existing.contains(message.id) {
            stored.messages.append(toStoredMessage(message))
        }
    }

    private func setActive(_ id: String?, forKey key: String) {
        if let id {
            defaults.set(id, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func toAgent(_ stored: StoredAgent) -> AgentConnection {
        AgentConnection(
            id: stored.id,
            address: stored.address,
            name: stored.name,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt
        )
    }

    private func toConversation(_ stored: StoredConversation) -> Conversation {
        Conversation(
            id: stored.id,
            title: stored.title,
            agentID: stored.agentID,
            agentAddress: stored.agentAddress,
            mode: ChatMode(rawValue: stored.modeRaw) ?? .safe,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            messages: stored.messages
                .sorted { $0.createdAt < $1.createdAt }
                .map(toMessage),
            serverSession: decodeSession(stored.serverSessionData)
        )
    }

    private func toMessage(_ stored: StoredMessage) -> ChatMessage {
        ChatMessage(
            id: stored.id,
            role: ChatRole(rawValue: stored.roleRaw) ?? .agent,
            content: stored.content,
            createdAt: stored.createdAt
        )
    }

    private func toStoredAgent(_ agent: AgentConnection) -> StoredAgent {
        StoredAgent(
            id: agent.id,
            name: agent.name,
            address: agent.address,
            createdAt: agent.createdAt,
            updatedAt: agent.updatedAt
        )
    }

    private func toStoredConversation(_ conversation: Conversation) -> StoredConversation {
        StoredConversation(
            id: conversation.id,
            title: conversation.title,
            agentID: conversation.agentID,
            agentAddress: conversation.agentAddress,
            modeRaw: conversation.mode.rawValue,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            serverSessionData: encodeSession(conversation.serverSession),
            messages: conversation.messages.map(toStoredMessage)
        )
    }

    private func toStoredMessage(_ message: ChatMessage) -> StoredMessage {
        StoredMessage(
            id: message.id,
            roleRaw: message.role.rawValue,
            content: message.content,
            createdAt: message.createdAt
        )
    }

    private func encodeSession(_ session: [String: JSONValue]?) -> Data? {
        guard let session else { return nil }
        return try? JSONEncoder().encode(session)
    }

    private func decodeSession(_ data: Data?) -> [String: JSONValue]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}
