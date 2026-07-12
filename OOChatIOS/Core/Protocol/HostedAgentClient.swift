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

    static func from(_ frame: [String: JSONValue]) -> HostedAgentEvent? {
        guard let type = frame["type"]?.stringValue,
              let id = frame["tool_id"]?.stringValue ?? frame["id"]?.stringValue,
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

/// Wire-level operations the view model needs from the hosted-agent client,
/// as a protocol so tests can substitute a scripted transport.
protocol HostedAgentTransport {
    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult
    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onApprovalRequest: (@MainActor (ToolApprovalRequest) async -> ApprovalDecision)?,
        onUlwCheckpoint: (@MainActor (UlwCheckpointRequest) async -> UlwCheckpointDecision)?,
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?
    ) async throws -> HostedAgentResult
}

final class HostedAgentClient: HostedAgentTransport {
    private let connectionPool: HostedAgentConnectionPool
    private let identityStore: IdentityStore
    private let session: URLSession
    private let relayURL = "wss://oo.openonion.ai"
    private let localEndpoints = ["http://localhost:8000", "http://127.0.0.1:8000"]

    init(
        identityStore: IdentityStore,
        session: URLSession = .shared,
        poolSize: Int = 3,
        connectionIdleLifetime: TimeInterval = 5 * 60
    ) {
        connectionPool = HostedAgentConnectionPool(
            identityStore: identityStore,
            session: session,
            maximumSize: poolSize,
            idleLifetime: connectionIdleLifetime,
            relayURL: "wss://oo.openonion.ai",
            localEndpoints: ["http://localhost:8000", "http://127.0.0.1:8000"]
        )
        self.identityStore = identityStore
        self.session = session
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

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        let endpoint = try await resolveEndpoint(agentAddress: agentAddress)
        let socket = session.webSocketTask(with: endpoint.wsURL)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let connectFrame = try buildConnectFrame(agentAddress: agentAddress, conversation: conversation, endpoint: endpoint)
        try await send(connectFrame, over: socket)

        while true {
            let frame = try await receiveFrame(from: socket)
            switch frame["type"]?.stringValue {
            case "PING":
                try await send(["type": .string("PONG")], over: socket)
            case "CONNECTED":
                return HostedAgentResult(output: nil, endpointLabel: endpoint.label, serverSession: extractServerSession(from: frame))
            case "ERROR":
                throw HostedAgentClientError.server(messageText(frame))
            default:
                continue
            }
        }
    }

    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onApprovalRequest: (@MainActor (ToolApprovalRequest) async -> ApprovalDecision)?,
        onUlwCheckpoint: (@MainActor (UlwCheckpointRequest) async -> UlwCheckpointDecision)?,
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?
    ) async throws -> HostedAgentResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        let endpoint = try await resolveEndpoint(agentAddress: agentAddress)
        let socket = session.webSocketTask(with: endpoint.wsURL)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let connectFrame = try buildConnectFrame(agentAddress: agentAddress, conversation: conversation, endpoint: endpoint)
        try await send(connectFrame, over: socket)

        var inputSent = false
        var serverSession = conversation.serverSession
        while true {
            let frame = try await receiveFrame(from: socket)
            switch frame["type"]?.stringValue {
            case "PING":
                try await send(["type": .string("PONG")], over: socket)
            case "CONNECTED":
                if let session = extractServerSession(from: frame) {
                    serverSession = session
                }
                if !inputSent {
                    inputSent = true
                    if let modeChange = Self.pendingModeChangeFrame(
                        for: conversation,
                        connectionStatus: frame["status"]?.stringValue
                    ) {
                        try await send(modeChange, over: socket)
                    }
                    let inputFrame = try buildInputFrame(agentAddress: agentAddress, prompt: prompt, endpoint: endpoint)
                    try await send(inputFrame, over: socket)
                }
            case "OUTPUT":
                if let session = extractServerSession(from: frame) {
                    serverSession = session
                }
                return HostedAgentResult(output: messageText(frame), endpointLabel: endpoint.label, serverSession: serverSession)
            case "tool_call", "tool_result":
                if let event = HostedAgentEvent.from(frame) {
                    await onEvent?(event)
                }
            case "approval_needed", "APPROVAL_NEEDED":
                guard let request = ToolApprovalRequest.from(frame) else {
                    throw HostedAgentClientError.badFrame
                }
                let decision = await onApprovalRequest?(request)
                    ?? .rejectHard(feedback: "Approval unavailable.")
                try await send(
                    Self.approvalResponseFrame(
                        decision: decision,
                        agentAddress: agentAddress,
                        endpoint: endpoint
                    ),
                    over: socket
                )
            case "ulw_turns_reached":
                guard let request = UlwCheckpointRequest.from(frame) else {
                    throw HostedAgentClientError.badFrame
                }
                let decision = await onUlwCheckpoint?(request) ?? .switchMode(.safe)
                try await send(
                    Self.ulwResponseFrame(
                        decision: decision,
                        agentAddress: agentAddress,
                        endpoint: endpoint
                    ),
                    over: socket
                )
            case "plan_review":
                guard let request = PlanReviewRequest.from(frame) else {
                    throw HostedAgentClientError.badFrame
                }
                let decision = await onPlanReview?(request)
                    ?? .requestChanges(feedback: "Plan review unavailable.")
                try await send(
                    Self.planReviewResponseFrame(
                        decision: decision,
                        request: request,
                        agentAddress: agentAddress,
                        endpoint: endpoint
                    ),
                    over: socket
                )
            case "ERROR":
                throw HostedAgentClientError.server(messageText(frame))
            case "ask_user":
                throw HostedAgentClientError.server(messageText(frame))
            default:
                continue
            }
        }
    }

    static func approvalResponseFrame(
        decision: ApprovalDecision,
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        let recipient = endpoint.kind == .relay ? agentAddress : nil
        return decision.responseFrame(to: recipient)
    }

    static func pendingModeChangeFrame(
        for conversation: Conversation,
        connectionStatus: String?
    ) -> [String: JSONValue]? {
        guard connectionStatus == "running",
              let rawMode = conversation.serverSession?[ClientSessionMetadata.pendingModeChange]?.stringValue,
              let mode = ChatMode(rawValue: rawMode) else {
            return nil
        }
        var frame: [String: JSONValue] = [
            "type": .string("mode_change"),
            "mode": .string(mode.rawValue),
        ]
        if mode == .ulw {
            frame["turns"] = conversation.serverSession?["ulw_turns"] ?? .number(100)
        }
        return frame
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

    private func resolveEndpoint(agentAddress: String) async throws -> ResolvedEndpoint {
        for httpURL in localEndpoints {
            if let endpoint = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 1.2) {
                return endpoint
            }
        }

        let normalizedRelay = relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relayHTTP = normalizedRelay.replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        if let url = URL(string: "\(relayHTTP)/api/relay/agents/\(agentAddress)"),
           let relayInfo: AgentInfo = try? await fetchJSON(url: url, timeout: 3.0) {
            for httpURL in sortByProximity(relayInfo.endpoints ?? []) where httpURL.hasPrefix("http") {
                if let endpoint = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 2.5) {
                    return endpoint
                }
            }
        }

        guard let relaySocketURL = URL(string: "\(normalizedRelay)/ws/input") else {
            throw HostedAgentClientError.invalidURL("\(normalizedRelay)/ws/input")
        }
        return ResolvedEndpoint(wsURL: relaySocketURL, kind: .relay, label: normalizedRelay)
    }

    private func probe(httpURL: String, agentAddress: String, timeout: TimeInterval) async throws -> ResolvedEndpoint? {
        guard let url = URL(string: "\(httpURL)/info") else {
            return nil
        }
        guard let info: AgentInfo = try? await fetchJSON(url: url, timeout: timeout), info.address == agentAddress else {
            return nil
        }
        guard let wsURL = URL(string: httpToWebSocket(httpURL)) else {
            throw HostedAgentClientError.invalidURL(httpURL)
        }
        return ResolvedEndpoint(wsURL: wsURL, kind: .direct, label: info.name.map { "\($0) at \(httpURL)" } ?? httpURL)
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

    private func buildConnectFrame(agentAddress: String, conversation: Conversation, endpoint: ResolvedEndpoint) throws -> [String: JSONValue] {
        let timestamp = Double(Int(Date().timeIntervalSince1970))
        let payload: [String: JSONValue] = [
            "timestamp": .number(timestamp),
            "to": .string(agentAddress),
        ]
        var frame = try identityStore.signedEnvelope(type: "CONNECT", payload: payload)
        frame["session_id"] = .string(conversation.id)
        frame["session"] = .object(sessionPayload(for: conversation))
        if endpoint.kind == .relay {
            frame["to"] = .string(agentAddress)
        }
        return frame
    }

    private func sessionPayload(for conversation: Conversation) -> [String: JSONValue] {
        var session = conversation.serverSession ?? [:]
        session.removeValue(forKey: ClientSessionMetadata.pendingModeChange)
        session["session_id"] = .string(conversation.id)
        session["mode"] = .string(conversation.mode.rawValue)
        if conversation.mode == .ulw {
            session["skip_tool_approval"] = .bool(true)
            if session["ulw_turns"] == nil {
                session["ulw_turns"] = .number(100)
            }
            if session["ulw_turns_used"] == nil {
                session["ulw_turns_used"] = .number(0)
            }
        } else {
            session.removeValue(forKey: "skip_tool_approval")
            session.removeValue(forKey: "ulw_turns")
            session.removeValue(forKey: "ulw_turns_used")
        }
        return session
    }

    private func buildInputFrame(agentAddress: String, prompt: String, endpoint: ResolvedEndpoint) throws -> [String: JSONValue] {
        let timestamp = Double(Int(Date().timeIntervalSince1970))
        var payload: [String: JSONValue] = [
            "prompt": .string(prompt),
            "timestamp": .number(timestamp),
        ]
        if endpoint.kind == .relay {
            payload["to"] = .string(agentAddress)
        }
        var frame = try identityStore.signedEnvelope(type: "INPUT", payload: payload)
        frame["input_id"] = .string(UUID().uuidString)
        frame["prompt"] = .string(prompt)
        if endpoint.kind == .relay {
            frame["to"] = .string(agentAddress)
        }
        return frame
    }

    private func extractServerSession(from frame: [String: JSONValue]) -> [String: JSONValue]? {
        if case .object(let session)? = frame["session"] {
            return session
        }
        return nil
    }

    private func send(_ frame: [String: JSONValue], over socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostedAgentClientError.badFrame
        }
        try await socket.send(.string(text))
    }

    private func receiveFrame(from socket: URLSessionWebSocketTask, timeout: TimeInterval = 45.0) async throws -> [String: JSONValue] {
        try await withThrowingTaskGroup(of: [String: JSONValue].self) { group in
            group.addTask {
                try await self.readFrame(from: socket)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw HostedAgentClientError.timeout
            }

            guard let frame = try await group.next() else {
                throw HostedAgentClientError.closed
            }
            group.cancelAll()
            return frame
        }
    }

    private func readFrame(from socket: URLSessionWebSocketTask) async throws -> [String: JSONValue] {
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

private struct HostedAgentConnectionKey: Hashable {
    let agentAddress: String
    let conversationID: String
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
    private let relayURL: String
    private let localEndpoints: [String]

    private var connections: [HostedAgentConnectionKey: Entry] = [:]
    private var cleanupTask: Task<Void, Never>?

    init(
        identityStore: IdentityStore,
        session: URLSession,
        maximumSize: Int,
        idleLifetime: TimeInterval,
        relayURL: String,
        localEndpoints: [String]
    ) {
        self.identityStore = identityStore
        self.session = session
        self.maximumSize = max(1, maximumSize)
        self.idleLifetime = max(1, idleLifetime)
        self.relayURL = relayURL
        self.localEndpoints = localEndpoints
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
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?
    ) async throws -> HostedAgentResult {
        let lease = await acquire(agentAddress: agentAddress, conversationID: conversation.id)
        do {
            let result = try await lease.connection.sendPrompt(
                conversation: conversation,
                prompt: prompt,
                onEvent: onEvent,
                onApprovalRequest: onApprovalRequest,
                onUlwCheckpoint: onUlwCheckpoint,
                onPlanReview: onPlanReview
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
            relayURL: relayURL,
            localEndpoints: localEndpoints
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
    private enum State {
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
    }

    private let key: HostedAgentConnectionKey
    private let identityStore: IdentityStore
    private let session: URLSession
    private let relayURL: String
    private let localEndpoints: [String]
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
        relayURL: String,
        localEndpoints: [String]
    ) {
        self.key = key
        self.identityStore = identityStore
        self.session = session
        self.relayURL = relayURL
        self.localEndpoints = localEndpoints
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
                state = .connecting
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
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?
    ) async throws -> HostedAgentResult {
        try Task.checkCancellation()
        reconnectToApplyPendingModeChangeIfNeeded(conversation: conversation)
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
                    onPlanReview: onPlanReview
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

            let connectFrame = try buildConnectFrame(conversation: conversation, endpoint: endpoint)
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
        guard pendingPrompt?.id == promptID, let socket, let endpoint else {
            return
        }
        do {
            if let modeChange = HostedAgentClient.pendingModeChangeFrame(
                for: conversation,
                connectionStatus: connectionStatus
            ) {
                try await send(modeChange, over: socket)
            }
            let inputFrame = try buildInputFrame(prompt: prompt, endpoint: endpoint)
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
            state = .connected
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
        case "tool_call", "tool_result":
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
        case "ERROR", "ask_user":
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

    private func reconnectToApplyPendingModeChangeIfNeeded(conversation: Conversation) {
        guard conversation.serverSession?[ClientSessionMetadata.pendingModeChange] != nil,
              state == .connected,
              pendingPrompt == nil else {
            return
        }
        disconnect(with: HostedAgentClientError.closed, closeCode: .normalClosure)
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
        state = .disconnected
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

    private func normalizedConnectionError(_ error: Error) -> Error {
        if error is CancellationError || error is HostedAgentClientError {
            return error
        }
        return HostedAgentClientError.closed
    }

    private func resolveEndpoint(agentAddress: String) async throws -> ResolvedEndpoint {
        for httpURL in localEndpoints {
            if let endpoint = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 1.2) {
                return endpoint
            }
        }

        let normalizedRelay = relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relayHTTP = normalizedRelay.replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        if let url = URL(string: "\(relayHTTP)/api/relay/agents/\(agentAddress)"),
           let relayInfo: AgentInfo = try? await fetchJSON(url: url, timeout: 3.0) {
            for httpURL in sortByProximity(relayInfo.endpoints ?? []) where httpURL.hasPrefix("http") {
                if let endpoint = try await probe(httpURL: httpURL, agentAddress: agentAddress, timeout: 2.5) {
                    return endpoint
                }
            }
        }

        guard let relaySocketURL = URL(string: "\(normalizedRelay)/ws/input") else {
            throw HostedAgentClientError.invalidURL("\(normalizedRelay)/ws/input")
        }
        return ResolvedEndpoint(wsURL: relaySocketURL, kind: .relay, label: normalizedRelay)
    }

    private func probe(httpURL: String, agentAddress: String, timeout: TimeInterval) async throws -> ResolvedEndpoint? {
        guard let url = URL(string: "\(httpURL)/info") else {
            return nil
        }
        guard let info: AgentInfo = try? await fetchJSON(url: url, timeout: timeout), info.address == agentAddress else {
            return nil
        }
        guard let wsURL = URL(string: httpToWebSocket(httpURL)) else {
            throw HostedAgentClientError.invalidURL(httpURL)
        }
        return ResolvedEndpoint(wsURL: wsURL, kind: .direct, label: info.name.map { "\($0) at \(httpURL)" } ?? httpURL)
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

    private func buildConnectFrame(conversation: Conversation, endpoint: ResolvedEndpoint) throws -> [String: JSONValue] {
        let timestamp = Double(Int(Date().timeIntervalSince1970))
        let payload: [String: JSONValue] = [
            "timestamp": .number(timestamp),
            "to": .string(key.agentAddress),
        ]
        var frame = try identityStore.signedEnvelope(type: "CONNECT", payload: payload)
        frame["session_id"] = .string(conversation.id)
        frame["session"] = .object(sessionPayload(for: conversation))
        if endpoint.kind == .relay {
            frame["to"] = .string(key.agentAddress)
        }
        return frame
    }

    private func sessionPayload(for conversation: Conversation) -> [String: JSONValue] {
        var session = conversation.serverSession ?? [:]
        session.removeValue(forKey: ClientSessionMetadata.pendingModeChange)
        session["session_id"] = .string(conversation.id)
        session["mode"] = .string(conversation.mode.rawValue)
        if conversation.mode == .ulw {
            session["skip_tool_approval"] = .bool(true)
            if session["ulw_turns"] == nil {
                session["ulw_turns"] = .number(100)
            }
            if session["ulw_turns_used"] == nil {
                session["ulw_turns_used"] = .number(0)
            }
        } else {
            session.removeValue(forKey: "skip_tool_approval")
            session.removeValue(forKey: "ulw_turns")
            session.removeValue(forKey: "ulw_turns_used")
        }
        return session
    }

    private func buildInputFrame(prompt: String, endpoint: ResolvedEndpoint) throws -> [String: JSONValue] {
        let timestamp = Double(Int(Date().timeIntervalSince1970))
        var payload: [String: JSONValue] = [
            "prompt": .string(prompt),
            "timestamp": .number(timestamp),
        ]
        if endpoint.kind == .relay {
            payload["to"] = .string(key.agentAddress)
        }
        var frame = try identityStore.signedEnvelope(type: "INPUT", payload: payload)
        frame["input_id"] = .string(UUID().uuidString)
        frame["prompt"] = .string(prompt)
        if endpoint.kind == .relay {
            frame["to"] = .string(key.agentAddress)
        }
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
