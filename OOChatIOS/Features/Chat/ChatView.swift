import SwiftUI
// The main chat view message and conversations of the app.
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    let onOpenSidebar: () -> Void

    init(
        viewModel: ChatViewModel,
        showsComposer: Bool = true,
        onOpenSidebar: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.showsComposer = showsComposer
        self.onOpenSidebar = onOpenSidebar
    }

    var body: some View {
        NavigationStack {
            ChatScreen(
                viewModel: viewModel,
                showsComposer: showsComposer,
                onOpenSidebar: onOpenSidebar
            )
        }
    }
}

struct ChatScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    let onOpenSidebar: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bottomAnchorID = "chat.bottomAnchor"

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
                        }
                        .id(conversation.id)
                        .transition(conversationTransition)
                        .padding(.horizontal)
                        .padding(.vertical, 16)
                        .animation(
                            AppMotion.contentArrival(reduceMotion: reduceMotion),
                            value: conversation.messages.map(\.id)
                        )
                        .animation(
                            AppMotion.contentArrival(reduceMotion: reduceMotion),
                            value: viewModel.pendingInteractionID
                        )
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: scrollSignature(for: conversation)) {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: viewModel.pendingInteractionID) {
                        if let interactionID = viewModel.pendingInteractionID {
                            withAnimation(AppMotion.contentArrival(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(scrollTarget(for: interactionID), anchor: .bottom)
                            }
                        }
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

            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onOpenSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .overlay(alignment: .topTrailing) {
                            if viewModel.hasBackgroundPendingInteraction {
                                Circle()
                                    .fill(Color(.systemOrange))
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -3)
                            }
                        }
                }
                .accessibilityLabel(
                    viewModel.hasBackgroundPendingInteraction
                        ? "Open sidebar, approval required"
                        : "Open sidebar"
                )
            }
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
        !isToolCallCoveredByPendingApproval(message, in: conversationID)
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

    private func isToolCallCoveredByPendingApproval(_ message: ChatMessage, in conversationID: String) -> Bool {
        guard let approval = viewModel.pendingApproval,
              approval.conversationID == conversationID,
              message.role == .tool,
              message.toolState == .running,
              message.content.isEmpty else {
            return false
        }

        let messageArguments = message.toolArguments ?? [:]
        guard messageArguments == approval.request.arguments else {
            return false
        }

        if message.toolName == approval.request.tool {
            return true
        }

        return ToolActionSummary.requested(
            toolName: message.toolName ?? "tool",
            arguments: messageArguments
        ) == ToolActionSummary.requested(
            toolName: approval.request.tool,
            arguments: approval.request.arguments
        )
    }

    private func scrollSignature(for conversation: Conversation) -> String {
        guard let message = conversation.messages.last else {
            return conversation.id
        }

        return [
            conversation.id,
            String(conversation.messages.count),
            message.id,
            message.content,
            message.deliveryState.rawValue,
            message.toolState?.rawValue ?? ""
        ].joined(separator: "|")
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
