import Combine
import Foundation
import SwiftUI

@MainActor
final class WeakChatViewModelReference {
    weak var value: ChatViewModel?

    init(_ value: ChatViewModel) {
        self.value = value
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var identity: StoredIdentity?
    @Published var isConnecting = false
    @Published var errorMessage: String?
    @Published var connectionFailureMessage: String?
    @Published var agentAddressDraft = ""
    @Published var prompt = "" {
        didSet {
            conversationState.updateActiveDraft(prompt)
        }
    }
    @Published private(set) var isOffline = false
    @Published private(set) var isOfflineBannerDismissed = false
    @Published private var connectionStatesByConversationID: [String: ConnectionState] = [:]
    @Published private var processingConversationIDs: Set<String> = []
    @Published private var skillsByAgentAddress: [String: [AgentSkill]] = [:]

    var shouldShowOfflineBanner: Bool {
        isOffline && !isOfflineBannerDismissed
    }

    private var deliveryTasksByConversationID: [String: Task<Void, Never>] = [:]
    private var activeMessageIDsByConversationID: [String: String] = [:]
    private var pausedConversationIDs: Set<String> = []
    private(set) var recoveryTask: Task<Void, Never>?
    private(set) var probeTask: Task<Void, Never>?
    private var skillFetchTasks: [String: Task<Void, Never>] = [:]
    private let interactionCoordinator = InteractionCoordinator()
    private var interactionChangeCancellable: AnyCancellable?
    private var conversationStateChangeCancellable: AnyCancellable?
    private var persistenceErrorCancellable: AnyCancellable?

    /// Seconds between silent reachability probes while offline. Overridable in tests.
    var probeInterval: TimeInterval = 5

    private let conversationState: ConversationState
    private let identityStore: IdentityStore
    private let networkMonitor: NetworkPathMonitoring
    private let injectedClient: HostedAgentTransport?
    private lazy var client: HostedAgentTransport = injectedClient ?? HostedAgentClient(identityStore: identityStore)

    var agents: [AgentConnection] {
        conversationState.agents
    }

    var conversations: [Conversation] {
        get {
            conversationState.conversations
        }
        set {
            conversationState.replaceConversations(newValue)
        }
    }

    var activeAgentID: String? {
        conversationState.activeAgentID
    }

    var activeConversationID: String? {
        conversationState.activeConversationID
    }

    var activeAgent: AgentConnection? {
        conversationState.activeAgent
    }

    var activeConversation: Conversation? {
        conversationState.activeConversation
    }

    var activeMode: ChatMode {
        activeConversation?.mode ?? .safe
    }

    var connectionState: ConnectionState {
        guard let activeConversationID else {
            return .disconnected
        }
        return connectionState(forConversationID: activeConversationID)
    }

    var isProcessing: Bool {
        guard let activeConversationID else {
            return false
        }
        return processingConversationIDs.contains(activeConversationID)
    }

    var sendTask: Task<Void, Never>? {
        guard let activeConversationID else {
            return nil
        }
        return deliveryTasksByConversationID[activeConversationID]
    }

    var pendingApproval: PendingApproval? {
        activePendingApproval
    }

    var pendingUlwCheckpoint: PendingUlwCheckpoint? {
        activePendingUlwCheckpoint
    }

    var pendingPlanReview: PendingPlanReview? {
        activePendingPlanReview
    }

    var pendingAskUser: PendingAskUser? {
        activePendingAskUser
    }

    var activePendingApproval: PendingApproval? {
        interactionCoordinator.pendingApproval(for: activeConversationID)
    }

    var activePendingUlwCheckpoint: PendingUlwCheckpoint? {
        interactionCoordinator.pendingUlwCheckpoint(for: activeConversationID)
    }

    var activePendingPlanReview: PendingPlanReview? {
        interactionCoordinator.pendingPlanReview(for: activeConversationID)
    }

    var activePendingAskUser: PendingAskUser? {
        interactionCoordinator.pendingAskUser(for: activeConversationID)
    }

    var pendingInteractionID: String? {
        interactionCoordinator.pendingInteractionID(for: activeConversationID)
    }

    func isProcessing(conversationID: String) -> Bool {
        processingConversationIDs.contains(conversationID)
    }

    func hasPendingInteraction(forConversationID conversationID: String) -> Bool {
        interactionCoordinator.hasPendingInteraction(for: conversationID)
    }

    var hasBackgroundPendingInteraction: Bool {
        interactionCoordinator.hasPendingInteraction(excluding: activeConversationID)
    }

    var onlineAgentCount: Int {
        agents.filter(isAgentOnline).count
    }

    func isAgentOnline(_ agent: AgentConnection) -> Bool {
        conversations(for: agent).contains { conversation in
            connectionState(forConversationID: conversation.id) == .connected
        }
    }

    var slashSkillSuggestions: [AgentSkill] {
        guard let query = slashSkillQuery,
              let address = activeAgent?.address else {
            return []
        }
        let skills = skillsByAgentAddress[address] ?? []
        guard !query.isEmpty else {
            return skills
        }
        return skills.filter {
            $0.name.range(
                of: query,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    var shouldShowSlashSkillPicker: Bool {
        slashSkillQuery != nil && !slashSkillSuggestions.isEmpty
    }

    init(
        store: ConversationRepository? = nil,
        identityStore: IdentityStore = IdentityStore(),
        client: HostedAgentTransport? = nil,
        networkMonitor: NetworkPathMonitoring? = nil
    ) {
        let store = store ?? ConversationRepositoryFactory.make()
        let conversationState = ConversationState(store: store)
        self.conversationState = conversationState
        self.identityStore = identityStore
        self.injectedClient = client
        self.networkMonitor = networkMonitor ?? NetworkMonitor()
        self.agentAddressDraft = conversationState.activeAgent?.address ?? ""
        do {
            self.identity = try identityStore.loadOrCreateIdentity()
        } catch {
            self.errorMessage = error.localizedDescription
        }
        if let error = conversationState.persistenceError {
            self.errorMessage = error.localizedDescription
        }
        self.networkMonitor.onUpdate = { [weak self] isOnline in
            self?.handleNetworkChange(isOnline: isOnline)
        }
        self.client.onConnectionStateChange = { [weak self] conversationID, state in
            self?.setConnectionState(state, forConversationID: conversationID)
        }
        interactionChangeCancellable = interactionCoordinator.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        conversationStateChangeCancellable = conversationState.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        persistenceErrorCancellable = conversationState.$persistenceError
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.errorMessage = error.localizedDescription
            }
        self.networkMonitor.start()
    }

    deinit {
        networkMonitor.cancel()
        probeTask?.cancel()
        recoveryTask?.cancel()
        deliveryTasksByConversationID.values.forEach { $0.cancel() }
        skillFetchTasks.values.forEach { $0.cancel() }
    }

    func agent(withID id: String) -> AgentConnection? {
        conversationState.agent(withID: id)
    }

    func conversation(withID id: String) -> Conversation? {
        conversationState.conversation(withID: id)
    }

    func conversations(for agent: AgentConnection) -> [Conversation] {
        conversationState.conversations(for: agent)
    }

    func selectAgent(_ agent: AgentConnection) {
        conversationState.selectAgent(agent, currentDraft: prompt)
        prompt = conversationState.activeDraft
        agentAddressDraft = agent.address
        loadSkillsIfNeeded(for: agent)
    }

    func selectConversation(_ conversation: Conversation) {
        conversationState.selectConversation(conversation, currentDraft: prompt)
        prompt = conversationState.activeDraft
        if let agent = agent(for: conversation) {
            agentAddressDraft = agent.address
            loadSkillsIfNeeded(for: agent)
        }
    }

    func selectConversation(withID id: String) {
        guard let conversation = conversation(withID: id) else {
            return
        }
        selectConversation(conversation)
    }

    func createConversation(for agent: AgentConnection) -> Conversation {
        let conversation = conversationState.createConversation(for: agent, currentDraft: prompt)
        prompt = conversationState.activeDraft
        connectionStatesByConversationID[conversation.id] = .disconnected
        agentAddressDraft = agent.address
        return conversation
    }

    @discardableResult
    func saveAgent(id: String? = nil, name: String, address: String, token: String) -> AgentConnection? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard HostedAgentClient.isHostedAgentAddress(trimmedAddress) else {
            errorMessage = "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
            return nil
        }
        errorMessage = nil
        let next = conversationState.saveAgent(
            id: id,
            name: trimmedName,
            address: trimmedAddress,
            token: trimmedToken
        )
        agentAddressDraft = next.address
        return next
    }

    func switchToAgentForChat(_ agent: AgentConnection) {
        agentAddressDraft = agent.address
        if let conversation = conversations(for: agent).first {
            conversationState.selectConversation(conversation, currentDraft: prompt)
            prompt = conversationState.activeDraft
        } else {
            _ = createConversation(for: agent)
        }
        loadSkillsIfNeeded(for: agent)
    }

    func promptDidChange() {
        guard slashSkillQuery != nil, let activeAgent else {
            return
        }
        loadSkillsIfNeeded(for: activeAgent)
    }

    func prefetchActiveAgentSkills() {
        guard let activeAgent else {
            return
        }
        loadSkillsIfNeeded(for: activeAgent)
    }

    func selectSlashSkill(_ skill: AgentSkill) {
        prompt = "/\(skill.name) "
    }

    func deleteConversation(_ conversation: Conversation) {
        cancelPendingInteractions(forConversationID: conversation.id)
        pausedConversationIDs.remove(conversation.id)
        connectionStatesByConversationID[conversation.id] = nil
        conversationState.deleteConversation(conversation, currentDraft: prompt)
        prompt = conversationState.activeDraft
    }

    func deleteAgent(_ agent: AgentConnection) {
        let deletedConversationIDs = Set(conversations(for: agent).map(\.id))
        for conversationID in deletedConversationIDs {
            cancelPendingInteractions(forConversationID: conversationID)
            pausedConversationIDs.remove(conversationID)
            connectionStatesByConversationID[conversationID] = nil
        }
        conversationState.deleteAgent(agent, currentDraft: prompt)
        prompt = conversationState.activeDraft
        agentAddressDraft = activeAgent?.address ?? ""
    }

    /// Renames a conversation in place. Empty/whitespace titles and no-op renames are
    /// ignored. A rename is a metadata edit, not activity, so it deliberately does not
    /// reorder the list, bump `updatedAt`, or change the active conversation — only the
    /// title and its persisted row change.
    func renameConversation(_ conversation: Conversation, to title: String) {
        conversationState.renameConversation(conversation, to: title)
    }

    /// Filters conversations by title and message content via the store's indexed query,
    /// optionally scoped to a single agent. An empty/whitespace query returns all
    /// conversations (most-recent-first), matching the repository contract.
    func searchConversations(_ query: String, for agent: AgentConnection? = nil) -> [Conversation] {
        conversationState.searchConversations(query, for: agent)
    }

    func setMode(_ mode: ChatMode) {
        guard var conversation = activeConversation else {
            return
        }
        guard conversation.mode != mode else {
            return
        }
        conversation.mode = mode
        conversation.serverSession = session(conversation.serverSession, applying: mode, conversationID: conversation.id)
        conversation.serverSession?["updated"] = .number(Date().timeIntervalSince1970)
        upsert(conversation)
    }

    func connectToAgent() async -> AgentConnection? {
        let address = agentAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostedAgentClient.isHostedAgentAddress(address) else {
            let message = "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
            errorMessage = message
            connectionFailureMessage = message
            return nil
        }
        guard !isOffline else {
            let message = "You appear to be offline. Check your connection and try again."
            errorMessage = message
            connectionFailureMessage = "Connection failed. \(message)"
            return nil
        }
        guard !isConnecting else {
            return nil
        }

        isConnecting = true
        errorMessage = nil
        connectionFailureMessage = nil

        let agent: AgentConnection
        if let activeAgent, activeAgent.address == address {
            agent = activeAgent
        } else {
            agent = agents.first { $0.address == address } ?? AgentConnection(address: address)
        }
        var conversation = conversations(for: agent).first ?? Conversation(agentID: agent.id, agentAddress: address)
        setConnectionState(.reconnecting, forConversationID: conversation.id)

        do {
            let result = try await client.connect(agentAddress: address, conversation: conversation)
            if let session = result.serverSession {
                conversation.mode = serverMode(from: session, fallback: conversation.mode)
                conversation.serverSession = self.session(
                    session,
                    applying: conversation.mode,
                    conversationID: conversation.id
                )
            }
            let savedAgent = upsertAgent(agent)
            ensureDefaultConversation(for: savedAgent, seed: conversation)
            loadSkillsIfNeeded(for: savedAgent)
            setConnectionState(.connected, forConversationID: conversation.id)
            isConnecting = false
            return savedAgent
        } catch {
            let message = error.localizedDescription
            setConnectionState(.disconnected, forConversationID: conversation.id)
            errorMessage = message
            connectionFailureMessage = "Connection failed. \(message)"
            isConnecting = false
            return nil
        }
    }

    func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var conversation = activeConversation else {
            return
        }
        guard let agent = agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            errorMessage = "Connect to an agent before sending a message."
            return
        }

        prompt = ""
        errorMessage = nil
        conversation.agentID = agent.id
        conversation.agentAddress = agent.address
        conversation.title = conversation.title == "New mobile session" ? titleFromPrompt(text) : conversation.title
        let message = ChatMessage(role: .user, content: text, deliveryState: .queued)
        conversation.messages.append(message)
        upsert(conversation)
        pausedConversationIDs.remove(conversation.id)

        if !isOffline {
            startNextQueuedMessage(in: conversation.id)
        }
    }

    func retryMessage(_ message: ChatMessage) {
        guard message.role == .user,
              message.deliveryState == .failed || message.deliveryState == .cancelled else {
            return
        }
        guard var conversation = conversations.first(where: { candidate in
            candidate.messages.contains { $0.id == message.id }
        }) else {
            return
        }
        if let index = conversation.messages.firstIndex(where: { $0.id == message.id }) {
            conversation.messages[index].deliveryState = .queued
        }
        errorMessage = nil
        upsert(conversation)
        pausedConversationIDs.remove(conversation.id)

        if !isOffline {
            startNextQueuedMessage(in: conversation.id)
        }
    }

    func flushQueuedMessages() async {
        guard !isOffline else {
            return
        }

        for conversation in conversations {
            startNextQueuedMessage(in: conversation.id)
        }

        while !isOffline {
            let tasks = Array(deliveryTasksByConversationID.values)
            guard !tasks.isEmpty else {
                break
            }
            for task in tasks {
                await task.value
            }
        }
    }

    func stopActiveResponse() {
        guard let conversationID = activeConversationID,
              let task = deliveryTasksByConversationID[conversationID],
              let conversation = conversation(withID: conversationID),
              let agent = agent(for: conversation) else {
            return
        }

        pausedConversationIDs.insert(conversationID)
        guard settlePendingInteractionForStop(in: conversationID) else {
            task.cancel()
            return
        }

        let transport = client
        Task {
            await transport.waitForPendingInteractionResponses(
                agentAddress: agent.address,
                conversationID: conversationID
            )
            task.cancel()
        }
    }

    @discardableResult
    private func startNextQueuedMessage(in conversationID: String) -> Bool {
        guard !isOffline,
              !pausedConversationIDs.contains(conversationID),
              deliveryTasksByConversationID[conversationID] == nil,
              let conversation = conversation(withID: conversationID),
              let message = conversation.messages.first(where: {
                  $0.role == .user && $0.deliveryState == .queued
              }) else {
            return false
        }

        activeMessageIDsByConversationID[conversationID] = message.id
        processingConversationIDs.insert(conversationID)
        if connectionState(forConversationID: conversationID) != .connected {
            setConnectionState(.reconnecting, forConversationID: conversationID)
        }

        guard let deliveryTask = makeDeliveryTask(
            messageID: message.id,
            conversationID: conversationID
        ) else {
            activeMessageIDsByConversationID[conversationID] = nil
            processingConversationIDs.remove(conversationID)
            return false
        }
        deliveryTasksByConversationID[conversationID] = deliveryTask
        return true
    }

    private func makeDeliveryTask(messageID: String, conversationID: String) -> Task<Void, Never>? {
        guard let conversation = self.conversation(withID: conversationID),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              message.role == .user,
              let agent = agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return nil
        }
        var pending = conversation
        pending.messages.append(ChatMessage(role: .thinking, content: "Waiting for hosted agent…"))
        upsert(pending)

        let transport = client
        let interactionCoordinator = interactionCoordinator
        let owner = WeakChatViewModelReference(self)
        return Task { [transport, interactionCoordinator, owner] in
            defer {
                owner.value?.deliveryDidFinish(
                    messageID: messageID,
                    conversationID: conversationID
                )
            }
            do {
                let result = try await transport.sendPrompt(
                    agentAddress: agent.address,
                    conversation: pending,
                    prompt: message.content,
                    onEvent: { [owner] event in
                        owner.value?.apply(event, toConversationID: conversationID)
                    },
                    onInteraction: { [interactionCoordinator, owner] interaction in
                        await interactionCoordinator.handle(
                            interaction,
                            conversationID: conversationID
                        ) { [owner] in
                            owner.value?.conversation(withID: conversationID) != nil
                        }
                    }
                )
                try Task.checkCancellation()
                owner.value?.completeDelivery(
                    result,
                    messageID: messageID,
                    conversationID: conversationID
                )
            } catch is CancellationError {
                owner.value?.cancelDelivery(messageID: messageID, conversationID: conversationID)
            } catch {
                owner.value?.failDelivery(
                    error,
                    messageID: messageID,
                    conversationID: conversationID
                )
            }
        }
    }

    private func deliveryDidFinish(messageID: String, conversationID: String) {
        guard activeMessageIDsByConversationID[conversationID] == messageID else {
            return
        }
        deliveryTasksByConversationID[conversationID] = nil
        activeMessageIDsByConversationID[conversationID] = nil
        processingConversationIDs.remove(conversationID)
        if !isOffline, !pausedConversationIDs.contains(conversationID) {
            startNextQueuedMessage(in: conversationID)
        }
    }

    private func completeDelivery(
        _ result: HostedAgentResult,
        messageID: String,
        conversationID: String
    ) {
        guard var updated = conversation(withID: conversationID) else {
            return
        }
        updated.messages.removeAll { $0.role == .thinking }
        if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
            updated.messages[index].deliveryState = .sent
        }
        if let session = result.serverSession {
            updated.mode = serverMode(from: session, fallback: updated.mode)
            updated.serverSession = self.session(
                session,
                applying: updated.mode,
                conversationID: updated.id
            )
        }
        updated.messages.append(ChatMessage(role: .agent, content: result.output ?? ""))
        setConnectionState(.connected, forConversationID: conversationID)
        upsert(updated)
    }

    private func failDelivery(
        _ error: Error,
        messageID: String,
        conversationID: String
    ) {
        guard var updated = conversation(withID: conversationID) else {
            return
        }
        updated.messages.removeAll { $0.role == .thinking }
        if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
            updated.messages[index].deliveryState = .failed
        }
        if activeConversationID == conversationID {
            errorMessage = error.localizedDescription
        }
        setConnectionState(.disconnected, forConversationID: conversationID)
        upsert(updated)
    }

    private func cancelDelivery(messageID: String, conversationID: String) {
        guard var updated = conversation(withID: conversationID) else {
            return
        }
        updated.messages.removeAll { $0.role == .thinking }
        if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
            updated.messages[index].deliveryState = .cancelled
        }
        setConnectionState(.disconnected, forConversationID: conversationID)
        upsert(updated)
    }

    private func handleNetworkChange(isOnline: Bool) {
        let wasOffline = isOffline
        isOffline = !isOnline
        guard isOnline else {
            if !wasOffline {
                // Fresh drop: surface the banner again even if it was dismissed earlier.
                isOfflineBannerDismissed = false
            }
            for conversationID in conversations.map(\.id) {
                connectionStatesByConversationID[conversationID] = .disconnected
            }
            startRecoveryProbing()
            return
        }
        probeTask?.cancel()
        guard wasOffline else {
            return
        }
        recoveryTask = Task {
            await self.reconnect()
            await self.flushQueuedMessages()
        }
    }

    private func apply(_ event: HostedAgentEvent, toConversationID conversationID: String) {
        guard var conversation = conversation(withID: conversationID) else {
            return
        }

        let persistence: ConversationPersistence
        switch event {
        case .toolCall(let id, let name, let arguments):
            guard !conversation.messages.contains(where: { $0.id == id }) else {
                return
            }
            conversation.messages.append(
                ChatMessage(
                    id: id,
                    role: .tool,
                    content: "",
                    toolName: name,
                    toolArguments: arguments,
                    toolState: .running
                )
            )
            persistence = .message(id: id)
        case .toolResult(let id, let name, let output, let state):
            if let index = conversation.messages.firstIndex(where: { $0.id == id && $0.role == .tool }) {
                conversation.messages[index].toolName = name ?? conversation.messages[index].toolName
                conversation.messages[index].content = output
                conversation.messages[index].toolState = state
            } else {
                conversation.messages.append(
                    ChatMessage(
                        id: id,
                        role: .tool,
                        content: output,
                        toolName: name ?? "tool",
                        toolState: state
                    )
                )
            }
            persistence = .message(id: id)
        case .modeChanged(let mode):
            conversation.mode = mode
            conversation.serverSession = session(
                conversation.serverSession,
                applying: mode,
                conversationID: conversationID
            )
            persistence = .metadata
        }

        upsert(conversation, persistence: persistence)
    }

    func allowPendingApprovalOnce(id: String) {
        resolvePendingApproval(id: id, with: .allowOnce)
    }

    func trustPendingApprovalForSession(id: String) {
        resolvePendingApproval(id: id, with: .allowSession)
    }

    func rejectPendingApproval(id: String) {
        resolvePendingApproval(id: id, with: .rejectSoft(feedback: nil))
    }

    func stopPendingApproval(id: String) {
        guard activePendingApproval?.id == id else {
            return
        }
        stopActiveResponse()
    }

    func explainPendingApproval(id: String) {
        resolvePendingApproval(id: id, with: .rejectExplain(feedback: nil))
    }

    func continueUlw(id: String, turns: Int = 100) {
        resolvePendingUlwCheckpoint(id: id, with: .continueWork(turns: turns))
    }

    func switchModeFromUlwCheckpoint(id: String, to mode: ChatMode) {
        guard activePendingUlwCheckpoint?.id == id else {
            return
        }
        setMode(mode)
        resolvePendingUlwCheckpoint(id: id, with: .switchMode(mode))
    }

    func approvePendingPlan(id: String) {
        resolvePendingPlanReview(id: id, with: .approve)
    }

    func requestPlanChanges(id: String, feedback: String?) {
        resolvePendingPlanReview(id: id, with: .requestChanges(feedback: feedback))
    }

    func answerPendingAskUser(id: String, answer: String) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .askUser(.answer(answer))
        )
    }

    private func resolvePendingApproval(id: String, with decision: ApprovalDecision) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .approval(decision)
        )
    }

    private func resolvePendingUlwCheckpoint(id: String, with decision: UlwCheckpointDecision) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .ulwCheckpoint(decision)
        )
    }

    private func resolvePendingPlanReview(id: String, with decision: PlanReviewDecision) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .planReview(decision)
        )
    }

    private func cancelPendingInteractions(forConversationID conversationID: String) {
        interactionCoordinator.cancelInteractions(for: conversationID)
        deliveryTasksByConversationID[conversationID]?.cancel()
    }

    private func settlePendingInteractionForStop(in conversationID: String) -> Bool {
        interactionCoordinator.cancelInteractions(for: conversationID)
    }

    /// The path monitor can lag well behind the actual network (especially on the
    /// simulator), so while offline we also probe the agent directly on a timer and
    /// recover as soon as a probe gets through — no monitor update or user tap needed.
    private func startRecoveryProbing() {
        probeTask?.cancel()
        probeTask = Task {
            while !Task.isCancelled && self.isOffline {
                try? await Task.sleep(nanoseconds: UInt64(self.probeInterval * 1_000_000_000))
                guard !Task.isCancelled, self.isOffline else {
                    return
                }
                if await self.probeReconnect() {
                    self.isOffline = false
                    await self.flushQueuedMessages()
                    return
                }
            }
        }
    }

    /// Quiet reachability check. Unlike reconnect(), a failed probe leaves all UI state
    /// untouched so background retries don't flash error banners every few seconds.
    private func probeReconnect() async -> Bool {
        guard let conversation = activeConversation,
              let agent = agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return false
        }
        do {
            let result = try await client.connect(agentAddress: agent.address, conversation: conversation)
            if let session = result.serverSession {
                var updated = self.conversation(withID: conversation.id) ?? conversation
                updated.agentID = agent.id
                updated.agentAddress = agent.address
                updated.serverSession = self.session(session, applying: updated.mode, conversationID: updated.id)
                self.upsert(updated)
            }
            setConnectionState(.connected, forConversationID: conversation.id)
            refreshSkills(for: agent)
            return true
        } catch {
            return false
        }
    }

    func dismissOfflineBanner() {
        isOfflineBannerDismissed = true
    }

    /// Manual recovery for when the path monitor is slow to notice the network is back
    /// (common on the simulator): attempt a real reconnect, and if it succeeds treat
    /// the app as online again and flush the queue without waiting for the monitor.
    func retryConnectivity() {
        guard isOffline, let conversationID = activeConversationID else {
            return
        }
        recoveryTask = Task {
            await self.reconnect()
            if self.connectionState(forConversationID: conversationID) == .connected {
                self.isOffline = false
                await self.flushQueuedMessages()
            }
        }
    }

    func reconnect() async {
        guard let conversation = activeConversation,
              let agent = agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return
        }
        errorMessage = nil
        setConnectionState(.reconnecting, forConversationID: conversation.id)
        do {
            let result = try await client.connect(agentAddress: agent.address, conversation: conversation)
            if let session = result.serverSession {
                var updated = self.conversation(withID: conversation.id) ?? conversation
                updated.agentID = agent.id
                updated.agentAddress = agent.address
                updated.serverSession = self.session(session, applying: updated.mode, conversationID: updated.id)
                self.upsert(updated)
            }
            refreshSkills(for: agent)
            setConnectionState(.connected, forConversationID: conversation.id)
        } catch {
            setConnectionState(.disconnected, forConversationID: conversation.id)
            if activeConversationID == conversation.id {
                errorMessage = error.localizedDescription
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func upsertAgent(_ agent: AgentConnection) -> AgentConnection {
        let next = conversationState.upsertAgent(agent)
        agentAddressDraft = next.address
        return next
    }

    private func ensureDefaultConversation(for agent: AgentConnection, seed: Conversation) {
        var normalizedSeed = seed
        if let existing = conversations(for: agent).first,
           let session = seed.serverSession {
            normalizedSeed.serverSession = self.session(
                session,
                applying: existing.mode,
                conversationID: existing.id
            )
        }
        conversationState.ensureDefaultConversation(
            for: agent,
            seed: normalizedSeed,
            currentDraft: prompt
        )
        prompt = conversationState.activeDraft
    }

    private func upsert(
        _ conversation: Conversation,
        persistence: ConversationPersistence = .full
    ) {
        conversationState.upsert(conversation, persistence: persistence)
    }

    private func setConnectionState(
        _ state: ConnectionState,
        forConversationID conversationID: String
    ) {
        connectionStatesByConversationID[conversationID] = state
    }

    private func connectionState(forConversationID conversationID: String) -> ConnectionState {
        connectionStatesByConversationID[conversationID] ?? .disconnected
    }

    private func agent(for conversation: Conversation) -> AgentConnection? {
        conversationState.agent(for: conversation)
    }

    private func conversationBelongsToAgent(_ conversation: Conversation, _ agent: AgentConnection) -> Bool {
        conversationState.conversationBelongsToAgent(conversation, agent)
    }

    private func session(_ session: [String: JSONValue]?, applying mode: ChatMode, conversationID: String) -> [String: JSONValue] {
        var next = session ?? [:]
        next["session_id"] = .string(conversationID)
        next["mode"] = .string(mode.rawValue)
        next.removeValue(forKey: "ulw_turns")
        next.removeValue(forKey: "ulw_turns_used")
        next.removeValue(forKey: "ulw_prompt")
        next.removeValue(forKey: "skip_tool_approval")
        return next
    }

    private func serverMode(from session: [String: JSONValue], fallback: ChatMode) -> ChatMode {
        guard let rawMode = session["mode"]?.stringValue,
              let mode = ChatMode(rawValue: rawMode) else {
            return fallback
        }
        return mode
    }

    private var slashSkillQuery: String? {
        guard prompt.hasPrefix("/") else {
            return nil
        }
        let query = String(prompt.dropFirst())
        guard !query.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        return query
    }

    private func loadSkillsIfNeeded(
        for agent: AgentConnection,
        allowWhileOffline: Bool = false
    ) {
        let address = agent.address
        guard (allowWhileOffline || !isOffline),
              HostedAgentClient.isHostedAgentAddress(address),
              skillsByAgentAddress[address] == nil,
              skillFetchTasks[address] == nil else {
            return
        }

        skillFetchTasks[address] = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.skillFetchTasks[address] = nil
            }
            do {
                let skills = try await self.client.fetchSkills(agentAddress: address)
                guard !Task.isCancelled else {
                    return
                }
                self.skillsByAgentAddress[address] = skills.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            } catch {
                // Slash discovery is optional. Leave the command editable and retry
                // the next time the user invokes the picker.
            }
        }
    }

    private func refreshSkills(for agent: AgentConnection) {
        skillsByAgentAddress[agent.address] = nil
        loadSkillsIfNeeded(for: agent, allowWhileOffline: true)
    }

    private func titleFromPrompt(_ text: String) -> String {
        if text.count > 38 {
            return String(text.prefix(35)) + "..."
        }
        return text
    }
}
