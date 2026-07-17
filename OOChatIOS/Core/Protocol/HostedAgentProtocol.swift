import Foundation

enum HostedAgentClientError: LocalizedError {
    case invalidAddress
    case invalidURL(String)
    case badFrame
    case server(String)
    case closed
    case timeout
    case busy

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
        case .invalidURL(let url):
            return "Couldn't reach the agent at \(url)."
        case .badFrame:
            return "The agent sent an unexpected reply. Try again."
        case .server(let message):
            return message
        case .closed:
            return "The connection closed before the agent replied. Try again."
        case .timeout:
            return "The agent didn't reply in time. Try again."
        case .busy:
            return "The hosted agent is already processing a message in this conversation."
        }
    }
}
enum HostedAgentEvent: Equatable {
    case toolCall(id: String, name: String, arguments: [String: JSONValue])
    case toolResult(id: String, name: String?, output: String, state: ToolCallState)
    case modeChanged(ChatMode)

    static func from(_ frame: [String: JSONValue]) -> HostedAgentEvent? {
        guard let type = frame["type"]?.stringValue else {
            return nil
        }

        if type == "mode_changed",
           let rawMode = frame["mode"]?.stringValue,
           let mode = ChatMode(rawValue: rawMode) {
            return .modeChanged(mode)
        }

        guard let id = frame["tool_id"]?.stringValue ?? frame["id"]?.stringValue,
              !id.isEmpty else {
            return nil
        }

        switch type {
        case "tool_call":
            let name = frame["name"]?.stringValue ?? "tool"
            let arguments: [String: JSONValue]
            if case .object(let value)? = frame["args"] {
                arguments = value
            } else {
                arguments = [:]
            }
            return .toolCall(id: id, name: name, arguments: arguments)
        case "tool_result":
            let state: ToolCallState = frame["status"]?.stringValue?.lowercased() == "error" ? .failed : .completed
            return .toolResult(
                id: id,
                name: frame["name"]?.stringValue,
                output: eventMessageText(frame),
                state: state
            )
        default:
            return nil
        }
    }

    private static func eventMessageText(_ frame: [String: JSONValue]) -> String {
        for key in ["result", "message", "error", "text", "content"] {
            if let value = frame[key] {
                if let text = value.stringValue {
                    return text
                }
                return formattedJSON(value)
            }
        }
        return "Hosted agent returned \(frame["type"]?.stringValue ?? "an event")."
    }

    private static func formattedJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

extension ToolApprovalRequest {
    static func from(_ frame: [String: JSONValue]) -> ToolApprovalRequest? {
        guard frame["type"]?.stringValue?.lowercased() == "approval_needed",
              let tool = frame["tool"]?.stringValue,
              !tool.isEmpty else {
            return nil
        }

        let argumentsValue = frame["arguments"] ?? frame["args"]
        let arguments: [String: JSONValue]
        switch argumentsValue {
        case .none:
            arguments = [:]
        case .some(.object(let value)):
            arguments = value
        default:
            return nil
        }

        let identifier = frame["approval_id"]?.stringValue
            ?? frame["request_id"]?.stringValue
            ?? frame["id"]?.stringValue
            ?? UUID().uuidString
        let batchRemaining = batchItems(from: frame["batch_remaining"])

        return ToolApprovalRequest(
            id: identifier,
            tool: tool,
            arguments: arguments,
            description: frame["description"]?.stringValue,
            batchRemaining: batchRemaining
        )
    }

    private static func batchItems(from value: JSONValue?) -> [ToolApprovalBatchItem] {
        guard case .array(let values)? = value else {
            return []
        }
        return values.compactMap { item in
            guard case .object(let object) = item,
                  let tool = object["tool"]?.stringValue,
                  !tool.isEmpty else {
                return nil
            }
            let rawArguments = object["arguments"] ?? object["args"] ?? .object([:])
            return ToolApprovalBatchItem(
                tool: tool,
                rawArguments: decodedBatchArguments(rawArguments)
            )
        }
    }

    private static func decodedBatchArguments(_ value: JSONValue) -> JSONValue {
        guard case .string(let text) = value,
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return value
        }
        return decoded
    }
}

extension ApprovalDecision {
    var responseFrame: [String: JSONValue] {
        responseFrame(to: nil)
    }

    func responseFrame(to recipient: String?) -> [String: JSONValue] {
        var frame: [String: JSONValue] = [
            "type": .string("APPROVAL_RESPONSE"),
            "scope": .string("once"),
        ]

        switch self {
        case .allowOnce:
            frame["approved"] = .bool(true)
        case .allowSession:
            frame["approved"] = .bool(true)
            frame["scope"] = .string("session")
        case .rejectSoft(let feedback):
            frame["approved"] = .bool(false)
            frame["mode"] = .string("reject_soft")
            if let feedback, !feedback.isEmpty {
                frame["feedback"] = .string(feedback)
            }
        case .rejectHard(let feedback):
            frame["approved"] = .bool(false)
            frame["mode"] = .string("reject_hard")
            if let feedback, !feedback.isEmpty {
                frame["feedback"] = .string(feedback)
            }
        case .rejectExplain(let feedback):
            frame["approved"] = .bool(false)
            frame["mode"] = .string("reject_explain")
            if let feedback, !feedback.isEmpty {
                frame["feedback"] = .string(feedback)
            }
        }

        if let recipient, !recipient.isEmpty {
            frame["to"] = .string(recipient)
        }

        return frame
    }
}

extension UlwCheckpointRequest {
    static func from(_ frame: [String: JSONValue]) -> UlwCheckpointRequest? {
        guard frame["type"]?.stringValue?.lowercased() == "ulw_turns_reached",
              let turnsUsed = frame["turns_used"]?.numberValue,
              let maxTurns = frame["max_turns"]?.numberValue else {
            return nil
        }
        return UlwCheckpointRequest(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            turnsUsed: Int(turnsUsed),
            maxTurns: Int(maxTurns)
        )
    }
}

extension UlwCheckpointDecision {
    var responseFrame: [String: JSONValue] {
        switch self {
        case .continueWork(let turns):
            return [
                "type": .string("ULW_RESPONSE"),
                "action": .string("continue"),
                "turns": .number(Double(turns)),
            ]
        case .switchMode(let mode):
            return [
                "type": .string("ULW_RESPONSE"),
                "action": .string("switch_mode"),
                "mode": .string(mode.rawValue),
            ]
        }
    }
}

extension PlanReviewRequest {
    static func from(_ frame: [String: JSONValue]) -> PlanReviewRequest? {
        guard frame["type"]?.stringValue?.lowercased() == "plan_review",
              let content = frame["plan_content"]?.stringValue,
              !content.isEmpty else {
            return nil
        }
        return PlanReviewRequest(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            planContent: content
        )
    }
}

extension PlanReviewDecision {
    func responseFrame(for request: PlanReviewRequest) -> [String: JSONValue] {
        let message: String
        switch self {
        case .approve:
            message = "Plan approved. Implement now. Do NOT re-enter plan mode.\n\n---\n\n\(request.planContent)"
        case .requestChanges(let feedback):
            let trimmed = feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = trimmed.isEmpty ? "Plan needs revision." : trimmed
            message = "Plan rejected. Revise with write_plan(). Feedback: \(detail)"
        }
        return [
            "type": .string("PLAN_REVIEW_RESPONSE"),
            "message": .string(message),
        ]
    }
}

extension AskUserRequest {
    static func from(_ frame: [String: JSONValue]) -> AskUserRequest? {
        guard frame["type"]?.stringValue?.lowercased() == "ask_user",
              let question = frame["question"]?.stringValue ?? frame["text"]?.stringValue,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let options: [String]
        if case .array(let values)? = frame["options"] {
            options = values.compactMap(\.stringValue)
        } else {
            options = []
        }

        let fields: [AskUserField]
        if case .array(let values)? = frame["fields"] {
            var seenNames: Set<String> = []
            fields = values.compactMap { value in
                guard case .object(let field) = value,
                      let name = field["name"]?.stringValue,
                      !name.isEmpty,
                      seenNames.insert(name).inserted else {
                    return nil
                }
                return AskUserField(
                    name: name,
                    label: field["label"]?.stringValue ?? name,
                    type: field["type"]?.stringValue ?? "text",
                    placeholder: field["placeholder"]?.stringValue
                )
            }
        } else {
            fields = []
        }

        let multiSelect: Bool
        if case .bool(let value)? = frame["multi_select"] {
            multiSelect = value
        } else {
            multiSelect = false
        }

        return AskUserRequest(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            question: question,
            options: options,
            multiSelect: multiSelect,
            fields: fields
        )
    }
}

extension HostedAgentInteraction {
    static func from(_ frame: [String: JSONValue]) -> HostedAgentInteraction? {
        switch frame["type"]?.stringValue?.lowercased() {
        case "approval_needed":
            return ToolApprovalRequest.from(frame).map(Self.approval)
        case "ulw_turns_reached":
            return UlwCheckpointRequest.from(frame).map(Self.ulwCheckpoint)
        case "plan_review":
            return PlanReviewRequest.from(frame).map(Self.planReview)
        case "ask_user":
            return AskUserRequest.from(frame).map(Self.askUser)
        default:
            return nil
        }
    }

    var unavailableDecision: HostedAgentInteractionDecision {
        switch self {
        case .approval:
            return .approval(.rejectHard(feedback: "Approval unavailable."))
        case .ulwCheckpoint:
            return .ulwCheckpoint(.switchMode(.safe))
        case .planReview:
            return .planReview(.requestChanges(feedback: "Plan review unavailable."))
        case .askUser:
            return .askUser(.cancel)
        }
    }
}

/// Wire-level operations the view model needs from the hosted-agent client,
/// as a protocol so tests can substitute a scripted transport.
protocol HostedAgentTransport {
    var onConnectionStateChange: (@MainActor (String, ConnectionState) -> Void)? { get set }

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult
    func fetchSkills(agentAddress: String) async throws -> [AgentSkill]
    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
    ) async throws -> HostedAgentResult
    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async
}
