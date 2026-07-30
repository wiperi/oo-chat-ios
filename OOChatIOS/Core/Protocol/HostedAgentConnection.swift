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
        // Allocated once and reused by every resend of this prompt. 
        let inputID: String
        let continuation: CheckedContinuation<HostedAgentResult, Error>
        let onEvent: (@MainActor (HostedAgentEvent) -> Void)?
        let onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
        let prompt: String
        let images: [String]
        let files: [HostedAgentFilePayload]
        // false until the INPUT frame reached the socket: a resume may resend it,
        // but only then — resending a delivered INPUT would run the prompt twice
        var inputDelivered = false
    }

    private let key: HostedAgentConnectionKey
    private let identityStore: IdentityStore
    private let connectionStateObserver: HostedAgentConnectionStateObserver
    private let socketFactory: HostedAgentWebSocketFactory
    private let endpointResolver: HostedAgentEndpointResolver
    private let connectTimeout: TimeInterval
    private let livenessTimeout: TimeInterval
    private let livenessCheckInterval: TimeInterval
    private let resumeAttemptLimit: Int
    private let resumeRetryDelay: TimeInterval

    private var state: State = .disconnected
    private var socket: (any HostedAgentWebSocketTask)?
    private var endpoint: ResolvedEndpoint?
    private var receiveTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var interactionTasks: [UUID: Task<Void, Never>] = [:]
    // rejects frames and failures from sockets that were already replaced
    private var socketGeneration = 0
    private var connectWaiters: [UUID: CheckedContinuation<HostedAgentResult, Error>] = [:]
    private var pendingPrompt: PendingPrompt?
    private var serverSession: [String: JSONValue]?
    private var connectionStatus: String?
    private var lastNetworkActivityAt = Date()
    private var resumeAttemptsUsed = 0
    private var lastConversation: Conversation?
    private var requiresRevalidation = false

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
        livenessCheckInterval: TimeInterval = 10,
        resumeAttemptLimit: Int = 3,
        resumeRetryDelay: TimeInterval = 1
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
        self.resumeAttemptLimit = resumeAttemptLimit
        self.resumeRetryDelay = resumeRetryDelay
    }

    // shares one connection attempt across callers for the same conversation
    func ensureConnected(conversation: Conversation) async throws -> HostedAgentResult {
        lastConversation = conversation
        if requiresRevalidation, state == .connected {
            guard pendingPrompt == nil else {
                throw HostedAgentClientError.busy
            }
            disconnect(with: HostedAgentClientError.closed, closeCode: .goingAway)
        }
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
        images: [String] = [],
        files: [HostedAgentFilePayload] = [],
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
    ) async throws -> HostedAgentResult {
        try Task.checkCancellation()
        _ = try await ensureConnected(conversation: conversation)
        try Task.checkCancellation()
        guard pendingPrompt == nil else {
            throw HostedAgentClientError.busy
        }
        resumeAttemptsUsed = 0

        let promptID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingPrompt = PendingPrompt(
                    id: promptID,
                    inputID: UUID().uuidString,
                    continuation: continuation,
                    onEvent: onEvent,
                    onInteraction: onInteraction,
                    prompt: prompt,
                    images: images,
                    files: files
                )
                guard !Task.isCancelled else {
                    disconnect(with: CancellationError(), closeCode: .goingAway)
                    return
                }
                Task { [weak self] in
                    await self?.transmitPrompt(
                        prompt,
                        images: images,
                        files: files,
                        conversation: conversation,
                        promptID: promptID
                    )
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

    func noteNetworkLost() {
        requiresRevalidation = true
    }

    // wall-clock silence while the app was suspended says nothing about socket health,
    // so returning to the foreground grants the liveness monitor a fresh window
    func noteApplicationBecameActive() {
        lastNetworkActivityAt = Date()
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

    private func transmitPrompt(
        _ prompt: String,
        images: [String],
        files: [HostedAgentFilePayload],
        conversation: Conversation,
        promptID: UUID
    ) async {
        let generation = socketGeneration
        guard let pending = pendingPrompt, pending.id == promptID else {
            return
        }
        // the socket may close after connection checks but before this task sends
        // failing here keeps the stored continuation from waiting forever
        guard let socket else {
            failConnection(HostedAgentClientError.closed, generation: generation)
            return
        }
        do {
            let inputFrame = try buildInputFrame(
                prompt: prompt,
                images: images,
                files: files,
                conversation: conversation,
                inputID: pending.inputID
            )
            try await send(inputFrame, over: socket)
            if pendingPrompt?.id == promptID {
                pendingPrompt?.inputDelivered = true
            }
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
            await resumePendingPrompt(from: frame, generation: generation)
        case "OUTPUT":
            updateServerSession(from: frame)
            connectionStatus = "connected"
            resumeAttemptsUsed = 0
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

    // A CONNECTED frame while a prompt is pending is a mid-prompt reconnect. The server's
    // `status` says where the run stands: "running" means events and the OUTPUT will stream
    // on this socket; anything else means the run finished while we were away (the reply is
    // the trailing agent entry in `chat_items`) or the INPUT never started it (resend it).
    private func resumePendingPrompt(from frame: [String: JSONValue], generation: Int) async {
        guard let pending = pendingPrompt else {
            return
        }
        guard frame["status"]?.stringValue != "running" else {
            return
        }

        if !pending.inputDelivered {
            guard var conversation = lastConversation else {
                failConnection(HostedAgentClientError.closed, generation: generation)
                return
            }
            if let serverSession {
                conversation.serverSession = serverSession
            }
            await transmitPrompt(
                pending.prompt,
                images: pending.images,
                files: pending.files,
                conversation: conversation,
                promptID: pending.id
            )
            return
        }

        let missedItems = Self.itemsAfterLastUserMessage(in: frame)
        for item in missedItems {
            guard let event = Self.replayedToolResult(item) else {
                continue
            }
            await pending.onEvent?(event)
        }
        guard pendingPrompt?.id == pending.id else {
            return
        }
        pendingPrompt = nil
        cancelInteractionTasks()
        let reply = missedItems.last { $0["type"]?.stringValue == "agent" }?["content"]?.stringValue
        if let reply, !reply.isEmpty {
            pending.continuation.resume(
                returning: HostedAgentResult(
                    output: reply,
                    endpointLabel: endpoint?.label ?? key.agentAddress,
                    serverSession: serverSession
                )
            )
        } else {
            // the server no longer has the run or its reply, so let the user retry
            pending.continuation.resume(throwing: HostedAgentClientError.closed)
        }
    }

    private static func itemsAfterLastUserMessage(in frame: [String: JSONValue]) -> [[String: JSONValue]] {
        guard case .array(let values)? = frame["chat_items"] else {
            return []
        }
        var turn: [[String: JSONValue]] = []
        for value in values {
            guard case .object(let item) = value else {
                continue
            }
            if item["type"]?.stringValue == "user" {
                turn.removeAll()
            } else {
                turn.append(item)
            }
        }
        return turn
    }

    private static func replayedToolResult(_ item: [String: JSONValue]) -> HostedAgentEvent? {
        guard item["type"]?.stringValue == "tool_call",
              let id = item["id"]?.stringValue,
              !id.isEmpty else {
            return nil
        }
        return .toolResult(
            id: id,
            name: item["name"]?.stringValue,
            output: HostedAgentEvent.messageText(item),
            state: item["status"]?.stringValue == "error" ? .failed : .completed
        )
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
        if canResume(after: error) {
            beginResumeAttempt()
            return
        }
        disconnect(with: normalizedConnectionError(error), closeCode: .goingAway)
    }

    // A dropped socket does not end the round-trip: the server keeps the run alive and
    // re-attaches it when the same session reconnects, so a pending prompt is worth
    // resuming for connection-loss errors. Server rejections and cancellations are final.
    private func canResume(after error: Error) -> Bool {
        guard pendingPrompt != nil,
              connectWaiters.isEmpty,
              lastConversation != nil,
              resumeAttemptsUsed < resumeAttemptLimit else {
            return false
        }
        switch error {
        case is CancellationError:
            return false
        case let clientError as HostedAgentClientError:
            switch clientError {
            case .closed, .timeout:
                return true
            default:
                return false
            }
        default:
            return true
        }
    }

    private func beginResumeAttempt() {
        resumeAttemptsUsed += 1
        socketGeneration += 1
        let generation = socketGeneration
        setState(.connecting)
        connectionStatus = nil

        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        // gates from the dead socket unblock here; the server replays any interaction
        // request that is still waiting once the new socket attaches
        cancelInteractionTasks()

        let socket = socket
        self.socket = nil
        endpoint = nil
        socket?.cancel(with: .goingAway, reason: nil)

        let delay = resumeRetryDelay * pow(2, Double(resumeAttemptsUsed - 1))
        resumeTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.resumeConnection(generation: generation)
        }
    }

    private func resumeConnection(generation: Int) async {
        guard generation == socketGeneration,
              state == .connecting,
              pendingPrompt != nil,
              var conversation = lastConversation else {
            return
        }
        if let serverSession {
            conversation.serverSession = serverSession
        }
        await openConnection(conversation: conversation, generation: generation)
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
        resumeTask?.cancel()
        resumeTask = nil
        resumeAttemptsUsed = 0
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
        if newState == .connected {
            requiresRevalidation = false
        }
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

    private func buildInputFrame(
        prompt: String,
        images: [String],
        files: [HostedAgentFilePayload],
        conversation: Conversation,
        inputID: String
    ) throws -> [String: JSONValue] {
        let timestamp = Double(Int(Date().timeIntervalSince1970))
        let payload = HostedAgentClient.inputSignaturePayload(
            agentAddress: key.agentAddress,
            conversationID: conversation.id,
            inputID: inputID,
            prompt: prompt,
            mode: conversation.mode,
            timestamp: timestamp,
            images: images,
            files: files
        )
        var frame = try identityStore.signedEnvelope(type: "INPUT", payload: payload)
        frame["to"] = .string(key.agentAddress)
        frame["session_id"] = .string(conversation.id)
        frame["input_id"] = .string(inputID)
        frame["prompt"] = .string(prompt)
        frame["mode"] = .string(conversation.mode.rawValue)
        if !images.isEmpty {
            frame["images"] = .array(images.map(JSONValue.string))
        }
        if !files.isEmpty {
            frame["files"] = .array(files.map(\.jsonValue))
        }
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
