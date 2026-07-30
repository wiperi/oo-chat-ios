import Combine
import Foundation

enum ConnectionRecoveryTrigger {
    case probe
    case pathRestored
    case userRetry
}

@MainActor
final class ConnectionRecoveryCoordinator: ObservableObject {
    @Published private(set) var isOffline = false
    @Published private(set) var isOfflineBannerDismissed = false
    @Published private(set) var isRetryingConnectivity = false
    @Published private var statesByConversationID: [String: ConnectionState] = [:]

    private(set) var recoveryTask: Task<Void, Never>?
    private(set) var probeTask: Task<Void, Never>?
    private(set) var launchFlushTask: Task<Void, Never>?
    private(set) var disconnectTask: Task<Void, Never>?
    /// Clamped on read: `UInt64(negative)` traps, so a non-positive interval would crash the
    /// probe loop rather than just polling too eagerly.
    var probeInterval: TimeInterval = 5 {
        didSet {
            probeInterval = max(0.1, probeInterval)
        }
    }

    var onRecoveryError: ((String, Error) -> Void)?
    var onReconnect: ((AgentConnection) -> Void)?

    private var recoveryConversationID: String?
    private var recoveryGeneration = 0
    private var probeConversationID: String?
    private var hasFlushedOnLaunch = false
    private let conversationState: ConversationState
    private let deliveryCoordinator: MessageDeliveryCoordinator
    private let networkMonitor: NetworkPathMonitoring
    private var transport: HostedAgentTransport

    init(
        conversationState: ConversationState,
        deliveryCoordinator: MessageDeliveryCoordinator,
        networkMonitor: NetworkPathMonitoring,
        transport: HostedAgentTransport
    ) {
        self.conversationState = conversationState
        self.deliveryCoordinator = deliveryCoordinator
        self.networkMonitor = networkMonitor
        self.transport = transport

        self.networkMonitor.onUpdate = { [weak self] isOnline in
            self?.handleNetworkChange(isOnline: isOnline)
        }
        self.transport.onConnectionStateChange = { [weak self] conversationID, state in
            self?.setConnectionState(state, forConversationID: conversationID)
        }
        self.deliveryCoordinator.connectionState = { [weak self] conversationID in
            self?.connectionState(forConversationID: conversationID) ?? .disconnected
        }
        self.deliveryCoordinator.onConnectionStateChange = { [weak self] conversationID, state in
            self?.setConnectionState(state, forConversationID: conversationID)
        }
    }

    deinit {
        networkMonitor.cancel()
        probeTask?.cancel()
        recoveryTask?.cancel()
        launchFlushTask?.cancel()
        disconnectTask?.cancel()
    }

    var shouldShowOfflineBanner: Bool {
        isOffline && !isOfflineBannerDismissed
    }

    func start() {
        networkMonitor.start()
    }

    func connectionState(forConversationID conversationID: String) -> ConnectionState {
        statesByConversationID[conversationID] ?? .disconnected
    }

    func setConnectionState(
        _ state: ConnectionState,
        forConversationID conversationID: String
    ) {
        statesByConversationID[conversationID] = state
    }

    func removeConnectionState(forConversationID conversationID: String) {
        statesByConversationID[conversationID] = nil
        cancelRecovery(forConversationID: conversationID)
    }

    func dismissOfflineBanner() {
        isOfflineBannerDismissed = true
    }

    func retryConnectivity() {
        guard isOffline, let conversationID = conversationState.activeConversationID else {
            return
        }
        startRecovery(forConversationID: conversationID, trigger: .userRetry)
    }

    func reconnectActiveConversation() async {
        guard let conversationID = conversationState.activeConversationID else {
            return
        }
        _ = await reconnect(conversationID: conversationID, trigger: .userRetry)
    }

    private func handleNetworkChange(isOnline: Bool) {
        let wasOffline = isOffline
        isOffline = !isOnline
        deliveryCoordinator.setDeliveryEnabled(isOnline)

        guard isOnline else {
            recoveryTask?.cancel()
            recoveryConversationID = nil
            if !wasOffline {
                isOfflineBannerDismissed = false
            }
            for conversationID in conversationState.conversations.map(\.id) {
                statesByConversationID[conversationID] = .disconnected
            }
            noteNetworkLost()
            startRecoveryProbing(forConversationID: conversationState.activeConversationID)
            return
        }

        probeTask?.cancel()
        probeConversationID = nil
        // Messages queued in a previous session are only drained by an offline→online
        // transition, which never happens when the app launches already online. Drain
        // them once on the first online path update instead.
        if !hasFlushedOnLaunch {
            hasFlushedOnLaunch = true
            launchFlushTask = Task { [weak self] in
                await self?.deliveryCoordinator.flushQueuedMessages()
            }
        }
        guard wasOffline, let conversationID = conversationState.activeConversationID else {
            return
        }
        startRecovery(forConversationID: conversationID, trigger: .pathRestored)
    }

    private func noteNetworkLost() {
        disconnectTask?.cancel()
        let transport = transport
        disconnectTask = Task {
            await transport.noteNetworkLost()
        }
    }

    private func startRecovery(
        forConversationID conversationID: String,
        trigger: ConnectionRecoveryTrigger
    ) {
        recoveryTask?.cancel()
        recoveryConversationID = conversationID
        recoveryGeneration += 1
        let generation = recoveryGeneration
        isRetryingConnectivity = trigger == .userRetry
        recoveryTask = Task { [weak self] in
            guard let self else {
                return
            }
            // A cancelled attempt finishes after its replacement started
            defer {
                if self.recoveryGeneration == generation {
                    self.isRetryingConnectivity = false
                }
            }
            let connected = await self.reconnect(
                conversationID: conversationID,
                trigger: trigger
            )
            // A retry only counts if it actually reconnected
            guard !Task.isCancelled,
                  trigger != .userRetry || connected else {
                return
            }
            if connected {
                self.isOffline = false
            }
            self.deliveryCoordinator.setDeliveryEnabled(!self.isOffline)
            await self.deliveryCoordinator.flushQueuedMessages()
        }
    }

    private func startRecoveryProbing(forConversationID conversationID: String?) {
        probeTask?.cancel()
        probeConversationID = conversationID
        guard let conversationID else {
            return
        }

        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.probeInterval,
                      self?.isOffline == true else {
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled,
                      self?.isOffline == true else {
                    return
                }
                if await self?.reconnect(
                    conversationID: conversationID,
                    trigger: .probe
                ) == true {
                    guard !Task.isCancelled, let self else {
                        return
                    }
                    self.isOffline = false
                    self.deliveryCoordinator.setDeliveryEnabled(true)
                    await self.deliveryCoordinator.flushQueuedMessages()
                    return
                }
            }
        }
    }

    private func reconnect(
        conversationID: String,
        trigger: ConnectionRecoveryTrigger
    ) async -> Bool {
        guard let conversation = conversationState.conversation(withID: conversationID),
              let agent = conversationState.agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return false
        }

        await disconnectTask?.value

        let silently = trigger == .probe
        if !silently {
            setConnectionState(.reconnecting, forConversationID: conversationID)
        }
        do {
            let result = try await transport.connect(
                agentAddress: agent.address,
                conversation: conversation
            )
            try Task.checkCancellation()
            guard conversationState.conversation(withID: conversationID) != nil else {
                return false
            }
            if let session = result.serverSession {
                var updated = conversationState.conversation(withID: conversationID) ?? conversation
                updated.agentID = agent.id
                updated.agentAddress = agent.address
                updated.serverSession = HostedAgentSessionState.applying(
                    updated.mode,
                    to: session,
                    conversationID: updated.id
                )
                conversationState.upsert(updated)
            }
            setConnectionState(.connected, forConversationID: conversationID)
            onReconnect?(agent)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let clientError = error as? HostedAgentClientError, case .busy = clientError {
                return false
            }
            if !silently {
                setConnectionState(.disconnected, forConversationID: conversationID)
                if conversationState.activeConversationID == conversationID {
                    onRecoveryError?(conversationID, error)
                }
            }
            return false
        }
    }

    private func cancelRecovery(forConversationID conversationID: String) {
        if recoveryConversationID == conversationID {
            recoveryTask?.cancel()
            recoveryConversationID = nil
        }
        if probeConversationID == conversationID {
            probeTask?.cancel()
            probeConversationID = nil
        }
    }
}
