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
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(conversation.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: conversation.messages.count) {
                        if let last = conversation.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                Composer(viewModel: viewModel)
            } else {
                ContentUnavailableView("No Conversation", systemImage: "bubble.left")
            }
        }
        .navigationTitle(viewModel.activeConversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if viewModel.agents.isEmpty {
                        Text("No Agents")
                    } else {
                        ForEach(viewModel.agents) { agent in
                            Button {
                                viewModel.selectAgent(agent)
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
                .disabled(viewModel.agents.isEmpty)
                .accessibilityLabel("Switch Agent")
            }

            ToolbarItem(placement: .topBarTrailing) {
                StatusPill(state: viewModel.connectionState)
            }
        }
        .overlay(alignment: .bottom) {
            ErrorBanner(message: viewModel.errorMessage) {
                viewModel.dismissError()
            }
        }
    }
}
