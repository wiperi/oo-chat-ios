import Foundation

final class ConversationStore: ConversationRepository {
    private let snapshotKey = "connectonion.native-ios.chatSnapshot.v2"
    private let corruptSnapshotKey = "connectonion.native-ios.chatSnapshot.v2.corrupt"
    private let legacyConversationsKey = "connectonion.native-ios.conversations"
    private let legacyActiveConversationKey = "connectonion.native-ios.activeConversation"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> ChatSnapshot {
        if let data = defaults.data(forKey: snapshotKey) {
            if let snapshot = try? decoder.decode(ChatSnapshot.self, from: data) {
                return sorted(snapshot)
            }
            defaults.set(data, forKey: corruptSnapshotKey)
        }

        guard let data = defaults.data(forKey: legacyConversationsKey),
              let conversations = try? decoder.decode([Conversation].self, from: data) else {
            return .empty
        }

        let migrated = migrateLegacyConversations(
            conversations,
            activeConversationID: defaults.string(forKey: legacyActiveConversationKey)
        )
        save(migrated)
        defaults.removeObject(forKey: legacyConversationsKey)
        defaults.removeObject(forKey: legacyActiveConversationKey)
        return migrated
    }

    func save(_ snapshot: ChatSnapshot) {
        if let data = try? encoder.encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    private func sorted(_ snapshot: ChatSnapshot) -> ChatSnapshot {
        ChatSnapshot(
            agents: snapshot.agents.sorted { $0.updatedAt > $1.updatedAt },
            conversations: snapshot.conversations.sorted { $0.updatedAt > $1.updatedAt },
            activeAgentID: snapshot.activeAgentID,
            activeConversationID: snapshot.activeConversationID
        )
    }

    private func migrateLegacyConversations(_ conversations: [Conversation], activeConversationID: String?) -> ChatSnapshot {
        var agents: [AgentConnection] = []
        var migratedConversations: [Conversation] = []

        for var conversation in conversations {
            let address = conversation.agentAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else {
                continue
            }

            if let index = agents.firstIndex(where: { $0.address == address }) {
                if conversation.updatedAt > agents[index].updatedAt {
                    agents[index].updatedAt = conversation.updatedAt
                }
                conversation.agentID = agents[index].id
            } else {
                let agent = AgentConnection(
                    address: address,
                    createdAt: conversation.createdAt,
                    updatedAt: conversation.updatedAt
                )
                agents.append(agent)
                conversation.agentID = agent.id
            }

            conversation.agentAddress = address
            migratedConversations.append(conversation)
        }

        let activeConversation = activeConversationID.flatMap { id in
            migratedConversations.first { $0.id == id }
        }
        let activeAgentID = activeConversation?.agentID ?? agents.first?.id
        return sorted(ChatSnapshot(
            agents: agents,
            conversations: migratedConversations,
            activeAgentID: activeAgentID,
            activeConversationID: activeConversation?.id
        ))
    }
}
