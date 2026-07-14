import Foundation
import SwiftData

typealias StoredAgent = StoredModelsSchemaV1.StoredAgent
typealias StoredConversation = StoredModelsSchemaV1.StoredConversation
typealias StoredMessage = StoredModelsSchemaV1.StoredMessage

// V1 pins the shape shipped when schema versioning was adopted (2026-07). Structural changes
// go into a new StoredModelsSchemaV(N+1) enum plus a MigrationStage in StoredModelsMigrationPlan;
// never edit a shipped version's models in place, or existing stores stop hash-matching it.
enum StoredModelsSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredAgent.self, StoredConversation.self, StoredMessage.self]
    }

    @Model
    final class StoredAgent {
        @Attribute(.unique) var id: String
        var name: String
        var address: String
        var token: String = ""
        var createdAt: Date
        var updatedAt: Date

        init(id: String, name: String, address: String, token: String, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.name = name
            self.address = address
            self.token = token
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class StoredConversation {
        @Attribute(.unique) var id: String
        var title: String
        var agentID: String?
        var agentAddress: String
        var modeRaw: String
        var createdAt: Date
        var updatedAt: Date
        var serverSessionData: Data?
        @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
        var messages: [StoredMessage]

        init(
            id: String,
            title: String,
            agentID: String?,
            agentAddress: String,
            modeRaw: String,
            createdAt: Date,
            updatedAt: Date,
            serverSessionData: Data?,
            messages: [StoredMessage]
        ) {
            self.id = id
            self.title = title
            self.agentID = agentID
            self.agentAddress = agentAddress
            self.modeRaw = modeRaw
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.serverSessionData = serverSessionData
            self.messages = messages
        }
    }

    @Model
    final class StoredMessage {
        // Server-chosen message IDs are not globally unique, so `id` is a conversation-scoped
        // composite; `messageID` keeps the original ID for in-conversation matching. The ""
        // default lets stores written before this field existed open via lightweight migration;
        // SwiftDataConversationRepository backfills the real values on init.
        @Attribute(.unique) var id: String
        var messageID: String = ""
        var roleRaw: String
        var content: String
        var createdAt: Date
        var deliveryStateRaw: String = "sent"
        var toolName: String?
        var toolArgumentsData: Data?
        var toolStateRaw: String?
        var conversation: StoredConversation?

        init(
            messageID: String,
            conversationID: String,
            roleRaw: String,
            content: String,
            createdAt: Date,
            deliveryStateRaw: String = "sent",
            toolName: String? = nil,
            toolArgumentsData: Data? = nil,
            toolStateRaw: String? = nil
        ) {
            self.id = StoredMessage.compositeID(conversationID: conversationID, messageID: messageID)
            self.messageID = messageID
            self.roleRaw = roleRaw
            self.content = content
            self.createdAt = createdAt
            self.deliveryStateRaw = deliveryStateRaw
            self.toolName = toolName
            self.toolArgumentsData = toolArgumentsData
            self.toolStateRaw = toolStateRaw
        }

        // Length-prefixing the conversation component keeps the key unambiguous for arbitrary
        // IDs (including ones containing "#"), so distinct (conversation, message) pairs can
        // never produce the same key.
        static func compositeID(conversationID: String, messageID: String) -> String {
            "\(conversationID.utf8.count)#\(conversationID)#\(messageID)"
        }
    }
}

// Stores older than V1 (written before versioning) hash-match no version here and make the
// staged open throw; SwiftDataConversationRepository then falls back to a plan-less open whose
// lightweight inference carries them to the V1 shape, so the next open matches V1.
enum StoredModelsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [StoredModelsSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
