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
    case error
}

struct AgentConnection: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var address: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        address: String,
        name: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.address = address
        self.name = name ?? Self.defaultName(for: address)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func defaultName(for address: String) -> String {
        guard address.count > 16 else {
            return address.isEmpty ? "Agent" : "Agent \(address)"
        }
        return "Agent \(address.prefix(8))...\(address.suffix(6))"
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    var role: ChatRole
    var content: String
    var createdAt: Date

    init(id: String = UUID().uuidString, role: ChatRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

struct Conversation: Identifiable, Codable, Equatable {
    static let defaultInitialMessage = "ConnectOnion native iOS session is ready."

    let id: String
    var title: String
    var agentID: String?
    var agentAddress: String
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
        self.createdAt = now
        self.updatedAt = now
        self.messages = [
            ChatMessage(role: .agent, content: Self.defaultInitialMessage)
        ]
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
