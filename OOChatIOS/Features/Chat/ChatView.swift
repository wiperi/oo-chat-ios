import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void

    init(
        viewModel: ChatViewModel,
        showsComposer: Bool = true,
        showsSidebarButton: Bool = true,
        onOpenSidebar: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.showsComposer = showsComposer
        self.showsSidebarButton = showsSidebarButton
        self.onOpenSidebar = onOpenSidebar
    }

    var body: some View {
        NavigationStack {
            ChatScreen(
                viewModel: viewModel,
                showsComposer: showsComposer,
                showsSidebarButton: showsSidebarButton,
                onOpenSidebar: onOpenSidebar
            )
        }
    }
}

struct ChatScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    var showsSidebarButton: Bool = true
    let onOpenSidebar: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bottomAnchorY: CGFloat = 0
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var shouldFollowLatest = true
    private let bottomAnchorID = "chat.bottomAnchor"
    private let scrollCoordinateSpace = "chat.scroll"

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = viewModel.activeConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(timelineEntries(for: conversation)) { entry in
                                timelineView(for: entry)
                                    .id(entry.id)
                                    .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let approval = viewModel.activePendingApproval {
                                ApprovalCard(approval: approval) {
                                    viewModel.allowPendingApprovalOnce(id: approval.id)
                                } onTrustSession: {
                                    viewModel.trustPendingApprovalForSession(id: approval.id)
                                } onReject: {
                                    viewModel.rejectPendingApproval(id: approval.id)
                                } onStop: {
                                    viewModel.stopPendingApproval(id: approval.id)
                                } onExplain: {
                                    viewModel.explainPendingApproval(id: approval.id)
                                }
                                .id("pendingApproval")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let checkpoint = viewModel.activePendingUlwCheckpoint {
                                UlwCheckpointCard(checkpoint: checkpoint) {
                                    viewModel.continueUlw(id: checkpoint.id)
                                } onAcceptEdits: {
                                    viewModel.switchModeFromUlwCheckpoint(id: checkpoint.id, to: .accept)
                                } onSafeMode: {
                                    viewModel.switchModeFromUlwCheckpoint(id: checkpoint.id, to: .safe)
                                }
                                .id("pendingUlwCheckpoint")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let review = viewModel.activePendingPlanReview {
                                PlanReviewCard(review: review) {
                                    viewModel.approvePendingPlan(id: review.id)
                                } onRequestChanges: { feedback in
                                    viewModel.requestPlanChanges(id: review.id, feedback: feedback)
                                }
                                .id("pendingPlanReview")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let pending = viewModel.activePendingAskUser {
                                AskUserCard(pending: pending) { answer in
                                    viewModel.answerPendingAskUser(id: pending.id, answer: answer)
                                }
                                .id("pendingAskUser")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ChatBottomAnchorPreferenceKey.self,
                                            value: geometry.frame(
                                                in: .named(scrollCoordinateSpace)
                                            ).maxY
                                        )
                                    }
                                }
                        }
                        .id(conversation.id)
                        .transition(conversationTransition)
                        .padding(.horizontal)
                        .padding(.vertical, 16)
                        .frame(maxWidth: ChatReadableWidth.maximum)
                        .frame(maxWidth: .infinity)
                        .animation(
                            AppMotion.contentArrival(reduceMotion: reduceMotion),
                            value: conversation.messages.map(\.id)
                        )
                        .animation(
                            AppMotion.contentArrival(reduceMotion: reduceMotion),
                            value: viewModel.pendingInteractionID
                        )
                    }
                    .coordinateSpace(name: scrollCoordinateSpace)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ChatViewportHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: scrollUpdate(for: conversation)) { previous, current in
                        guard shouldFollowLatest else {
                            return
                        }
                        scrollToBottom(
                            proxy,
                            animated: current.isNewMessage(comparedTo: previous)
                        )
                    }
                    .onChange(of: viewModel.pendingInteractionID) {
                        if let interactionID = viewModel.pendingInteractionID {
                            withAnimation(AppMotion.contentArrival(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(scrollTarget(for: interactionID), anchor: .bottom)
                            }
                        }
                    }
                    .onPreferenceChange(ChatBottomAnchorPreferenceKey.self) { value in
                        bottomAnchorY = value
                        updateFollowLatest()
                    }
                    .onPreferenceChange(ChatViewportHeightPreferenceKey.self) { value in
                        scrollViewportHeight = value
                        updateFollowLatest()
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if showsComposer {
                            Composer(viewModel: viewModel)
                                .padding(.top, 8)
                                .background {
                                    Color(.systemBackground)
                                        .ignoresSafeArea(edges: .bottom)
                                }
                        }
                    }
                }
            } else {
                ContentUnavailableView("No Conversation", systemImage: "bubble.left")
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(viewModel.activeConversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(viewModel.activeConversation?.title ?? "Chat")
                        .font(.headline)
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    HStack {
                        StatusPill(state: viewModel.connectionState)
                    }
                    .contentTransition(.opacity)
                }
                .animation(
                    AppMotion.stateChange(reduceMotion: reduceMotion),
                    value: viewModel.activeConversationID
                )
            }

            if showsSidebarButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onOpenSidebar()
                    } label: {
                        Image(systemName: "sidebar.left")
                            .overlay(alignment: .topTrailing) {
                                if let state = viewModel.backgroundActivityState {
                                    ConversationStatusDot(state: state)
                                        .offset(x: 4, y: -3)
                                        .transition(AppMotion.statusTransition(reduceMotion: reduceMotion))
                                }
                            }
                            .animation(AppMotion.statusChange, value: viewModel.backgroundActivityState)
                    }
                    .accessibilityLabel(backgroundAttentionLabel)
                }
            }
        }
    }

    private var backgroundAttentionLabel: String {
        switch viewModel.backgroundActivityState {
        case .actionRequired:
            return "Open sidebar, action required"
        case .failedDelivery:
            return "Open sidebar, a message failed to send"
        case .completedUnread:
            return "Open sidebar, background task completed"
        case .working, nil:
            return "Open sidebar"
        }
    }

    private func scrollTarget(for interactionID: String) -> String {
        if interactionID == viewModel.activePendingApproval?.id {
            return "pendingApproval"
        }
        if interactionID == viewModel.activePendingUlwCheckpoint?.id {
            return "pendingUlwCheckpoint"
        }
        if interactionID == viewModel.activePendingPlanReview?.id {
            return "pendingPlanReview"
        }
        return "pendingAskUser"
    }

    private func shouldShowMessage(_ message: ChatMessage, in conversationID: String) -> Bool {
        !viewModel.isToolCallCoveredByPendingApproval(message, in: conversationID)
    }

    private func timelineEntries(for conversation: Conversation) -> [ChatTimelineEntry] {
        ChatTimelineBuilder.entries(
            from: conversation.messages.filter {
                shouldShowMessage($0, in: conversation.id)
            }
        )
    }

    @ViewBuilder
    private func timelineView(for entry: ChatTimelineEntry) -> some View {
        switch entry {
        case .message(let message):
            MessageBubble(message: message) {
                viewModel.retryMessage(message)
            }
        case .toolCallGroup(let messages):
            ToolCallGroupView(messages: messages)
        }
    }

    private func scrollUpdate(for conversation: Conversation) -> ChatScrollUpdate {
        let message = conversation.messages.last
        return ChatScrollUpdate(
            conversationID: conversation.id,
            messageCount: conversation.messages.count,
            messageID: message?.id,
            contentLength: message?.content.count ?? 0,
            deliveryState: message?.deliveryState.rawValue ?? "",
            toolState: message?.toolState?.rawValue ?? ""
        )
    }

    private func updateFollowLatest() {
        guard scrollViewportHeight > 0 else {
            return
        }
        shouldFollowLatest = bottomAnchorY - scrollViewportHeight
            <= ChatScrollMetrics.followThreshold
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private var conversationTransition: AnyTransition {
        guard !reduceMotion else {
            return .opacity
        }

        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 10, y: 0)),
            removal: .opacity
        )
    }
}

private struct ChatScrollUpdate: Equatable {
    let conversationID: String
    let messageCount: Int
    let messageID: String?
    /// Length rather than the text itself: this is rebuilt on every redraw purely to detect
    /// change, and a streamed reply still grows it by one on each token — copying the whole
    /// body into an Equatable struct per token is pure allocation churn.
    let contentLength: Int
    let deliveryState: String
    let toolState: String

    func isNewMessage(comparedTo previous: ChatScrollUpdate) -> Bool {
        conversationID == previous.conversationID
            && (messageCount != previous.messageCount || messageID != previous.messageID)
    }
}

private enum ChatScrollMetrics {
    static let followThreshold: CGFloat = 80
}

// Caps the message column so text stays at a readable line length on iPad, where the
// content region is far wider than any phone. Below this width it is inert, so compact
// layouts keep their existing full-bleed behavior.
enum ChatReadableWidth {
    static let maximum: CGFloat = 720
}

private struct ChatBottomAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum ChatTimelineEntry: Identifiable, Equatable {
    case message(ChatMessage)
    case toolCallGroup([ChatMessage])

    var id: String {
        switch self {
        case .message(let message):
            return message.id
        case .toolCallGroup(let messages):
            return messages.first?.id ?? "toolCallGroup"
        }
    }
}

enum ChatTimelineBuilder {
    static func entries(from messages: [ChatMessage]) -> [ChatTimelineEntry] {
        var entries: [ChatTimelineEntry] = []
        var pendingToolCalls: [ChatMessage] = []

        func appendPendingToolCalls() {
            guard !pendingToolCalls.isEmpty else {
                return
            }

            if pendingToolCalls.count == 1, let message = pendingToolCalls.first {
                entries.append(.message(message))
            } else {
                entries.append(.toolCallGroup(pendingToolCalls))
            }
            pendingToolCalls.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if message.role == .tool {
                pendingToolCalls.append(message)
            } else {
                appendPendingToolCalls()
                entries.append(.message(message))
            }
        }

        appendPendingToolCalls()
        return entries
    }
}
