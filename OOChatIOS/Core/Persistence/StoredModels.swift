import Foundation
import SwiftData

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
    @Attribute(.unique) var id: String
    var roleRaw: String
    var content: String
    var createdAt: Date
    var deliveryStateRaw: String = "sent"
    var toolName: String?
    var toolArgumentsData: Data?
    var toolStateRaw: String?
    var conversation: StoredConversation?

    init(
        id: String,
        roleRaw: String,
        content: String,
        createdAt: Date,
        deliveryStateRaw: String = "sent",
        toolName: String? = nil,
        toolArgumentsData: Data? = nil,
        toolStateRaw: String? = nil
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.content = content
        self.createdAt = createdAt
        self.deliveryStateRaw = deliveryStateRaw
        self.toolName = toolName
        self.toolArgumentsData = toolArgumentsData
        self.toolStateRaw = toolStateRaw
    }
}
