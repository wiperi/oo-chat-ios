import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        NavigationStack {
            ChatScreen(viewModel: viewModel)
        }
    }
}

struct ChatScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    private let bottomAnchorID = "chat.bottomAnchor"

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = viewModel.activeConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(conversation.messages) { message in
                                MessageBubble(message: message) {
                                    viewModel.retryMessage(message)
                                }
                                .id(message.id)
                            }

                            if let approval = viewModel.pendingApproval {
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

                            if let checkpoint = viewModel.pendingUlwCheckpoint {
                                UlwCheckpointCard(checkpoint: checkpoint) {
                                    viewModel.continueUlw(id: checkpoint.id)
                                } onAcceptEdits: {
                                    viewModel.switchModeFromUlwCheckpoint(id: checkpoint.id, to: .accept)
                                } onSafeMode: {
                                    viewModel.switchModeFromUlwCheckpoint(id: checkpoint.id, to: .safe)
                                }
                                .id("pendingUlwCheckpoint")
                                .transition(.opacity)
                            }

                            if let review = viewModel.pendingPlanReview {
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
                    }
                }
            } else {
                ContentUnavailableView("No Conversation", systemImage: "bubble.left")
            }
        }
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
                Menu {
                    if viewModel.agents.isEmpty {
                        Text("No Agents")
                    } else {
                        ForEach(viewModel.agents) { agent in
                            Button {
                                viewModel.switchToAgentForChat(agent)
                            } label: {
                                HStack {
                                    Text(agent.name)
                                    if viewModel.activeAgentID == agent.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, AppTheme.primary)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .disabled(viewModel.agents.isEmpty || viewModel.isProcessing)
                .accessibilityLabel("Switch Agent")
            }
        }
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func scrollTarget(for interactionID: String) -> String {
        if interactionID == viewModel.pendingApproval?.id {
            return "pendingApproval"
        }
        if interactionID == viewModel.pendingUlwCheckpoint?.id {
            return "pendingUlwCheckpoint"
        }
        return "pendingPlanReview"
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
