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
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: conversation.messages.count) {
                        if let last = conversation.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
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
    }
}
