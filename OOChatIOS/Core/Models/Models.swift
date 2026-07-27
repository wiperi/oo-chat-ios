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
            return "Accept Edits"
        case .ulw:
            return "Ultra Work"
        }
    }
}

struct AgentConnection: Identifiable, Equatable {
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

enum MessageDeliveryState: String, Codable, Equatable {
    case sent
    case queued
    case failed
    case cancelled
}

enum ToolCallState: String, Codable, Equatable {
    case running
    case completed
    case failed
}

struct ChatImageAttachment: Identifiable, Codable, Equatable {
    static let maximumCount = 10
    static let maximumByteCount = 10 * 1024 * 1024

    let id: String
    let data: Data
    let mimeType: String

    init(
        id: String = UUID().uuidString,
        data: Data,
        mimeType: String
    ) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

struct ChatFileAttachment: Identifiable, Codable, Equatable {
    static let maximumCount = 10
    static let maximumByteCount = 10 * 1024 * 1024

    let id: String
    let name: String
    let data: Data
    let mimeType: String

    init(
        id: String = UUID().uuidString,
        name: String,
        data: Data,
        mimeType: String
    ) {
        self.id = id
        self.name = name
        self.data = data
        self.mimeType = mimeType
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

struct ToolApprovalBatchItem: Equatable {
    let tool: String
    let arguments: JSONValue

    init(tool: String, arguments: [String: JSONValue] = [:]) {
        self.tool = tool
        self.arguments = .object(arguments)
    }

    init(tool: String, rawArguments: JSONValue) {
        self.tool = tool
        self.arguments = rawArguments
    }
}

struct ToolApprovalRequest: Identifiable, Equatable {
    let id: String
    let tool: String
    let arguments: [String: JSONValue]
    let description: String?
    let batchRemaining: [ToolApprovalBatchItem]

    init(
        id: String = UUID().uuidString,
        tool: String,
        arguments: [String: JSONValue],
        description: String? = nil,
        batchRemaining: [ToolApprovalBatchItem] = []
    ) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
        self.description = description
        self.batchRemaining = batchRemaining
    }
}

enum ApprovalDecision: Equatable {
    case allowOnce
    case allowSession
    case rejectSoft(feedback: String?)
    case rejectHard(feedback: String?)
    case rejectExplain(feedback: String?)
}

struct PendingApproval: Identifiable, Equatable {
    let conversationID: String
    let request: ToolApprovalRequest

    var id: String {
        request.id
    }
}

struct UlwCheckpointRequest: Identifiable, Equatable {
    let id: String
    let turnsUsed: Int
    let maxTurns: Int

    init(id: String = UUID().uuidString, turnsUsed: Int, maxTurns: Int) {
        self.id = id
        self.turnsUsed = turnsUsed
        self.maxTurns = maxTurns
    }
}

enum UlwCheckpointDecision: Equatable {
    case continueWork(turns: Int)
    case switchMode(ChatMode)
}

struct PendingUlwCheckpoint: Identifiable, Equatable {
    let conversationID: String
    let request: UlwCheckpointRequest

    var id: String { request.id }
}

struct PlanReviewRequest: Identifiable, Equatable {
    let id: String
    let planContent: String

    init(id: String = UUID().uuidString, planContent: String) {
        self.id = id
        self.planContent = planContent
    }
}

enum PlanReviewDecision: Equatable {
    case approve
    case requestChanges(feedback: String?)
}

struct PendingPlanReview: Identifiable, Equatable {
    let conversationID: String
    let request: PlanReviewRequest

    var id: String { request.id }
}

struct AskUserField: Identifiable, Equatable {
    let name: String
    let label: String
    let type: String
    let placeholder: String?

    var id: String { name }

    init(name: String, label: String, type: String = "text", placeholder: String? = nil) {
        self.name = name
        self.label = label
        self.type = type
        self.placeholder = placeholder
    }

    var isSecure: Bool {
        type.lowercased() == "password"
    }
}

struct AskUserRequest: Identifiable, Equatable {
    let id: String
    let question: String
    let options: [String]
    let multiSelect: Bool
    let fields: [AskUserField]

    init(
        id: String = UUID().uuidString,
        question: String,
        options: [String] = [],
        multiSelect: Bool = false,
        fields: [AskUserField] = []
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.fields = fields
    }
}

enum AskUserDecision: Equatable {
    case answer(String)
    case cancel
}

/// A single transport-level representation for every interaction that pauses an
/// agent turn while the app waits for a person to respond.
enum HostedAgentInteraction: Identifiable, Equatable {
    case approval(ToolApprovalRequest)
    case ulwCheckpoint(UlwCheckpointRequest)
    case planReview(PlanReviewRequest)
    case askUser(AskUserRequest)

    var id: String {
        switch self {
        case .approval(let request):
            return request.id
        case .ulwCheckpoint(let request):
            return request.id
        case .planReview(let request):
            return request.id
        case .askUser(let request):
            return request.id
        }
    }
}

/// Pairs a response with its interaction kind so mismatched responses cannot
/// accidentally be sent over the wire.
enum HostedAgentInteractionDecision: Equatable {
    case approval(ApprovalDecision)
    case ulwCheckpoint(UlwCheckpointDecision)
    case planReview(PlanReviewDecision)
    case askUser(AskUserDecision)
    /// The agent replaced this request with a newer one of the same kind. The gate is released
    /// so the receive loop can continue, but nothing is written back — see
    /// `HostedAgentConnection.interactionResponseFrame`.
    case superseded
}

struct PendingAskUser: Identifiable, Equatable {
    let conversationID: String
    let request: AskUserRequest

    var id: String { request.id }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    var role: ChatRole
    var content: String
    var createdAt: Date
    var deliveryState: MessageDeliveryState
    var images: [ChatImageAttachment]
    var files: [ChatFileAttachment]
    var toolName: String?
    var toolArguments: [String: JSONValue]?
    var toolState: ToolCallState?

    init(
        id: String = UUID().uuidString,
        role: ChatRole,
        content: String,
        createdAt: Date = Date(),
        deliveryState: MessageDeliveryState = .sent,
        images: [ChatImageAttachment] = [],
        files: [ChatFileAttachment] = [],
        toolName: String? = nil,
        toolArguments: [String: JSONValue]? = nil,
        toolState: ToolCallState? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.images = images
        self.files = files
        self.toolName = toolName
        self.toolArguments = toolArguments
        self.toolState = toolState
    }
}

struct Conversation: Identifiable, Equatable {
    let id: String
    var title: String
    var agentID: String?
    var agentAddress: String
    var mode: ChatMode
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var serverSession: [String: JSONValue]?

    /// Placeholder title; `MessageDeliveryCoordinator` compares against it to decide whether
    /// the first prompt should name the conversation.
    static let defaultTitle = "New mobile session"

    init(agentID: String? = nil, agentAddress: String = "") {
        let now = Date()
        self.id = UUID().uuidString
        self.title = Self.defaultTitle
        self.agentID = agentID
        self.agentAddress = agentAddress
        self.mode = .safe
        self.createdAt = now
        self.updatedAt = now
        self.messages = []
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

}

struct ChatSnapshot: Equatable {
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

    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }
}

struct AgentSkill: Identifiable, Decodable, Equatable {
    let name: String
    let description: String
    let location: String?

    var id: String {
        name
    }

    init(name: String, description: String = "", location: String? = nil) {
        self.name = name
        self.description = description
        self.location = location
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case location
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        location = try container.decodeIfPresent(String.self, forKey: .location)
    }
}

struct AgentProfile: Decodable {
    let alias: String?
    let skills: [AgentSkill]?
}

struct AgentInfo: Decodable {
    let address: String?
    let name: String?
    let endpoints: [String]?
    let skills: [AgentSkill]?
    let profile: AgentProfile?

    var advertisedSkills: [AgentSkill] {
        skills ?? profile?.skills ?? []
    }
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
