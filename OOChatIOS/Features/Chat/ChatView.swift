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
        .toolbar {
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
