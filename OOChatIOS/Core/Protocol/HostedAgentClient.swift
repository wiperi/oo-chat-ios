import CryptoKit
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
        onApprovalRequest: (@MainActor (ToolApprovalRequest) async -> ApprovalDecision)?,
        onUlwCheckpoint: (@MainActor (UlwCheckpointRequest) async -> UlwCheckpointDecision)?,
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?,
        onAskUser: (@MainActor (AskUserRequest) async -> AskUserDecision)?
    ) async throws -> HostedAgentResult
    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async
}

final class HostedAgentClient: HostedAgentTransport {
    private let connectionPool: HostedAgentConnectionPool
    private let discovery: HostedAgentDiscovery
    private let connectionStateObserver: HostedAgentConnectionStateObserver

    var onConnectionStateChange: (@MainActor (String, ConnectionState) -> Void)? {
        get { connectionStateObserver.handler }
        set { connectionStateObserver.handler = newValue }
    }

    init(
        identityStore: IdentityStore,
        session: URLSession = .shared,
        poolSize: Int = 3,
        connectionIdleLifetime: TimeInterval = 5 * 60
    ) {
        let relayURL = "wss://oo.openonion.ai"
        let localEndpoints = ["http://localhost:8000", "http://127.0.0.1:8000"]
        let discovery = HostedAgentDiscovery(
            session: session,
            relayURL: relayURL,
            localEndpoints: localEndpoints
        )
        let connectionStateObserver = HostedAgentConnectionStateObserver()
        self.discovery = discovery
        self.connectionStateObserver = connectionStateObserver
        connectionPool = HostedAgentConnectionPool(
            identityStore: identityStore,
            session: session,
            maximumSize: poolSize,
            idleLifetime: connectionIdleLifetime,
            discovery: discovery,
            connectionStateObserver: connectionStateObserver
        )
    }

    deinit {
        let connectionPool = connectionPool
        Task {
            await connectionPool.closeAll()
        }
    }

    static func isHostedAgentAddress(_ address: String) -> Bool {
        address.range(of: #"^0x[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil
    }

    static func connectSignaturePayload(
        agentAddress: String,
        conversationID: String,
        session: [String: JSONValue],
        timestamp: Double
    ) -> [String: JSONValue] {
        [
            "action": .string("session.connect"),
            "to": .string(agentAddress),
            "timestamp": .number(timestamp),
            "session_id": .string(conversationID),
            "session_sha256": .string(canonicalSHA256(.object(session))),
        ]
    }

    static func inputSignaturePayload(
        agentAddress: String,
        conversationID: String,
        inputID: String,
        prompt: String,
        mode: ChatMode,
        timestamp: Double
    ) -> [String: JSONValue] {
        [
            "action": .string("session.input"),
            "to": .string(agentAddress),
            "timestamp": .number(timestamp),
            "session_id": .string(conversationID),
            "input_id": .string(inputID),
            "prompt": .string(prompt),
            "mode": .string(mode.rawValue),
            "attachments_sha256": .string(
                canonicalSHA256(
                    .object([
                        "images": .array([]),
                        "files": .array([]),
                    ])
                )
            ),
        ]
    }

    private static func canonicalSHA256(_ value: JSONValue) -> String {
        let digest = SHA256.hash(data: Data(CanonicalJSON.string(from: value).utf8))
        return Hex.encode(Data(digest))
    }

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        return try await connectionPool.connect(agentAddress: agentAddress, conversation: conversation)
    }

    func fetchSkills(agentAddress: String) async throws -> [AgentSkill] {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        let result = try await discovery.discover(agentAddress: agentAddress)
        guard result.metadataAvailable else {
            throw HostedAgentClientError.server("Agent skill metadata is unavailable.")
        }
        return result.skills
    }

    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onApprovalRequest: (@MainActor (ToolApprovalRequest) async -> ApprovalDecision)?,
        onUlwCheckpoint: (@MainActor (UlwCheckpointRequest) async -> UlwCheckpointDecision)?,
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?,
        onAskUser: (@MainActor (AskUserRequest) async -> AskUserDecision)?
    ) async throws -> HostedAgentResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        return try await connectionPool.sendPrompt(
            agentAddress: agentAddress,
            conversation: conversation,
            prompt: prompt,
            onEvent: onEvent,
            onApprovalRequest: onApprovalRequest,
            onUlwCheckpoint: onUlwCheckpoint,
            onPlanReview: onPlanReview,
            onAskUser: onAskUser
        )
    }

    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async {
        await connectionPool.waitForPendingInteractionResponses(
            agentAddress: agentAddress,
            conversationID: conversationID
        )
    }

    static func approvalResponseFrame(
        decision: ApprovalDecision,
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        let recipient = endpoint.kind == .relay ? agentAddress : nil
        return decision.responseFrame(to: recipient)
    }

    static func ulwResponseFrame(
        decision: UlwCheckpointDecision,
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        routedInteractiveFrame(
            decision.responseFrame,
            agentAddress: agentAddress,
            endpoint: endpoint
        )
    }

    static func planReviewResponseFrame(
        decision: PlanReviewDecision,
        request: PlanReviewRequest,
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        routedInteractiveFrame(
            decision.responseFrame(for: request),
            agentAddress: agentAddress,
            endpoint: endpoint
        )
    }

    static func askUserResponseFrame(
        answer: String,
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        routedInteractiveFrame(
            [
                "type": .string("ASK_USER_RESPONSE"),
                "answer": .string(answer),
            ],
            agentAddress: agentAddress,
            endpoint: endpoint
        )
    }

    private static func routedInteractiveFrame(
        _ frame: [String: JSONValue],
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        guard endpoint.kind == .relay else {
            return frame
        }
        var routed = frame
        routed["to"] = .string(agentAddress)
        return routed
    }

}

private final class HostedAgentConnectionStateObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: (@MainActor (String, ConnectionState) -> Void)?
    private var sequenceByConversationID: [String: Int] = [:]

    var handler: (@MainActor (String, ConnectionState) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    func notify(conversationID: String, state: ConnectionState) {
        lock.lock()
        let sequence = (sequenceByConversationID[conversationID] ?? 0) + 1
        sequenceByConversationID[conversationID] = sequence
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let handler = self?.currentHandler(
                conversationID: conversationID,
                sequence: sequence
            ) else {
                return
            }
            handler(conversationID, state)
        }
    }

    private func currentHandler(
        conversationID: String,
        sequence: Int
    ) -> (@MainActor (String, ConnectionState) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard sequenceByConversationID[conversationID] == sequence else {
            return nil
        }
        return storedHandler
    }
}

private struct HostedAgentConnectionKey: Hashable {
    let agentAddress: String
    let conversationID: String
}

private struct HostedAgentDiscoveryResult {
    let endpoint: ResolvedEndpoint
    let skills: [AgentSkill]
    let metadataAvailable: Bool
}

/// Resolves both the connection route and the public metadata advertised by an agent.
/// Direct `/info` metadata is preferred; relay profile metadata is the fallback when
/// the host itself cannot be reached over HTTP.
private actor HostedAgentDiscovery {
    private let session: URLSession
    private let relayURL: String
    private let localEndpoints: [String]

    init(session: URLSession, relayURL: String, localEndpoints: [String]) {
        self.session = session
        self.relayURL = relayURL
        self.localEndpoints = localEndpoints
    }

    func discover(agentAddress: String) async throws -> HostedAgentDiscoveryResult {
        for httpURL in localEndpoints {
            if let result = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 1.2) {
                return result
            }
        }

        let normalizedRelay = relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relayHTTP = normalizedRelay.replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        var relaySkills: [AgentSkill] = []
        var relayMetadataAvailable = false
        if let url = URL(string: "\(relayHTTP)/api/relay/agents/\(agentAddress)"),
           let relayInfo: AgentInfo = try? await fetchJSON(url: url, timeout: 3.0) {
            relayMetadataAvailable = true
            relaySkills = normalizedSkills(relayInfo.advertisedSkills)
            for httpURL in sortByProximity(relayInfo.endpoints ?? []) where httpURL.hasPrefix("http") {
                if let result = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 2.5) {
                    return result
                }
            }
        }

        guard let relaySocketURL = URL(string: "\(normalizedRelay)/ws/input") else {
            throw HostedAgentClientError.invalidURL("\(normalizedRelay)/ws/input")
        }
        return HostedAgentDiscoveryResult(
            endpoint: ResolvedEndpoint(wsURL: relaySocketURL, kind: .relay, label: normalizedRelay),
            skills: relaySkills,
            metadataAvailable: relayMetadataAvailable
        )
    }

    private func probe(
        httpURL: String,
        agentAddress: String,
        timeout: TimeInterval
    ) async throws -> HostedAgentDiscoveryResult? {
        guard let url = URL(string: "\(httpURL)/info") else {
            return nil
        }
        guard let info: AgentInfo = try? await fetchJSON(url: url, timeout: timeout),
              info.address == agentAddress else {
            return nil
        }
        guard let wsURL = URL(string: httpToWebSocket(httpURL)) else {
            throw HostedAgentClientError.invalidURL(httpURL)
        }
        return HostedAgentDiscoveryResult(
            endpoint: ResolvedEndpoint(
                wsURL: wsURL,
                kind: .direct,
                label: info.name.map { "\($0) at \(httpURL)" } ?? httpURL
            ),
            skills: normalizedSkills(info.advertisedSkills),
            metadataAvailable: true
        )
    }

    private func fetchJSON<T: Decodable>(url: URL, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw HostedAgentClientError.server("Endpoint \(url.absoluteString) did not return OK.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func normalizedSkills(_ skills: [AgentSkill]) -> [AgentSkill] {
        var seen: Set<String> = []
        return skills.compactMap { skill in
            let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else {
                return nil
            }
            return AgentSkill(
                name: name,
                description: skill.description.trimmingCharacters(in: .whitespacesAndNewlines),
                location: skill.location
            )
        }
    }

    private func sortByProximity(_ endpoints: [String]) -> [String] {
        endpoints.sorted { left, right in
            priority(left) < priority(right)
        }
    }

    private func priority(_ endpoint: String) -> Int {
        if endpoint.contains("localhost") || endpoint.contains("127.0.0.1") {
            return 0
        }
        if endpoint.contains("192.168.") || endpoint.contains("10.") || endpoint.contains("172.16.") {
            return 1
        }
        return 2
    }

    private func httpToWebSocket(_ httpURL: String) -> String {
        let base = httpURL.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let scheme = httpURL.hasPrefix("https://") ? "wss" : "ws"
        return "\(scheme)://\(base)/ws"
    }
}

/// Owns a bounded set of session-bound WebSockets. Connections that are actively
/// running an agent or waiting for human interaction are pinned and never evicted.
private actor HostedAgentConnectionPool {
    private struct Entry {
        let connection: HostedAgentConnection
        var activeLeases: Int
        var lastUsedAt: Date
    }

    private struct Lease {
        let key: HostedAgentConnectionKey
        let connection: HostedAgentConnection
    }

    private let identityStore: IdentityStore
    private let session: URLSession
    private let maximumSize: Int
    private let idleLifetime: TimeInterval
    private let discovery: HostedAgentDiscovery
    private let connectionStateObserver: HostedAgentConnectionStateObserver

    private var connections: [HostedAgentConnectionKey: Entry] = [:]
    private var cleanupTask: Task<Void, Never>?

    init(
        identityStore: IdentityStore,
        session: URLSession,
        maximumSize: Int,
        idleLifetime: TimeInterval,
        discovery: HostedAgentDiscovery,
        connectionStateObserver: HostedAgentConnectionStateObserver
    ) {
        self.identityStore = identityStore
        self.session = session
        self.maximumSize = max(1, maximumSize)
        self.idleLifetime = max(1, idleLifetime)
        self.discovery = discovery
        self.connectionStateObserver = connectionStateObserver
    }

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult {
        let lease = await acquire(agentAddress: agentAddress, conversationID: conversation.id)
        do {
            let result = try await lease.connection.ensureConnected(conversation: conversation)
            release(lease)
            await trimToSize()
            return result
        } catch {
            release(lease)
            await trimToSize()
            throw error
        }
    }

    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onApprovalRequest: (@MainActor (ToolApprovalRequest) async -> ApprovalDecision)?,
        onUlwCheckpoint: (@MainActor (UlwCheckpointRequest) async -> UlwCheckpointDecision)?,
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?,
        onAskUser: (@MainActor (AskUserRequest) async -> AskUserDecision)?
    ) async throws -> HostedAgentResult {
        let lease = await acquire(agentAddress: agentAddress, conversationID: conversation.id)
        do {
            let result = try await lease.connection.sendPrompt(
                conversation: conversation,
                prompt: prompt,
                onEvent: onEvent,
                onApprovalRequest: onApprovalRequest,
                onUlwCheckpoint: onUlwCheckpoint,
                onPlanReview: onPlanReview,
                onAskUser: onAskUser
            )
            release(lease)
            await trimToSize()
            return result
        } catch {
            release(lease)
            await trimToSize()
            throw error
        }
    }

    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async {
        let key = HostedAgentConnectionKey(agentAddress: agentAddress, conversationID: conversationID)
        guard let connection = connections[key]?.connection else {
            return
        }
        await connection.waitForPendingInteractionResponses()
    }

    func closeAll() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        let activeConnections = connections.values.map(\.connection)
        connections.removeAll()
        for connection in activeConnections {
            await connection.close()
        }
    }

    private func acquire(agentAddress: String, conversationID: String) async -> Lease {
        startCleanupTaskIfNeeded()
        await evictExpiredConnections()

        let key = HostedAgentConnectionKey(agentAddress: agentAddress, conversationID: conversationID)
        if var entry = connections[key] {
            entry.activeLeases += 1
            entry.lastUsedAt = Date()
            connections[key] = entry
            return Lease(key: key, connection: entry.connection)
        }

        while connections.count >= maximumSize, await evictLeastRecentlyUsedIdleConnection() {}

        let connection = HostedAgentConnection(
            key: key,
            identityStore: identityStore,
            session: session,
            discovery: discovery,
            connectionStateObserver: connectionStateObserver
        )
        connections[key] = Entry(connection: connection, activeLeases: 1, lastUsedAt: Date())
        return Lease(key: key, connection: connection)
    }

    private func release(_ lease: Lease) {
        guard var entry = connections[lease.key], entry.connection === lease.connection else {
            return
        }
        entry.activeLeases = max(0, entry.activeLeases - 1)
        entry.lastUsedAt = Date()
        connections[lease.key] = entry
    }

    private func startCleanupTaskIfNeeded() {
        guard cleanupTask == nil else {
            return
        }
        let interval = min(30, max(1, idleLifetime / 2))
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                await self?.evictExpiredConnections()
            }
        }
    }

    private func evictExpiredConnections() async {
        let cutoff = Date().addingTimeInterval(-idleLifetime)
        let expiredKeys = connections.compactMap { key, entry in
            entry.activeLeases == 0 && entry.lastUsedAt < cutoff ? key : nil
        }
        let expiredConnections = expiredKeys.compactMap { key in
            connections.removeValue(forKey: key)?.connection
        }
        for connection in expiredConnections {
            await connection.close()
        }
    }

    @discardableResult
    private func evictLeastRecentlyUsedIdleConnection() async -> Bool {
        var candidate: (key: HostedAgentConnectionKey, entry: Entry)?
        for (key, entry) in connections {
            guard entry.activeLeases == 0 else {
                continue
            }
            if candidate == nil || entry.lastUsedAt < candidate!.entry.lastUsedAt {
                candidate = (key, entry)
            }
        }
        guard let candidate,
              let removed = connections.removeValue(forKey: candidate.key),
              removed.connection === candidate.entry.connection else {
            return false
        }
        await removed.connection.close()
        return true
    }

    private func trimToSize() async {
        while connections.count > maximumSize {
            guard await evictLeastRecentlyUsedIdleConnection() else {
                return
            }
        }
    }
}

private actor HostedAgentConnection {
    private enum State: Equatable {
        case disconnected
        case connecting
        case connected
    }

    private struct PendingPrompt {
        let id: UUID
        let continuation: CheckedContinuation<HostedAgentResult, Error>
        let onEvent: (@MainActor (HostedAgentEvent) -> Void)?
        let onApprovalRequest: (@MainActor (ToolApprovalRequest) async -> ApprovalDecision)?
        let onUlwCheckpoint: (@MainActor (UlwCheckpointRequest) async -> UlwCheckpointDecision)?
        let onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?
        let onAskUser: (@MainActor (AskUserRequest) async -> AskUserDecision)?
    }

    private let key: HostedAgentConnectionKey
    private let identityStore: IdentityStore
    private let session: URLSession
    private let discovery: HostedAgentDiscovery
    private let connectionStateObserver: HostedAgentConnectionStateObserver
    private let connectTimeout: TimeInterval = 45
    private let livenessTimeout: TimeInterval = 75

    private var state: State = .disconnected
    private var socket: URLSessionWebSocketTask?
    private var endpoint: ResolvedEndpoint?
    private var receiveTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var interactionTasks: [UUID: Task<Void, Never>] = [:]
    private var socketGeneration = 0
    private var connectWaiters: [UUID: CheckedContinuation<HostedAgentResult, Error>] = [:]
    private var pendingPrompt: PendingPrompt?
    private var serverSession: [String: JSONValue]?
    private var connectionStatus: String?
    private var lastNetworkActivityAt = Date()

    init(
        key: HostedAgentConnectionKey,
        identityStore: IdentityStore,
        session: URLSession,
        discovery: HostedAgentDiscovery,
        connectionStateObserver: HostedAgentConnectionStateObserver
    ) {
        self.key = key
        self.identityStore = identityStore
        self.session = session
        self.discovery = discovery
        self.connectionStateObserver = connectionStateObserver
    }

    func ensureConnected(conversation: Conversation) async throws -> HostedAgentResult {
        if state == .connected, socket != nil, let endpoint {
            return HostedAgentResult(output: nil, endpointLabel: endpoint.label, serverSession: serverSession)
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connectWaiters[waiterID] = continuation
                guard state != .connecting else {
                    return
                }
                setState(.connecting)
                serverSession = sessionPayload(for: conversation)
                socketGeneration += 1
                let generation = socketGeneration
                Task { [weak self] in
                    await self?.openConnection(conversation: conversation, generation: generation)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelConnectWaiter(waiterID)
            }
        }
    }

    func sendPrompt(
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onApprovalRequest: (@MainActor (ToolApprovalRequest) async -> ApprovalDecision)?,
        onUlwCheckpoint: (@MainActor (UlwCheckpointRequest) async -> UlwCheckpointDecision)?,
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?,
        onAskUser: (@MainActor (AskUserRequest) async -> AskUserDecision)?
    ) async throws -> HostedAgentResult {
        try Task.checkCancellation()
        _ = try await ensureConnected(conversation: conversation)
        try Task.checkCancellation()
        guard pendingPrompt == nil else {
            throw HostedAgentClientError.busy
        }

        let promptID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingPrompt = PendingPrompt(
                    id: promptID,
                    continuation: continuation,
                    onEvent: onEvent,
                    onApprovalRequest: onApprovalRequest,
                    onUlwCheckpoint: onUlwCheckpoint,
                    onPlanReview: onPlanReview,
                    onAskUser: onAskUser
                )
                guard !Task.isCancelled else {
                    disconnect(with: CancellationError(), closeCode: .goingAway)
                    return
                }
                Task { [weak self] in
                    await self?.transmitPrompt(prompt, conversation: conversation, promptID: promptID)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPrompt(promptID)
            }
        }
    }

    func close() {
        disconnect(with: HostedAgentClientError.closed, closeCode: .goingAway)
    }

    func waitForPendingInteractionResponses() async {
        let tasks = Array(interactionTasks.values)
        for task in tasks {
            await task.value
        }
    }

    private func openConnection(conversation: Conversation, generation: Int) async {
        scheduleConnectTimeout(generation: generation)
        do {
            let endpoint = try await resolveEndpoint(agentAddress: key.agentAddress)
            guard state == .connecting, generation == socketGeneration else {
                return
            }

            self.endpoint = endpoint
            let socket = session.webSocketTask(with: endpoint.wsURL)
            self.socket = socket
            lastNetworkActivityAt = Date()
            socket.resume()
            startReceiveLoop(socket: socket, generation: generation)
            startLivenessMonitor(generation: generation)

            let connectFrame = try buildConnectFrame(conversation: conversation)
            try await send(connectFrame, over: socket)
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func startReceiveLoop(socket: URLSessionWebSocketTask, generation: Int) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await Self.readFrame(from: socket)
                    guard let self else {
                        return
                    }
                    await self.handle(frame, generation: generation)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else {
                        return
                    }
                    await self.failConnection(error, generation: generation)
                    return
                }
            }
        }
    }

    private func scheduleConnectTimeout(generation: Int) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64((self?.connectTimeout ?? 45) * 1_000_000_000))
            } catch {
                return
            }
            await self?.failConnection(HostedAgentClientError.timeout, generation: generation)
        }
    }

    private func startLivenessMonitor(generation: Int) {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                if await self.hasTimedOut(generation: generation) {
                    await self.failConnection(HostedAgentClientError.timeout, generation: generation)
                    return
                }
            }
        }
    }

    private func hasTimedOut(generation: Int) -> Bool {
        generation == socketGeneration
            && Date().timeIntervalSince(lastNetworkActivityAt) > livenessTimeout
    }

    private func transmitPrompt(_ prompt: String, conversation: Conversation, promptID: UUID) async {
        let generation = socketGeneration
        guard pendingPrompt?.id == promptID, let socket else {
            return
        }
        do {
            let inputFrame = try buildInputFrame(prompt: prompt, conversation: conversation)
            try await send(inputFrame, over: socket)
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func cancelConnectWaiter(_ waiterID: UUID) {
        guard let waiter = connectWaiters.removeValue(forKey: waiterID) else {
            return
        }
        waiter.resume(throwing: CancellationError())
        if connectWaiters.isEmpty, state == .connecting {
            disconnect(with: CancellationError(), closeCode: .goingAway)
        }
    }

    private func cancelPrompt(_ promptID: UUID) {
        guard pendingPrompt?.id == promptID else {
            return
        }
        disconnect(with: CancellationError(), closeCode: .goingAway)
    }

    private func handle(_ frame: [String: JSONValue], generation: Int) async {
        guard generation == socketGeneration else {
            return
        }
        lastNetworkActivityAt = Date()

        switch frame["type"]?.stringValue {
        case "PING":
            guard let socket else {
                return
            }
            do {
                try await send(["type": .string("PONG")], over: socket)
            } catch {
                failConnection(error, generation: generation)
            }
        case "CONNECTED":
            updateServerSession(from: frame)
            connectionStatus = frame["status"]?.stringValue
            setState(.connected)
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            let result = HostedAgentResult(
                output: nil,
                endpointLabel: endpoint?.label ?? key.agentAddress,
                serverSession: serverSession
            )
            let waiters = Array(connectWaiters.values)
            connectWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: result)
            }
        case "OUTPUT":
            updateServerSession(from: frame)
            connectionStatus = "connected"
            guard let pending = pendingPrompt else {
                return
            }
            pendingPrompt = nil
            cancelInteractionTasks()
            pending.continuation.resume(
                returning: HostedAgentResult(
                    output: messageText(frame),
                    endpointLabel: endpoint?.label ?? key.agentAddress,
                    serverSession: serverSession
                )
            )
        case "tool_call", "tool_result", "mode_changed":
            guard let pending = pendingPrompt, let event = HostedAgentEvent.from(frame) else {
                return
            }
            await pending.onEvent?(event)
        case "approval_needed", "APPROVAL_NEEDED":
            guard let pending = pendingPrompt,
                  let request = ToolApprovalRequest.from(frame) else {
                failConnection(HostedAgentClientError.badFrame, generation: generation)
                return
            }
            startApprovalTask(request: request, promptID: pending.id, generation: generation)
        case "ulw_turns_reached":
            guard let pending = pendingPrompt,
                  let request = UlwCheckpointRequest.from(frame) else {
                failConnection(HostedAgentClientError.badFrame, generation: generation)
                return
            }
            startUlwCheckpointTask(request: request, promptID: pending.id, generation: generation)
        case "plan_review":
            guard let pending = pendingPrompt,
                  let request = PlanReviewRequest.from(frame) else {
                failConnection(HostedAgentClientError.badFrame, generation: generation)
                return
            }
            startPlanReviewTask(request: request, promptID: pending.id, generation: generation)
        case "ask_user":
            guard let pending = pendingPrompt,
                  let request = AskUserRequest.from(frame) else {
                failConnection(HostedAgentClientError.badFrame, generation: generation)
                return
            }
            startAskUserTask(request: request, promptID: pending.id, generation: generation)
        case "ERROR":
            failConnection(
                HostedAgentClientError.server(messageText(frame)),
                generation: generation
            )
        default:
            break
        }
    }

    private func startApprovalTask(request: ToolApprovalRequest, promptID: UUID, generation: Int) {
        let taskID = UUID()
        interactionTasks[taskID] = Task { [weak self] in
            await self?.processApproval(
                request: request,
                promptID: promptID,
                generation: generation,
                taskID: taskID
            )
        }
    }

    private func processApproval(
        request: ToolApprovalRequest,
        promptID: UUID,
        generation: Int,
        taskID: UUID
    ) async {
        defer {
            interactionTasks.removeValue(forKey: taskID)
        }
        guard generation == socketGeneration,
              let pending = pendingPrompt,
              pending.id == promptID else {
            return
        }
        let decision = await pending.onApprovalRequest?(request)
            ?? .rejectHard(feedback: "Approval unavailable.")
        guard generation == socketGeneration,
              pendingPrompt?.id == promptID,
              let socket,
              let endpoint else {
            return
        }
        do {
            try await send(
                HostedAgentClient.approvalResponseFrame(
                    decision: decision,
                    agentAddress: key.agentAddress,
                    endpoint: endpoint
                ),
                over: socket
            )
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func startUlwCheckpointTask(request: UlwCheckpointRequest, promptID: UUID, generation: Int) {
        let taskID = UUID()
        interactionTasks[taskID] = Task { [weak self] in
            await self?.processUlwCheckpoint(
                request: request,
                promptID: promptID,
                generation: generation,
                taskID: taskID
            )
        }
    }

    private func processUlwCheckpoint(
        request: UlwCheckpointRequest,
        promptID: UUID,
        generation: Int,
        taskID: UUID
    ) async {
        defer {
            interactionTasks.removeValue(forKey: taskID)
        }
        guard generation == socketGeneration,
              let pending = pendingPrompt,
              pending.id == promptID else {
            return
        }
        let decision = await pending.onUlwCheckpoint?(request) ?? .switchMode(.safe)
        guard generation == socketGeneration,
              pendingPrompt?.id == promptID,
              let socket,
              let endpoint else {
            return
        }
        do {
            try await send(
                HostedAgentClient.ulwResponseFrame(
                    decision: decision,
                    agentAddress: key.agentAddress,
                    endpoint: endpoint
                ),
                over: socket
            )
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func startPlanReviewTask(request: PlanReviewRequest, promptID: UUID, generation: Int) {
        let taskID = UUID()
        interactionTasks[taskID] = Task { [weak self] in
            await self?.processPlanReview(
                request: request,
                promptID: promptID,
                generation: generation,
                taskID: taskID
            )
        }
    }

    private func processPlanReview(
        request: PlanReviewRequest,
        promptID: UUID,
        generation: Int,
        taskID: UUID
    ) async {
        defer {
            interactionTasks.removeValue(forKey: taskID)
        }
        guard generation == socketGeneration,
              let pending = pendingPrompt,
              pending.id == promptID else {
            return
        }
        let decision = await pending.onPlanReview?(request)
            ?? .requestChanges(feedback: "Plan review unavailable.")
        guard generation == socketGeneration,
              pendingPrompt?.id == promptID,
              let socket,
              let endpoint else {
            return
        }
        do {
            try await send(
                HostedAgentClient.planReviewResponseFrame(
                    decision: decision,
                    request: request,
                    agentAddress: key.agentAddress,
                    endpoint: endpoint
                ),
                over: socket
            )
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func startAskUserTask(request: AskUserRequest, promptID: UUID, generation: Int) {
        let taskID = UUID()
        interactionTasks[taskID] = Task { [weak self] in
            await self?.processAskUser(
                request: request,
                promptID: promptID,
                generation: generation,
                taskID: taskID
            )
        }
    }

    private func processAskUser(
        request: AskUserRequest,
        promptID: UUID,
        generation: Int,
        taskID: UUID
    ) async {
        defer {
            interactionTasks.removeValue(forKey: taskID)
        }
        guard generation == socketGeneration,
              let pending = pendingPrompt,
              pending.id == promptID else {
            return
        }
        let decision = await pending.onAskUser?(request) ?? .cancel
        guard case .answer(let answer) = decision else {
            return
        }
        guard generation == socketGeneration,
              pendingPrompt?.id == promptID,
              let socket,
              let endpoint else {
            return
        }
        do {
            try await send(
                HostedAgentClient.askUserResponseFrame(
                    answer: answer,
                    agentAddress: key.agentAddress,
                    endpoint: endpoint
                ),
                over: socket
            )
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func cancelInteractionTasks() {
        let tasks = Array(interactionTasks.values)
        interactionTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func updateServerSession(from frame: [String: JSONValue]) {
        if case .object(let session)? = frame["session"] {
            serverSession = session
        }
        if let sessionID = frame["session_id"]?.stringValue {
            var updated = serverSession ?? [:]
            updated["session_id"] = .string(sessionID)
            serverSession = updated
        }
    }

    private func failConnection(_ error: Error, generation: Int) {
        guard generation == socketGeneration else {
            return
        }
        disconnect(with: normalizedConnectionError(error), closeCode: .goingAway)
    }

    private func disconnect(with error: Error, closeCode: URLSessionWebSocketTask.CloseCode) {
        socketGeneration += 1
        setState(.disconnected)
        connectionStatus = nil

        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        cancelInteractionTasks()

        let socket = socket
        self.socket = nil
        endpoint = nil
        socket?.cancel(with: closeCode, reason: nil)

        let waiters = Array(connectWaiters.values)
        connectWaiters.removeAll()
        let pending = pendingPrompt
        pendingPrompt = nil

        for waiter in waiters {
            waiter.resume(throwing: error)
        }
        pending?.continuation.resume(throwing: error)
    }

    private func setState(_ newState: State) {
        guard state != newState else {
            return
        }
        state = newState
        let publicState: ConnectionState
        switch newState {
        case .disconnected:
            publicState = .disconnected
        case .connecting:
            publicState = .reconnecting
        case .connected:
            publicState = .connected
        }
        connectionStateObserver.notify(conversationID: key.conversationID, state: publicState)
    }

    private func normalizedConnectionError(_ error: Error) -> Error {
        if error is CancellationError || error is HostedAgentClientError {
            return error
        }
        return HostedAgentClientError.closed
    }

    private func resolveEndpoint(agentAddress: String) async throws -> ResolvedEndpoint {
        try await discovery.discover(agentAddress: agentAddress).endpoint
    }

    private func buildConnectFrame(conversation: Conversation) throws -> [String: JSONValue] {
        let timestamp = Double(Int(Date().timeIntervalSince1970))
        let session = sessionPayload(for: conversation)
        let payload = HostedAgentClient.connectSignaturePayload(
            agentAddress: key.agentAddress,
            conversationID: conversation.id,
            session: session,
            timestamp: timestamp
        )
        var frame = try identityStore.signedEnvelope(type: "CONNECT", payload: payload)
        frame["to"] = .string(key.agentAddress)
        frame["session_id"] = .string(conversation.id)
        frame["session"] = .object(session)
        return frame
    }

    private func sessionPayload(for conversation: Conversation) -> [String: JSONValue] {
        var session = conversation.serverSession ?? [:]
        session["session_id"] = .string(conversation.id)
        session["mode"] = .string(conversation.mode.rawValue)
        session.removeValue(forKey: "skip_tool_approval")
        session.removeValue(forKey: "ulw_turns")
        session.removeValue(forKey: "ulw_turns_used")
        session.removeValue(forKey: "ulw_prompt")
        return session
    }

    private func buildInputFrame(prompt: String, conversation: Conversation) throws -> [String: JSONValue] {
        let timestamp = Double(Int(Date().timeIntervalSince1970))
        let inputID = UUID().uuidString
        let payload = HostedAgentClient.inputSignaturePayload(
            agentAddress: key.agentAddress,
            conversationID: conversation.id,
            inputID: inputID,
            prompt: prompt,
            mode: conversation.mode,
            timestamp: timestamp
        )
        var frame = try identityStore.signedEnvelope(type: "INPUT", payload: payload)
        frame["to"] = .string(key.agentAddress)
        frame["session_id"] = .string(conversation.id)
        frame["input_id"] = .string(inputID)
        frame["prompt"] = .string(prompt)
        frame["mode"] = .string(conversation.mode.rawValue)
        return frame
    }

    private func send(_ frame: [String: JSONValue], over socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostedAgentClientError.badFrame
        }
        try await socket.send(.string(text))
        guard self.socket === socket else {
            throw HostedAgentClientError.closed
        }
        lastNetworkActivityAt = Date()
    }

    private static func readFrame(from socket: URLSessionWebSocketTask) async throws -> [String: JSONValue] {
        let message = try await socket.receive()
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                throw HostedAgentClientError.badFrame
            }
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        case .data(let data):
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        @unknown default:
            throw HostedAgentClientError.badFrame
        }
    }

    private func messageText(_ frame: [String: JSONValue]) -> String {
        for key in ["result", "message", "error", "text", "content"] {
            if let value = frame[key]?.stringValue {
                return value
            }
        }
        return "Hosted agent returned \(frame["type"]?.stringValue ?? "an event")."
    }
}
