import SwiftUI

struct ContentView: View {
    @StateObject var viewModel: ChatViewModel

    var body: some View {
        TabView {
            AgentsView(viewModel: viewModel)
                .tabItem { Label("Agents", systemImage: "network") }
            ChatView(viewModel: viewModel)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            SettingsView(viewModel: viewModel)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct AgentsView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Hosted agent") {
                    TextField("0x...", text: $viewModel.agentAddressDraft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button("Use Address") {
                        viewModel.useAddress()
                    }
                    Button("New Chat") {
                        viewModel.createConversation()
                    }
                }

                Section("Conversations") {
                    ForEach(viewModel.conversations) { conversation in
                        Button {
                            viewModel.selectConversation(conversation)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title)
                                    .font(.headline)
                                Text("\(short(conversation.agentAddress)) - \(conversation.messages.count) items")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { viewModel.conversations[$0] }.forEach(viewModel.deleteConversation)
                    }
                }
            }
            .navigationTitle("ConnectOnion")
            .overlay(alignment: .bottom) {
                ErrorBanner(message: viewModel.errorMessage)
            }
        }
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        NavigationStack {
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
                ErrorBanner(message: viewModel.errorMessage)
            }
        }
    }
}

struct Composer: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message the agent", text: $viewModel.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(viewModel.isProcessing)
            Button(viewModel.isProcessing ? "..." : "Send") {
                viewModel.sendPrompt()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isProcessing)
        }
        .padding()
        .background(.bar)
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Identity") {
                    Text(viewModel.identity?.address ?? "Creating...")
                        .font(.system(.footnote, design: .monospaced))
                    Text(viewModel.identity?.publicKeyHex ?? "")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section("Session") {
                    LabeledContent("Connection", value: viewModel.connectionState.rawValue)
                    LabeledContent("Session ID", value: viewModel.activeConversation?.id ?? "None")
                    Button("Reconnect") {
                        Task {
                            await viewModel.reconnect()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 36)
            }
            Text(message.content)
                .padding(12)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if message.role != .user {
                Spacer(minLength: 36)
            }
        }
    }

    private var background: Color {
        switch message.role {
        case .user:
            return .blue
        case .agent:
            return Color(.secondarySystemBackground)
        case .thinking:
            return .yellow.opacity(0.25)
        case .error:
            return .red.opacity(0.18)
        }
    }

    private var foreground: Color {
        message.role == .user ? .white : .primary
    }
}

struct StatusPill: View {
    let state: ConnectionState

    var body: some View {
        Text(state.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch state {
        case .connected:
            return .green.opacity(0.22)
        case .reconnecting:
            return .orange.opacity(0.22)
        case .disconnected:
            return .yellow.opacity(0.24)
        }
    }
}

struct ErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.footnote)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.red.opacity(0.14))
                .foregroundStyle(.red)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }
}

private func short(_ address: String) -> String {
    guard address.count > 16 else {
        return address.isEmpty ? "No address" : address
    }
    return "\(address.prefix(8))...\(address.suffix(6))"
}
