import Foundation
import SwiftData

@MainActor
final class SwiftDataConversationRepository: ConversationRepository {
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let activeAgentKey = "connectonion.native-ios.swiftdata.activeAgent"
    private let activeConversationKey = "connectonion.native-ios.swiftdata.activeConversation"


    init(inMemory: Bool = false, storeURL: URL? = nil, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(url: storeURL)
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        }
        container = try ModelContainer(
            for: StoredAgent.self, StoredConversation.self, StoredMessage.self,
            configurations: configuration
        )
        context = ModelContext(container)
    }

    func load() -> ChatSnapshot {
        let agents = (try? context.fetch(FetchDescriptor<StoredAgent>())) ?? []
        let conversations = (try? context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        return ChatSnapshot(
            agents: agents.map(toAgent).sorted { $0.updatedAt > $1.updatedAt },
            conversations: conversations.map(toConversation).sorted { $0.updatedAt > $1.updatedAt },
            activeAgentID: defaults.string(forKey: activeAgentKey),
            activeConversationID: defaults.string(forKey: activeConversationKey)
        )
    }

    func upsertConversation(_ conversation: Conversation) {
        if let stored = storedConversation(id: conversation.id) {
            apply(conversation, to: stored)
        } else {
            context.insert(toStoredConversation(conversation))
        }
        save()
    }

    func deleteConversation(id: String) {
        guard let stored = storedConversation(id: id) else { return }
        context.delete(stored)
        save()
    }

    func upsertAgent(_ agent: AgentConnection) {
        if let stored = storedAgent(id: agent.id) {
            apply(agent, to: stored)
        } else {
            context.insert(toStoredAgent(agent))
        }
        save()
    }

    func deleteAgent(id: String) {
        // Cascade by agentID only. Multiple agents can share one address (distinct tokens),
        // so an address-based cascade would wrongly delete a sibling agent's conversations.
        if let stored = storedAgent(id: id) {
            context.delete(stored)
        }
        let owned = (try? context.fetch(FetchDescriptor<StoredConversation>(
            predicate: #Predicate { $0.agentID == id }
        ))) ?? []
        owned.forEach(context.delete)
        save()
    }

    func saveActive(agentID: String?, conversationID: String?) {
        setActive(agentID, forKey: activeAgentKey)
        setActive(conversationID, forKey: activeConversationKey)
    }

    /// Case- and diacritic-insensitive search over conversation titles and message content,
    /// run as two indexed `#Predicate` fetches and unioned by conversation.
    func search(_ query: String) -> [Conversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return load().conversations
        }
        var matched: [String: StoredConversation] = [:]
        let titleHits = (try? context.fetch(FetchDescriptor<StoredConversation>(
            predicate: #Predicate { $0.title.localizedStandardContains(needle) }
        ))) ?? []
        for conversation in titleHits {
            matched[conversation.id] = conversation
        }
        let messageHits = (try? context.fetch(FetchDescriptor<StoredMessage>(
            predicate: #Predicate { $0.content.localizedStandardContains(needle) }
        ))) ?? []
        for message in messageHits {
            if let conversation = message.conversation {
                matched[conversation.id] = conversation
            }
        }
        return matched.values.map(toConversation).sorted { $0.updatedAt > $1.updatedAt }
    }



    private func storedAgent(id: String) -> StoredAgent? {
        (try? context.fetch(FetchDescriptor<StoredAgent>(predicate: #Predicate { $0.id == id })))?.first
    }

    private func storedConversation(id: String) -> StoredConversation? {
        (try? context.fetch(FetchDescriptor<StoredConversation>(predicate: #Predicate { $0.id == id })))?.first
    }

    private func save() {
        do {
            try context.save()
        } catch {
            // Surface the failure loudly in debug, and roll back so the shared context's
            // uncommitted changes don't get silently flushed by the next operation's save.
            assertionFailure("SwiftData save failed: \(error)")
            context.rollback()
        }
    }

    private func setActive(_ id: String?, forKey key: String) {
        if let id {
            defaults.set(id, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }



    private func apply(_ agent: AgentConnection, to stored: StoredAgent) {
        stored.name = agent.name
        stored.address = agent.address
        stored.token = agent.token
        stored.createdAt = agent.createdAt
        stored.updatedAt = agent.updatedAt
    }

    private func apply(_ conversation: Conversation, to stored: StoredConversation) {
        stored.title = conversation.title
        stored.agentID = conversation.agentID
        stored.agentAddress = conversation.agentAddress
        stored.modeRaw = conversation.mode.rawValue
        stored.createdAt = conversation.createdAt
        stored.updatedAt = conversation.updatedAt
        stored.serverSessionData = encodeSession(conversation.serverSession)
        syncMessages(conversation.messages, of: stored)
    }

    private func syncMessages(_ messages: [ChatMessage], of stored: StoredConversation) {
        let keep = Set(messages.map(\.id))
        for message in stored.messages where !keep.contains(message.id) {
            context.delete(message)
        }
        var existing: [String: StoredMessage] = [:]
        for message in stored.messages {
            existing[message.id] = message
        }
        for message in messages {
            if let storedMessage = existing[message.id] {
                // Existing rows keep their position while streamed tool results update in place.
                storedMessage.roleRaw = message.role.rawValue
                storedMessage.deliveryStateRaw = message.deliveryState.rawValue
                storedMessage.content = message.content
                storedMessage.toolName = message.toolName
                storedMessage.toolArgumentsData = encodeToolArguments(message.toolArguments)
                storedMessage.toolStateRaw = message.toolState?.rawValue
            } else {
                stored.messages.append(toStoredMessage(message))
            }
        }
    }



    private func toAgent(_ stored: StoredAgent) -> AgentConnection {
        AgentConnection(
            id: stored.id,
            address: stored.address,
            name: stored.name,
            token: stored.token,
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
            createdAt: stored.createdAt,
            deliveryState: MessageDeliveryState(rawValue: stored.deliveryStateRaw) ?? .sent,
            toolName: stored.toolName,
            toolArguments: decodeToolArguments(stored.toolArgumentsData),
            toolState: stored.toolStateRaw.flatMap(ToolCallState.init(rawValue:))
        )
    }

    private func toStoredAgent(_ agent: AgentConnection) -> StoredAgent {
        StoredAgent(
            id: agent.id,
            name: agent.name,
            address: agent.address,
            token: agent.token,
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
            createdAt: message.createdAt,
            deliveryStateRaw: message.deliveryState.rawValue,
            toolName: message.toolName,
            toolArgumentsData: encodeToolArguments(message.toolArguments),
            toolStateRaw: message.toolState?.rawValue
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

    private func encodeToolArguments(_ arguments: [String: JSONValue]?) -> Data? {
        guard let arguments else { return nil }
        return try? JSONEncoder().encode(arguments)
    }

    private func decodeToolArguments(_ data: Data?) -> [String: JSONValue]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}
