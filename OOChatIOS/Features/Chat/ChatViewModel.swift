import Combine
import Foundation
import SwiftUI

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
    @Published private var skillsByAgentAddress: [String: [AgentSkill]] = [:]

    var shouldShowOfflineBanner: Bool {
        isOffline && !isOfflineBannerDismissed
    }

    private(set) var recoveryTask: Task<Void, Never>?
    private(set) var probeTask: Task<Void, Never>?
    private var skillFetchTasks: [String: Task<Void, Never>] = [:]
    private let interactionCoordinator: InteractionCoordinator
    private let deliveryCoordinator: MessageDeliveryCoordinator
    private var interactionChangeCancellable: AnyCancellable?
    private var deliveryChangeCancellable: AnyCancellable?
    private var conversationStateChangeCancellable: AnyCancellable?
    private var persistenceErrorCancellable: AnyCancellable?

    /// Seconds between silent reachability probes while offline. Overridable in tests.
    var probeInterval: TimeInterval = 5

    private let conversationState: ConversationState
    private let identityStore: IdentityStore
    private let networkMonitor: NetworkPathMonitoring
    private var client: HostedAgentTransport

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
        return deliveryCoordinator.isProcessing(conversationID: activeConversationID)
    }

    var sendTask: Task<Void, Never>? {
        deliveryCoordinator.task(for: activeConversationID)
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
        deliveryCoordinator.isProcessing(conversationID: conversationID)
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
        let interactionCoordinator = InteractionCoordinator()
        let transport = client ?? HostedAgentClient(identityStore: identityStore)
        self.conversationState = conversationState
        self.interactionCoordinator = interactionCoordinator
        self.deliveryCoordinator = MessageDeliveryCoordinator(
            conversationState: conversationState,
            interactionCoordinator: interactionCoordinator,
            transport: transport
        )
        self.identityStore = identityStore
        self.client = transport
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
        deliveryCoordinator.connectionState = { [weak self] conversationID in
            self?.connectionState(forConversationID: conversationID) ?? .disconnected
        }
        deliveryCoordinator.onConnectionStateChange = { [weak self] conversationID, state in
            self?.setConnectionState(state, forConversationID: conversationID)
        }
        deliveryCoordinator.onDeliveryError = { [weak self] conversationID, message in
            guard self?.activeConversationID == conversationID else {
                return
            }
            self?.errorMessage = message
        }
        interactionChangeCancellable = interactionCoordinator.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        deliveryChangeCancellable = deliveryCoordinator.objectWillChange.sink { [weak self] in
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
        connectionStatesByConversationID[conversation.id] = nil
        conversationState.deleteConversation(conversation, currentDraft: prompt)
        prompt = conversationState.activeDraft
    }

    func deleteAgent(_ agent: AgentConnection) {
        let deletedConversationIDs = Set(conversations(for: agent).map(\.id))
        for conversationID in deletedConversationIDs {
            cancelPendingInteractions(forConversationID: conversationID)
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
        conversation.serverSession = HostedAgentSessionState.applying(
            mode,
            to: conversation.serverSession,
            conversationID: conversation.id
        )
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
                conversation.mode = HostedAgentSessionState.mode(from: session, fallback: conversation.mode)
                conversation.serverSession = HostedAgentSessionState.applying(
                    conversation.mode,
                    to: session,
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
        guard !text.isEmpty else {
            return
        }
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        switch deliveryCoordinator.enqueuePrompt(text) {
        case .queued:
            prompt = ""
            errorMessage = nil
        case .rejected(let message):
            errorMessage = message
        }
    }

    func retryMessage(_ message: ChatMessage) {
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        if deliveryCoordinator.retryMessage(message) {
            errorMessage = nil
        }
    }

    func flushQueuedMessages() async {
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        await deliveryCoordinator.flushQueuedMessages()
    }

    func stopActiveResponse() {
        deliveryCoordinator.stopActiveResponse()
    }

    private func handleNetworkChange(isOnline: Bool) {
        let wasOffline = isOffline
        isOffline = !isOnline
        deliveryCoordinator.setDeliveryEnabled(isOnline)
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
        deliveryCoordinator.cancelDeliveryAndInteractions(for: conversationID)
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
                updated.serverSession = HostedAgentSessionState.applying(
                    updated.mode,
                    to: session,
                    conversationID: updated.id
                )
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
                updated.serverSession = HostedAgentSessionState.applying(
                    updated.mode,
                    to: session,
                    conversationID: updated.id
                )
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
            normalizedSeed.serverSession = HostedAgentSessionState.applying(
                existing.mode,
                to: session,
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

}
