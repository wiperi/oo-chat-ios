import Foundation

struct SessionKey: Hashable {
    let agentAddress: String
    let conversationID: String
}

enum AgentRuntimeState: Equatable {
    case idle
    case resolvingEndpoint
    case connecting
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case waiting
    case suspended
    case closing
    case closed
    case failed(String)

    var connectionState: ConnectionState {
        switch self {
        case .connected:
            return .connected
        case .waiting:
            return .waiting
        case .suspended:
            return .suspended
        case .resolvingEndpoint, .connecting, .authenticating, .reconnecting:
            return .reconnecting
        case .idle, .closing, .closed, .failed:
            return .disconnected
        }
    }
}

enum AgentSessionEvent {
    case stateChanged(SessionKey, AgentRuntimeState)
    case serverSessionUpdated(SessionKey, [String: JSONValue])
    case message(SessionKey, ChatMessage)
    case pendingInteraction(SessionKey, PendingInteraction?)
}

actor AgentRuntimeManager {
    private let client: HostedAgentClient
    private var sessions: [SessionKey: AgentSessionActor] = [:]

    init(client: HostedAgentClient) {
        self.client = client
    }

    func session(for agent: AgentConnection, conversation: Conversation) -> AgentSessionActor {
        let key = SessionKey(agentAddress: agent.address, conversationID: conversation.id)
        if let session = sessions[key] {
            return session
        }

        let session = AgentSessionActor(key: key, agentAddress: agent.address, conversation: conversation, client: client)
        sessions[key] = session
        return session
    }

    func closeSession(agentAddress: String, conversationID: String) async {
        let key = SessionKey(agentAddress: agentAddress, conversationID: conversationID)
        let session = sessions.removeValue(forKey: key)
        await session?.close()
    }

    func closeSessions(agentAddress: String) async {
        let keys = sessions.keys.filter { $0.agentAddress == agentAddress }
        for key in keys {
            let session = sessions.removeValue(forKey: key)
            await session?.close()
        }
    }

    func closeAll() async {
        let allSessions = Array(sessions.values)
        sessions.removeAll()
        for session in allSessions {
            await session.close()
        }
    }

    func suspendAll() async {
        for session in sessions.values {
            await session.suspend()
        }
    }

    func resumeAll() async {
        for session in sessions.values {
            await session.resume()
        }
    }

    func networkBecameUnavailable() async {
        for session in sessions.values {
            await session.pauseForNetworkLoss()
        }
    }
}

actor AgentSessionActor {
    private struct PendingRequest {
        let id: String
        let type: String
        let continuation: CheckedContinuation<HostedAgentResult, Error>
        var sent = false
    }

    private let key: SessionKey
    private let agentAddress: String
    private let client: HostedAgentClient
    private var conversation: Conversation

    private var endpoint: ResolvedEndpoint?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectTask: Task<HostedAgentResult, Error>?
    private var connectTimeoutTask: Task<Void, Never>?

    private var authenticated = false
    private var suspended = false
    private var networkAvailable = true
    private var state: AgentRuntimeState = .idle
    private var reconnectAttempt = 0
    private var lastFrameAt = Date.distantPast
    private var currentServerSession: [String: JSONValue]?

    private var pendingConnect: CheckedContinuation<HostedAgentResult, Error>?
    private var pendingRequest: PendingRequest?
    private var eventContinuations: [UUID: AsyncStream<AgentSessionEvent>.Continuation] = [:]

    init(key: SessionKey, agentAddress: String, conversation: Conversation, client: HostedAgentClient) {
        self.key = key
        self.agentAddress = agentAddress
        self.conversation = conversation
        self.currentServerSession = conversation.serverSession
        self.client = client
    }

    func events() -> AsyncStream<AgentSessionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task {
                await self.addContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeContinuation(id: id)
                }
            }
        }
    }

    func connect(conversation: Conversation) async throws -> HostedAgentResult {
        updateConversation(conversation)
        suspended = false
        networkAvailable = true
        return try await ensureConnected()
    }

    func reconnect(conversation: Conversation) async throws -> HostedAgentResult {
        updateConversation(conversation)
        suspended = false
        networkAvailable = true
        closeSocket()
        return try await ensureConnected()
    }

    func resume() async {
        suspended = false
        networkAvailable = true
        guard socket == nil || !authenticated else {
            setState(.connected)
            return
        }
        do {
            _ = try await ensureConnected()
        } catch {
            handleConnectionError(error)
        }
    }

    func suspend() {
        suspended = true
        failPendingConnect(HostedAgentClientError.closed)
        failPendingRequest(HostedAgentClientError.closed, protectSentRequest: true)
        closeSocket()
        setState(.suspended)
    }

    func pauseForNetworkLoss() {
        networkAvailable = false
        failPendingConnect(HostedAgentClientError.closed)
        failPendingRequest(HostedAgentClientError.closed, protectSentRequest: true)
        closeSocket()
        setState(.closed)
    }

    func close() {
        suspended = true
        setState(.closing)
        failPendingConnect(HostedAgentClientError.closed)
        failPendingRequest(HostedAgentClientError.closed)
        closeSocket()
        setState(.closed)
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    func updateMode(_ mode: ChatMode, conversation: Conversation) async {
        updateConversation(conversation)
        currentServerSession = client.sessionPayload(for: conversation)
        emit(.serverSessionUpdated(key, currentServerSession ?? [:]))

        guard let socket, authenticated else {
            return
        }

        do {
            try await client.send(client.buildModeChangeFrame(mode: mode), over: socket)
        } catch {
            handleDisconnect(error, from: socket)
        }
    }

    func sendPrompt(conversation: Conversation, prompt: String) async throws -> HostedAgentResult {
        updateConversation(conversation)
        let connected = try await ensureConnected()
        guard connected.done else {
            throw HostedAgentClientError.notConnected
        }
        guard pendingRequest == nil else {
            throw HostedAgentClientError.requestInFlight
        }
        guard let socket, let endpoint else {
            throw HostedAgentClientError.notConnected
        }

        let inputID = UUID().uuidString
        let frame = try client.buildInputFrame(
            agentAddress: agentAddress,
            conversationID: conversation.id,
            prompt: prompt,
            endpoint: endpoint,
            inputID: inputID
        )
        return try await sendRequest(frame: frame, socket: socket, id: inputID, type: "INPUT")
    }

    func sendInteractionResponse(
        conversation: Conversation,
        type: String,
        payload: [String: JSONValue]
    ) async throws -> HostedAgentResult {
        updateConversation(conversation)
        if type != "ONBOARD_SUBMIT" {
            let connected = try await ensureConnected()
            guard connected.done else {
                throw HostedAgentClientError.notConnected
            }
        }
        guard pendingRequest == nil else {
            throw HostedAgentClientError.requestInFlight
        }
        guard let socket else {
            throw HostedAgentClientError.notConnected
        }

        var frame = try client.buildControlFrame(type: type, payload: payload)
        frame["session_id"] = .string(conversation.id)
        if endpoint?.kind == .relay {
            frame["to"] = .string(agentAddress)
        }

        return try await sendRequest(frame: frame, socket: socket, id: UUID().uuidString, type: type)
    }

    private func addContinuation(id: UUID, continuation: AsyncStream<AgentSessionEvent>.Continuation) {
        eventContinuations[id] = continuation
        continuation.yield(.stateChanged(key, state))
        if let currentServerSession {
            continuation.yield(.serverSessionUpdated(key, currentServerSession))
        }
    }

    private func removeContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func updateConversation(_ conversation: Conversation) {
        self.conversation = conversation
        if let serverSession = conversation.serverSession {
            currentServerSession = serverSession
        }
    }

    private func ensureConnected() async throws -> HostedAgentResult {
        if socket != nil, authenticated, !suspended, networkAvailable {
            return HostedAgentResult(
                output: nil,
                endpointLabel: endpoint?.label ?? agentAddress,
                serverSession: currentServerSession,
                done: true
            )
        }

        if let connectTask {
            return try await connectTask.value
        }

        let task = Task {
            try await self.openAndAuthenticate()
        }
        connectTask = task
        do {
            let result = try await task.value
            connectTask = nil
            return result
        } catch {
            connectTask = nil
            throw error
        }
    }

    private func openAndAuthenticate() async throws -> HostedAgentResult {
        guard networkAvailable else {
            throw HostedAgentClientError.closed
        }
        guard !suspended else {
            throw HostedAgentClientError.closed
        }
        guard HostedAgentClient.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }

        closeSocket()
        authenticated = false
        setState(.resolvingEndpoint)
        endpoint = try await client.resolveEndpoint(agentAddress: agentAddress)
        guard let endpoint else {
            throw HostedAgentClientError.closed
        }

        setState(.connecting)
        let socket = client.makeWebSocketTask(for: endpoint)
        self.socket = socket
        lastFrameAt = Date()
        socket.resume()
        startReceiveLoop(socket)
        startHealthLoop()

        setState(.authenticating)
        let frame = try client.buildConnectFrame(agentAddress: agentAddress, conversation: conversation, endpoint: endpoint)
        return try await sendConnectFrame(frame, over: socket)
    }

    private func sendConnectFrame(_ frame: [String: JSONValue], over socket: URLSessionWebSocketTask) async throws -> HostedAgentResult {
        try await withCheckedThrowingContinuation { continuation in
            pendingConnect = continuation
            connectTimeoutTask?.cancel()
            connectTimeoutTask = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self.handleDisconnect(HostedAgentClientError.timeout, from: socket)
            }

            let client = self.client
            Task {
                do {
                    try await client.send(frame, over: socket)
                } catch {
                    await self.handleDisconnect(error, from: socket)
                }
            }
        }
    }

    private func sendRequest(
        frame: [String: JSONValue],
        socket: URLSessionWebSocketTask,
        id: String,
        type: String
    ) async throws -> HostedAgentResult {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequest = PendingRequest(id: id, type: type, continuation: continuation, sent: false)

            let client = self.client
            Task {
                do {
                    try await client.send(frame, over: socket)
                    await self.markPendingRequestSent(id: id)
                } catch {
                    await self.handleDisconnect(error, from: socket)
                }
            }
        }
    }

    private func markPendingRequestSent(id: String) {
        guard pendingRequest?.id == id else {
            return
        }
        pendingRequest?.sent = true
    }

    private func startReceiveLoop(_ socket: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        let client = self.client
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let frame = try await client.readFrame(from: socket)
                    await self.handleFrame(frame, from: socket)
                } catch {
                    await self.handleDisconnect(error, from: socket)
                    break
                }
            }
        }
    }

    private func startHealthLoop() {
        healthTask?.cancel()
        healthTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self.checkHealth()
            }
        }
    }

    private func checkHealth() {
        guard let socket, authenticated, !suspended, networkAvailable else {
            return
        }
        if Date().timeIntervalSince(lastFrameAt) > 60 {
            socket.cancel(with: .goingAway, reason: nil)
            handleDisconnect(HostedAgentClientError.timeout, from: socket)
        }
    }

    private func handleFrame(_ frame: [String: JSONValue], from socket: URLSessionWebSocketTask) async {
        guard self.socket === socket else {
            return
        }
        lastFrameAt = Date()
        let type = frame["type"]?.stringValue ?? ""

        if type == "PING" {
            do {
                try await client.send(["type": .string("PONG")], over: socket)
            } catch {
                handleDisconnect(error, from: socket)
            }
            return
        }

        mergeServerSession(from: frame)

        switch type {
        case "CONNECTED":
            handleConnected(frame)
        case "session_sync":
            break
        case "SESSION_MERGED", "RECONNECTED":
            setState(.connected)
        case "mode_changed":
            handleModeChanged(frame)
        case "assistant", "thinking", "llm_call", "llm_result", "tool_call", "tool_result",
             "intent", "eval", "compact", "tool_blocked", "files_received", "agent_image":
            emitStreamMessage(from: frame)
        case "ask_user":
            handleAskUser(frame)
        case "approval_needed":
            handleApprovalNeeded(frame)
        case "plan_review":
            handlePlanReview(frame)
        case "ulw_turns_reached":
            handleUlwTurnsReached(frame)
        case "ONBOARD_REQUIRED":
            handleOnboardRequired(frame)
        case "ONBOARD_SUCCESS":
            handleOnboardSuccess(frame)
        case "OUTPUT":
            handleOutput(frame)
        case "ERROR":
            handleServerError(frame)
        default:
            break
        }
    }

    private func handleConnected(_ frame: [String: JSONValue]) {
        authenticated = true
        reconnectAttempt = 0
        setState(.connected)
        finishPendingConnect(
            HostedAgentResult(
                output: nil,
                endpointLabel: endpoint?.label ?? agentAddress,
                serverSession: currentServerSession,
                done: true
            )
        )

        if pendingRequest?.type == "ONBOARD_SUBMIT" {
            finishPendingRequest(
                HostedAgentResult(
                    output: "Onboarding complete.",
                    endpointLabel: endpoint?.label ?? agentAddress,
                    serverSession: currentServerSession,
                    done: true
                )
            )
        }
    }

    private func handleModeChanged(_ frame: [String: JSONValue]) {
        guard let mode = frame["mode"]?.stringValue else {
            return
        }
        var session = currentServerSession ?? [:]
        session["mode"] = .string(mode)
        currentServerSession = session
        emit(.serverSessionUpdated(key, session))
    }

    private func handleAskUser(_ frame: [String: JSONValue]) {
        let question = frame["text"]?.stringValue ?? frame["question"]?.stringValue ?? "The agent needs your input."
        let interaction = PendingInteraction(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            conversationID: conversation.id,
            kind: .askUser,
            title: "Agent Question",
            message: question,
            options: frame["options"]?.stringArrayValue ?? []
        )
        setState(.waiting)
        emit(.message(key, ChatMessage(role: .agent, content: question)))
        emit(.pendingInteraction(key, interaction))
        finishPendingRequest(pausedOutput: question)
    }

    private func handleApprovalNeeded(_ frame: [String: JSONValue]) {
        let tool = frame["tool"]?.stringValue ?? "Tool"
        let argumentsText = frame["arguments"]?.prettyPrinted ?? "{}"
        let description = frame["description"]?.stringValue ?? "Approve or reject this tool call."
        let interaction = PendingInteraction(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            conversationID: conversation.id,
            kind: .approval,
            title: "Approval Needed",
            message: description,
            tool: tool,
            argumentsText: argumentsText
        )
        setState(.waiting)
        emit(.message(key, ChatMessage(role: .agent, content: "\(tool) needs approval.\n\(description)")))
        emit(.pendingInteraction(key, interaction))
        finishPendingRequest(pausedOutput: description)
    }

    private func handlePlanReview(_ frame: [String: JSONValue]) {
        let plan = frame["plan_content"]?.stringValue ?? "The agent is waiting for your plan review."
        let interaction = PendingInteraction(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            conversationID: conversation.id,
            kind: .planReview,
            title: "Plan Review",
            message: plan
        )
        setState(.waiting)
        emit(.message(key, ChatMessage(role: .agent, content: plan)))
        emit(.pendingInteraction(key, interaction))
        finishPendingRequest(pausedOutput: plan)
    }

    private func handleUlwTurnsReached(_ frame: [String: JSONValue]) {
        let used = Int(frame["turns_used"]?.numberValue ?? 0)
        let max = Int(frame["max_turns"]?.numberValue ?? 0)
        let message = "ULW turn limit reached (\(used)/\(max))."
        let interaction = PendingInteraction(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            conversationID: conversation.id,
            kind: .ulwTurnsReached,
            title: "ULW Limit",
            message: message,
            options: ["continue", "stop"]
        )
        setState(.waiting)
        emit(.message(key, ChatMessage(role: .agent, content: message)))
        emit(.pendingInteraction(key, interaction))
        finishPendingRequest(pausedOutput: message)
    }

    private func handleOnboardRequired(_ frame: [String: JSONValue]) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        let methods = frame["methods"]?.stringArrayValue ?? []
        let message = methods.isEmpty ? "The agent requires onboarding." : "The agent requires onboarding: \(methods.joined(separator: ", "))."
        let interaction = PendingInteraction(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            conversationID: conversation.id,
            kind: .onboard,
            title: "Onboarding Required",
            message: message,
            options: methods
        )
        setState(.waiting)
        emit(.message(key, ChatMessage(role: .agent, content: message)))
        emit(.pendingInteraction(key, interaction))
        finishPendingConnect(
            HostedAgentResult(
                output: message,
                endpointLabel: endpoint?.label ?? agentAddress,
                serverSession: currentServerSession,
                done: false
            )
        )
        finishPendingRequest(pausedOutput: message)
    }

    private func handleOnboardSuccess(_ frame: [String: JSONValue]) {
        let message = frame["message"]?.stringValue ?? "Onboarding succeeded."
        setState(.authenticating)
        emit(.message(key, ChatMessage(role: .agent, content: message)))
        emit(.pendingInteraction(key, nil))
    }

    private func handleOutput(_ frame: [String: JSONValue]) {
        let output = client.messageText(frame)
        setState(.connected)
        emit(.pendingInteraction(key, nil))
        finishPendingRequest(
            HostedAgentResult(
                output: output,
                endpointLabel: endpoint?.label ?? agentAddress,
                serverSession: currentServerSession,
                done: true
            )
        )
    }

    private func handleServerError(_ frame: [String: JSONValue]) {
        let message = client.messageText(frame)
        let hadPendingRequest = pendingRequest != nil
        failPendingConnect(HostedAgentClientError.server(message))
        failPendingRequest(HostedAgentClientError.server(message), protectSentRequest: false)
        if !hadPendingRequest {
            emit(.message(key, ChatMessage(role: .error, content: message)))
        }
        closeSocket()
        setState(.failed(message))
        scheduleReconnect()
    }

    private func emitStreamMessage(from frame: [String: JSONValue]) {
        guard let message = streamMessage(from: frame) else {
            return
        }
        emit(.message(key, message))
    }

    private func streamMessage(from frame: [String: JSONValue]) -> ChatMessage? {
        let type = frame["type"]?.stringValue ?? ""
        switch type {
        case "assistant":
            guard let content = frame["content"]?.stringValue, !content.isEmpty else {
                return nil
            }
            return ChatMessage(role: .agent, content: content)
        case "thinking":
            let content = frame["content"]?.stringValue ?? frame["kind"]?.stringValue ?? "Thinking..."
            return ChatMessage(role: .thinking, content: content)
        case "llm_call":
            let model = frame["model"]?.stringValue ?? "model"
            return ChatMessage(role: .thinking, content: "Calling \(model)...")
        case "llm_result":
            return ChatMessage(role: .thinking, content: "Model response received.")
        case "tool_call":
            let name = frame["name"]?.stringValue ?? "tool"
            return ChatMessage(role: .thinking, content: "Running \(name)...")
        case "tool_result":
            let result = frame["result"]?.stringValue ?? frame["status"]?.stringValue ?? "done"
            return ChatMessage(role: .thinking, content: result)
        case "intent":
            return ChatMessage(role: .thinking, content: frame["ack"]?.stringValue ?? "Understanding intent...")
        case "eval":
            return ChatMessage(role: .thinking, content: frame["summary"]?.stringValue ?? "Evaluating...")
        case "compact":
            return ChatMessage(role: .thinking, content: frame["message"]?.stringValue ?? "Compacting context...")
        case "tool_blocked":
            return ChatMessage(role: .error, content: frame["message"]?.stringValue ?? "Tool call blocked.")
        case "files_received":
            return ChatMessage(role: .agent, content: frame["files"]?.prettyPrinted ?? "Files received.")
        case "agent_image":
            return ChatMessage(role: .agent, content: "Agent sent an image.")
        default:
            return nil
        }
    }

    private func mergeServerSession(from frame: [String: JSONValue]) {
        guard let incoming = client.extractServerSession(from: frame) else {
            return
        }
        var next = currentServerSession ?? [:]
        for (key, value) in incoming {
            next[key] = value
        }
        if next["session_id"] == nil {
            next["session_id"] = .string(conversation.id)
        }
        currentServerSession = next
        emit(.serverSessionUpdated(key, next))
    }

    private func finishPendingConnect(_ result: HostedAgentResult) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        guard let continuation = pendingConnect else {
            return
        }
        pendingConnect = nil
        continuation.resume(returning: result)
    }

    private func failPendingConnect(_ error: Error) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        guard let continuation = pendingConnect else {
            return
        }
        pendingConnect = nil
        continuation.resume(throwing: error)
    }

    private func finishPendingRequest(pausedOutput: String) {
        finishPendingRequest(
            HostedAgentResult(
                output: pausedOutput,
                endpointLabel: endpoint?.label ?? agentAddress,
                serverSession: currentServerSession,
                done: false
            )
        )
    }

    private func finishPendingRequest(_ result: HostedAgentResult) {
        guard let request = pendingRequest else {
            return
        }
        pendingRequest = nil
        request.continuation.resume(returning: result)
    }

    private func failPendingRequest(_ error: Error, protectSentRequest: Bool = false) {
        guard let request = pendingRequest else {
            return
        }
        pendingRequest = nil
        let reportedError = protectSentRequest && request.sent ? HostedAgentClientError.duplicateProtected : error
        request.continuation.resume(throwing: reportedError)
    }

    private func handleDisconnect(_ error: Error, from socket: URLSessionWebSocketTask?) {
        if let socket, let current = self.socket, socket !== current {
            return
        }

        closeSocket()
        authenticated = false
        failPendingConnect(error)
        failPendingRequest(error, protectSentRequest: true)

        guard !suspended else {
            setState(.suspended)
            return
        }
        guard networkAvailable else {
            setState(.closed)
            return
        }

        setState(.reconnecting(attempt: reconnectAttempt + 1))
        scheduleReconnect()
    }

    private func handleConnectionError(_ error: Error) {
        let message = error.localizedDescription
        setState(.failed(message))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !suspended, networkAvailable, reconnectTask == nil else {
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        setState(.reconnecting(attempt: attempt))
        reconnectTask = Task {
            let baseDelay = min(pow(2.0, Double(attempt - 1)), 30.0)
            let jitter = Double.random(in: 0...0.35)
            try? await Task.sleep(nanoseconds: UInt64((baseDelay + jitter) * 1_000_000_000))
            await self.runReconnectAttempt()
        }
    }

    private func runReconnectAttempt() async {
        reconnectTask = nil
        do {
            _ = try await ensureConnected()
        } catch {
            handleConnectionError(error)
        }
    }

    private func closeSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        healthTask?.cancel()
        healthTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        authenticated = false
    }

    private func setState(_ next: AgentRuntimeState) {
        guard state != next else {
            return
        }
        state = next
        emit(.stateChanged(key, next))
    }

    private func emit(_ event: AgentSessionEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}

private extension JSONValue {
    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }

    var stringArrayValue: [String]? {
        guard case .array(let values) = self else {
            return nil
        }
        return values.compactMap(\.stringValue)
    }

    var prettyPrinted: String? {
        guard let data = try? JSONEncoder().encode(self) else {
            return nil
        }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(data: prettyData, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }
}
