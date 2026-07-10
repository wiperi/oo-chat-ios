import Foundation

enum ConnectionState: String, Codable {
    case disconnected
    case connected
    case reconnecting
}

enum ChatRole: String, Codable {
    case user
    case agent
    case thinking
    case tool
    case error
}

enum ChatMode: String, CaseIterable, Codable, Identifiable, Equatable {
    case safe
    case plan
    case accept = "accept_edits"
    case ulw

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .safe:
            return "Safe"
        case .plan:
            return "Plan"
        case .accept:
            return "Accept"
        case .ulw:
            return "ULW"
        }
    }
}

struct AgentConnection: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var address: String
    var token: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        address: String,
        name: String? = nil,
        token: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.address = address
        self.name = name ?? Self.defaultName(for: address)
        self.token = token
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case address
        case token
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        address = try container.decode(String.self, forKey: .address)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultName(for: address)
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(address, forKey: .address)
        try container.encode(token, forKey: .token)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    static func defaultName(for address: String) -> String {
        guard address.count > 16 else {
            return address.isEmpty ? "Agent" : "Agent \(address)"
        }
        return "Agent \(address.prefix(8))...\(address.suffix(6))"
    }
}

enum MessageDeliveryState: String, Codable, Equatable {
    case sent
    case queued
    case failed
}

enum ToolCallState: String, Codable, Equatable {
    case running
    case completed
    case failed
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    var role: ChatRole
    var content: String
    var createdAt: Date
    var deliveryState: MessageDeliveryState
    var toolName: String?
    var toolArguments: [String: JSONValue]?
    var toolState: ToolCallState?

    init(
        id: String = UUID().uuidString,
        role: ChatRole,
        content: String,
        createdAt: Date = Date(),
        deliveryState: MessageDeliveryState = .sent,
        toolName: String? = nil,
        toolArguments: [String: JSONValue]? = nil,
        toolState: ToolCallState? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.toolName = toolName
        self.toolArguments = toolArguments
        self.toolState = toolState
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case createdAt
        case deliveryState
        case toolName
        case toolArguments
        case toolState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(ChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deliveryState = try container.decodeIfPresent(MessageDeliveryState.self, forKey: .deliveryState) ?? .sent
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolArguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .toolArguments)
        toolState = try container.decodeIfPresent(ToolCallState.self, forKey: .toolState)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(deliveryState, forKey: .deliveryState)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(toolArguments, forKey: .toolArguments)
        try container.encodeIfPresent(toolState, forKey: .toolState)
    }
}

struct Conversation: Identifiable, Codable, Equatable {
    static let defaultInitialMessage = "ConnectOnion native iOS session is ready."

    let id: String
    var title: String
    var agentID: String?
    var agentAddress: String
    var mode: ChatMode
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var serverSession: [String: JSONValue]?

    init(agentID: String? = nil, agentAddress: String = "") {
        let now = Date()
        self.id = UUID().uuidString
        self.title = "New mobile session"
        self.agentID = agentID
        self.agentAddress = agentAddress
        self.mode = .safe
        self.createdAt = now
        self.updatedAt = now
        self.messages = [
            ChatMessage(role: .agent, content: Self.defaultInitialMessage)
        ]
    }

    init(
        id: String,
        title: String,
        agentID: String?,
        agentAddress: String,
        mode: ChatMode,
        createdAt: Date,
        updatedAt: Date,
        messages: [ChatMessage],
        serverSession: [String: JSONValue]?
    ) {
        self.id = id
        self.title = title
        self.agentID = agentID
        self.agentAddress = agentAddress
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.serverSession = serverSession
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case agentID
        case agentAddress
        case mode
        case createdAt
        case updatedAt
        case messages
        case serverSession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        agentAddress = try container.decode(String.self, forKey: .agentAddress)
        mode = try container.decodeIfPresent(ChatMode.self, forKey: .mode) ?? .safe
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        serverSession = try container.decodeIfPresent([String: JSONValue].self, forKey: .serverSession)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(agentID, forKey: .agentID)
        try container.encode(agentAddress, forKey: .agentAddress)
        try container.encode(mode, forKey: .mode)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(serverSession, forKey: .serverSession)
    }
}

struct ChatSnapshot: Codable, Equatable {
    var agents: [AgentConnection]
    var conversations: [Conversation]
    var activeAgentID: String?
    var activeConversationID: String?

    static let empty = ChatSnapshot(
        agents: [],
        conversations: [],
        activeAgentID: nil,
        activeConversationID: nil
    )
}

struct StoredIdentity: Codable, Equatable {
    let address: String
    let publicKeyHex: String
    let createdAt: Date
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}

struct AgentInfo: Decodable {
    let address: String?
    let name: String?
    let endpoints: [String]?
}

struct ResolvedEndpoint {
    enum Kind {
        case direct
        case relay
    }

    let wsURL: URL
    let kind: Kind
    let label: String
}

struct HostedAgentResult {
    let output: String?
    let endpointLabel: String
    let serverSession: [String: JSONValue]?
}
