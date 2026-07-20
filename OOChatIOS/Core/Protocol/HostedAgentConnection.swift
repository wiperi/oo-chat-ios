import Foundation

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
        // No frames flow while an interaction card waits on the human, so a user who takes
        // longer than `livenessTimeout` to decide would otherwise lose the connection and
        // their decision with it. Sending the response updates `lastNetworkActivityAt`,
        // which restarts the clock from a live socket.
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
        // The socket can die between `ensureConnected` returning and this task running,
        // in which case `disconnect` already ran and resumed nothing — `pendingPrompt` was
        // set after it. Returning here would leak the continuation and hang the conversation
        // forever, so fail the prompt explicitly instead.
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
                // A payload we cannot parse used to fail the connection, which cost the user
                // the whole round-trip. Decline it on their behalf and keep the socket.
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
                // This kind's decline has no wire representation (ask_user cancel), so the
                // agent would keep waiting on a response that is never coming. End the
                // round-trip now rather than letting it sit until the receive timeout.
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
        // A superseded request is one the agent itself replaced by sending a newer one of the
        // same kind. Its gate still has to be released so the receive loop unblocks, but no
        // response goes on the wire: these frames carry no request ID, so a late reply would
        // be indistinguishable from an answer to the request that replaced it.
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
        HostedAgentEvent.messageText(frame)
    }
}
