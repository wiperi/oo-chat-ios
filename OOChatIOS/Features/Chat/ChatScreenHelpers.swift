import SwiftUI

extension ChatScreen {
    func shouldShowEmptyState(for conversation: Conversation) -> Bool {
        conversation.messages.isEmpty && viewModel.pendingInteractionID == nil
    }

    var backgroundAttentionLabel: String {
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

    func scrollTarget(for interactionID: String) -> String {
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

    func shouldShowMessage(_ message: ChatMessage, in conversationID: String) -> Bool {
        !viewModel.isToolCallCoveredByPendingApproval(message, in: conversationID)
    }

    func timelineEntries(for conversation: Conversation) -> [ChatTimelineEntry] {
        ChatTimelineBuilder.entries(
            from: conversation.messages.filter {
                shouldShowMessage($0, in: conversation.id)
            }
        )
    }

    @ViewBuilder
    func timelineView(for entry: ChatTimelineEntry) -> some View {
        switch entry {
        case .message(let message):
            MessageBubble(message: message) {
                viewModel.retryMessage(message)
            }
        case .toolCallGroup(let messages):
            ToolCallGroupView(messages: messages)
        }
    }

    func scrollUpdate(for conversation: Conversation) -> ChatScrollUpdate {
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

    func updateFollowLatest() {
        guard scrollViewportHeight > 0 else {
            return
        }
        shouldFollowLatest = bottomAnchorY - scrollViewportHeight
            <= ChatScrollMetrics.followThreshold
    }

    func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
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

    func scrollToBottomAfterKeyboardLayout(_ proxy: ScrollViewProxy) {
        scrollToBottom(proxy)
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatScrollMetrics.keyboardFollowUpDelay) {
            guard isPromptFocused else {
                return
            }
            scrollToBottom(proxy)
        }
    }

    var conversationTransition: AnyTransition {
        guard !reduceMotion else {
            return .opacity
        }

        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 10, y: 0)),
            removal: .opacity
        )
    }
}
