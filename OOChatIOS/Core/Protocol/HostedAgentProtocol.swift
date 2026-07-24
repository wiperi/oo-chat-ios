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
            return "Couldn't reach the agent at \(url). Check that the address is correct and the agent is online."
        case .badFrame:
            return "The agent sent a reply the app couldn't understand. Try again."
        case .server(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "The agent reported a problem but didn't say what went wrong. Try again."
                : "The agent reported a problem: \(detail)"
        case .closed:
            return "The connection closed before the agent replied. Try again."
        case .timeout:
            return "The agent didn't reply in time. Try again."
        case .busy:
            return "The agent is still working on your previous message in this conversation. Wait for it to finish, then try again."
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
                output: messageText(frame),
                state: state
            )
        default:
            return nil
        }
    }

    static func messageText(_ frame: [String: JSONValue]) -> String {
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

        // Servers send `arguments` either as an object or as a JSON string; anything else
        // still yields a card (with the raw value shown) rather than failing the frame,
        // because a rejected parse costs the user the whole round-trip.
        let arguments: [String: JSONValue]
        switch decodedArguments(frame["arguments"] ?? frame["args"] ?? .object([:])) {
        case .object(let value):
            arguments = value
        case .null:
            arguments = [:]
        case let other:
            arguments = ["value": other]
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
                rawArguments: decodedArguments(rawArguments)
            )
        }
    }

    private static func decodedArguments(_ value: JSONValue) -> JSONValue {
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
              let maxTurns = frame["max_turns"]?.numberValue,
              // `Int(Double)` traps on out-of-range values, so a frame carrying 1e300
              // would crash the app; reject the frame instead.
              let turnsUsedInt = Int(exactly: turnsUsed.rounded()),
              let maxTurnsInt = Int(exactly: maxTurns.rounded()) else {
            return nil
        }
        return UlwCheckpointRequest(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            turnsUsed: turnsUsedInt,
            maxTurns: maxTurnsInt
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

    /// Stand-in for a known interaction type whose payload could not be parsed. It is never
    /// presented to the user — it exists so the connection can still send that kind's decline
    /// response and let the round-trip finish, instead of tearing the socket down.
    /// Whatever ID the frame carried is preserved: today's response frames do not echo it,
    /// but a placeholder that quietly invents one would start answering the wrong request the
    /// day the protocol gains correlation IDs.
    static func declinePlaceholder(for frame: [String: JSONValue]) -> HostedAgentInteraction? {
        let identifier = frame["approval_id"]?.stringValue
            ?? frame["request_id"]?.stringValue
            ?? frame["id"]?.stringValue
            ?? UUID().uuidString
        switch frame["type"]?.stringValue?.lowercased() {
        case "approval_needed":
            return .approval(ToolApprovalRequest(id: identifier, tool: "unknown", arguments: [:]))
        case "ulw_turns_reached":
            return .ulwCheckpoint(UlwCheckpointRequest(id: identifier, turnsUsed: 0, maxTurns: 0))
        case "plan_review":
            return .planReview(PlanReviewRequest(id: identifier, planContent: ""))
        case "ask_user":
            return .askUser(AskUserRequest(id: identifier, question: ""))
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

/// The one place the echoed `session` dict is normalized before it goes back on the wire:
/// inject the client-owned keys, strip the server-owned ones. Both the outgoing CONNECT frame
/// and the view model's stored session go through here, so a newly stripped key cannot be
/// applied to one and missed by the other — `session_sha256` would reject the mismatch.
enum HostedAgentSessionState {
    static func applying(
        _ mode: ChatMode,
        to session: [String: JSONValue]?,
        conversationID: String
    ) -> [String: JSONValue] {
        var next = session ?? [:]
        next["session_id"] = .string(conversationID)
        next["mode"] = .string(mode.rawValue)
        next.removeValue(forKey: "ulw_turns")
        next.removeValue(forKey: "ulw_turns_used")
        next.removeValue(forKey: "ulw_prompt")
        next.removeValue(forKey: "skip_tool_approval")
        return next
    }

    static func mode(from session: [String: JSONValue], fallback: ChatMode) -> ChatMode {
        guard let rawMode = session["mode"]?.stringValue,
              let mode = ChatMode(rawValue: rawMode) else {
            return fallback
        }
        return mode
    }
}

/// Wire-level operations the view model needs from the hosted-agent client,
/// as a protocol so tests can substitute a scripted transport.
struct HostedAgentFilePayload: Codable, Equatable {
    let name: String
    let data: String

    var jsonValue: JSONValue {
        .object([
            "name": .string(name),
            "data": .string(data),
        ])
    }
}

protocol HostedAgentTransport {
    var onConnectionStateChange: (@MainActor (String, ConnectionState) -> Void)? { get set }

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult
    func fetchSkills(agentAddress: String) async throws -> [AgentSkill]
    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        images: [String],
        files: [HostedAgentFilePayload],
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
    ) async throws -> HostedAgentResult
    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async
    /// Called when the app returns to the foreground, so transports can refresh liveness
    /// bookkeeping that would otherwise treat the suspended time as a dead connection.
    func applicationDidBecomeActive()
}

extension HostedAgentTransport {
    func applicationDidBecomeActive() {}
}
