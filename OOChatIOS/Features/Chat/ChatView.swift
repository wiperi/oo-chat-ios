import SwiftUI
// The main chat view message and conversations of the app.
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let onOpenSidebar: () -> Void

    init(viewModel: ChatViewModel, onOpenSidebar: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onOpenSidebar = onOpenSidebar
    }

    var body: some View {
        NavigationStack {
            ChatScreen(viewModel: viewModel, onOpenSidebar: onOpenSidebar)
        }
    }
}

struct ChatScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let onOpenSidebar: () -> Void
    private let bottomAnchorID = "chat.bottomAnchor"

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = viewModel.activeConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(conversation.messages) { message in
                                if shouldShowMessage(message, in: conversation.id) {
                                    MessageBubble(message: message) {
                                        viewModel.retryMessage(message)
                                    }
                                    .id(message.id)
                                }
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
                                .transition(.opacity)
                            }

                            if let review = viewModel.activePendingPlanReview {
                                PlanReviewCard(review: review) {
                                    viewModel.approvePendingPlan(id: review.id)
                                } onRequestChanges: { feedback in
                                    viewModel.requestPlanChanges(id: review.id, feedback: feedback)
                                }
                                .id("pendingPlanReview")
                                .transition(.opacity)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 16)
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
                            withAnimation {
                                proxy.scrollTo(scrollTarget(for: interactionID), anchor: .bottom)
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Composer(viewModel: viewModel)
                            .padding(.top, 8)
                            .background {
                                Color(.systemBackground)
                                    .ignoresSafeArea(edges: .bottom)
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

                    StatusPill(state: viewModel.connectionState)
                }
            }

            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onOpenSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .disabled(viewModel.agents.isEmpty)
                .accessibilityLabel("Open sidebar")
            }
        }
    }

    private func scrollTarget(for interactionID: String) -> String {
        if interactionID == viewModel.activePendingApproval?.id {
            return "pendingApproval"
        }
        return "pendingPlanReview"
    }

    private func shouldShowMessage(_ message: ChatMessage, in conversationID: String) -> Bool {
        !isToolCallCoveredByPendingApproval(message, in: conversationID)
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
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}
