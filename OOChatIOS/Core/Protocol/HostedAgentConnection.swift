import Foundation

// wraps the system socket so tests can control reads and writes
protocol HostedAgentWebSocketTask: AnyObject, Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: HostedAgentWebSocketTask {}

typealias HostedAgentWebSocketFactory = @Sendable (URL) -> any HostedAgentWebSocketTask
typealias HostedAgentEndpointResolver = @Sendable (String) async throws -> ResolvedEndpoint

// owns one socket and one active prompt for a conversation
actor HostedAgentConnection {
    private enum State: Equatable {
        case disconnected
        case connecting
        case connected
    }

    private struct PendingPrompt {
        let id: UUID
        let continuation: CheckedContinuation<HostedAgentResult, Error>
        let onEvent: (@MainActor (HostedAgentEvent) -> Void)?
        let onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
    }

    private let key: HostedAgentConnectionKey
    private let identityStore: IdentityStore
    private let connectionStateObserver: HostedAgentConnectionStateObserver
    private let socketFactory: HostedAgentWebSocketFactory
    private let endpointResolver: HostedAgentEndpointResolver
    private let connectTimeout: TimeInterval
    private let livenessTimeout: TimeInterval
    private let livenessCheckInterval: TimeInterval

    private var state: State = .disconnected
    private var socket: (any HostedAgentWebSocketTask)?
    private var endpoint: ResolvedEndpoint?
    private var receiveTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var interactionTasks: [UUID: Task<Void, Never>] = [:]
    // rejects frames and failures from sockets that were already replaced
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
        connectionStateObserver: HostedAgentConnectionStateObserver,
        socketFactory: HostedAgentWebSocketFactory? = nil,
        endpointResolver: HostedAgentEndpointResolver? = nil,
        connectTimeout: TimeInterval = 45,
        livenessTimeout: TimeInterval = 75,
        livenessCheckInterval: TimeInterval = 10
    ) {
        self.key = key
        self.identityStore = identityStore
        self.connectionStateObserver = connectionStateObserver
        self.socketFactory = socketFactory ?? { session.webSocketTask(with: $0) }
        self.endpointResolver = endpointResolver ?? { agentAddress in
            try await discovery.discover(agentAddress: agentAddress).endpoint
        }
        self.connectTimeout = connectTimeout
        self.livenessTimeout = livenessTimeout
        self.livenessCheckInterval = livenessCheckInterval
    }

    // shares one connection attempt across callers for the same conversation
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

    // allows only one prompt to use this conversation socket at a time
    func sendPrompt(
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
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
                    onInteraction: onInteraction
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
            let socket = socketFactory(endpoint.wsURL)
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

    private func startReceiveLoop(
        socket: any HostedAgentWebSocketTask,
        generation: Int
    ) {
        // keeps one reader responsible for all frames from the current socket
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
                    try await Task.sleep(
                        nanoseconds: UInt64((self?.livenessCheckInterval ?? 10) * 1_000_000_000)
                    )
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
        // human interaction can stay quiet longer than the liveness window
        // sending a decision restarts activity tracking for the same socket
        guard interactionTasks.isEmpty else {
            return false
        }
        return generation == socketGeneration
            && Date().timeIntervalSince(lastNetworkActivityAt) > livenessTimeout
    }

    private func transmitPrompt(_ prompt: String, conversation: Conversation, promptID: UUID) async {
        let generation = socketGeneration
        guard pendingPrompt?.id == promptID else {
            return
        }
        // the socket may close after connection checks but before this task sends
        // failing here keeps the stored continuation from waiting forever
        guard let socket else {
            failConnection(HostedAgentClientError.closed, generation: generation)
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
        case "approval_needed", "APPROVAL_NEEDED", "ulw_turns_reached", "plan_review", "ask_user":
            guard let pending = pendingPrompt else {
                return
            }
            guard let interaction = HostedAgentInteraction.from(frame) else {
                // decline known interaction types when their payload cannot be parsed
                if let placeholder = HostedAgentInteraction.declinePlaceholder(for: frame) {
                    await sendDeclineResponse(for: placeholder, generation: generation)
                } else {
                    failConnection(HostedAgentClientError.badFrame, generation: generation)
                }
                return
            }
            startInteractionTask(interaction, promptID: pending.id, generation: generation)
        case "ERROR":
            failConnection(
                HostedAgentClientError.server(messageText(frame)),
                generation: generation
            )
        default:
            break
        }
    }

    private func startInteractionTask(
        _ interaction: HostedAgentInteraction,
        promptID: UUID,
        generation: Int
    ) {
        let taskID = UUID()
        interactionTasks[taskID] = Task { [weak self] in
            await self?.processInteraction(
                interaction,
                promptID: promptID,
                generation: generation,
                taskID: taskID
            )
        }
    }

    private func processInteraction(
        _ interaction: HostedAgentInteraction,
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
        let decision = await pending.onInteraction?(interaction) ?? interaction.unavailableDecision
        guard generation == socketGeneration,
              pendingPrompt?.id == promptID,
              let socket,
              let endpoint else {
            return
        }
        do {
            guard let frame = try interactionResponseFrame(
                for: interaction,
                decision: decision,
                endpoint: endpoint
            ) else {
                return
            }
            try await send(frame, over: socket)
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func sendDeclineResponse(
        for interaction: HostedAgentInteraction,
        generation: Int
    ) async {
        guard generation == socketGeneration, let socket, let endpoint else {
            return
        }
        do {
            guard let frame = try interactionResponseFrame(
                for: interaction,
                decision: interaction.unavailableDecision,
                endpoint: endpoint
            ) else {
                // ask user cancellation has no response frame, so end the pending turn
                failConnection(HostedAgentClientError.badFrame, generation: generation)
                return
            }
            try await send(frame, over: socket)
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func interactionResponseFrame(
        for interaction: HostedAgentInteraction,
        decision: HostedAgentInteractionDecision,
        endpoint: ResolvedEndpoint
    ) throws -> [String: JSONValue]? {
        switch (interaction, decision) {
        // superseded requests release the local gate without writing to the socket
        case (_, .superseded):
            return nil
        case (.approval, .approval(let approval)):
            return HostedAgentClient.approvalResponseFrame(
                decision: approval,
                agentAddress: key.agentAddress,
                endpoint: endpoint
            )
        case (.ulwCheckpoint, .ulwCheckpoint(let checkpoint)):
            return HostedAgentClient.ulwResponseFrame(
                decision: checkpoint,
                agentAddress: key.agentAddress,
                endpoint: endpoint
            )
        case (.planReview(let request), .planReview(let review)):
            return HostedAgentClient.planReviewResponseFrame(
                decision: review,
                request: request,
                agentAddress: key.agentAddress,
                endpoint: endpoint
            )
        case (.askUser, .askUser(.cancel)):
            return nil
        case (.askUser, .askUser(.answer(let answer))):
            return HostedAgentClient.askUserResponseFrame(
                answer: answer,
                agentAddress: key.agentAddress,
                endpoint: endpoint
            )
        default:
            throw HostedAgentClientError.badFrame
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
        // clear shared state before any waiter can resume and call back into this actor
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
        try await endpointResolver(agentAddress)
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
        HostedAgentSessionState.applying(
            conversation.mode,
            to: conversation.serverSession,
            conversationID: conversation.id
        )
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

    private func send(_ frame: [String: JSONValue], over socket: any HostedAgentWebSocketTask) async throws {
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostedAgentClientError.badFrame
        }
        try await socket.send(.string(text))
        // an awaited send may finish after this socket has already been replaced
        guard self.socket === socket else {
            throw HostedAgentClientError.closed
        }
        lastNetworkActivityAt = Date()
    }

    private static func readFrame(
        from socket: any HostedAgentWebSocketTask
    ) async throws -> [String: JSONValue] {
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
        HostedAgentEvent.messageText(frame)
    }
}
