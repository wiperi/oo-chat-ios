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

enum AgentRoute: Hashable {
    case sessions(String)
    case chat(String)
}

struct AgentsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var path: [AgentRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Connect agent") {
                    TextField("0x...", text: $viewModel.agentAddressDraft, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button {
                        Task {
                            if let agent = await viewModel.connectToAgent() {
                                path = [.sessions(agent.id)]
                            }
                        }
                    } label: {
                        HStack {
                            if viewModel.isConnecting {
                                ProgressView()
                            }
                            Text("Connect to Agent")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        viewModel.isConnecting ||
                            viewModel.agentAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                Section("Agents") {
                    if viewModel.agents.isEmpty {
                        Text("No agents connected")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.agents) { agent in
                            NavigationLink(value: AgentRoute.sessions(agent.id)) {
                                AgentRow(
                                    agent: agent,
                                    sessionCount: viewModel.conversations(for: agent).count
                                )
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { viewModel.agents[$0] }.forEach(viewModel.deleteAgent)
                        }
                    }
                }
            }
            .navigationTitle("ConnectOnion")
            .navigationDestination(for: AgentRoute.self) { route in
                switch route {
                case .sessions(let agentID):
                    AgentSessionsView(viewModel: viewModel, agentID: agentID, path: $path)
                case .chat(let conversationID):
                    RoutedChatView(viewModel: viewModel, conversationID: conversationID)
                }
            }
            .alert("Connection Failed", isPresented: connectionFailedBinding) {
                Button("OK", role: .cancel) {
                    viewModel.connectionFailureMessage = nil
                }
            } message: {
                Text(viewModel.connectionFailureMessage ?? "")
            }
            .overlay(alignment: .bottom) {
                ErrorBanner(message: viewModel.errorMessage)
            }
        }
    }

    private var connectionFailedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.connectionFailureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.connectionFailureMessage = nil
                }
            }
        )
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        NavigationStack {
            ChatScreen(viewModel: viewModel)
        }
    }
}

struct AgentSessionsView: View {
    @ObservedObject var viewModel: ChatViewModel
    let agentID: String
    @Binding var path: [AgentRoute]

    private var agent: AgentConnection? {
        viewModel.agent(withID: agentID)
    }

    private var sessions: [Conversation] {
        guard let agent else {
            return []
        }
        return viewModel.conversations(for: agent)
    }

    var body: some View {
        Group {
            if let agent {
                List {
                    Section("Agent") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.name)
                                .font(.headline)
                            Text(short(agent.address))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Button {
                            let conversation = viewModel.createConversation(for: agent)
                            path.append(.chat(conversation.id))
                        } label: {
                            Label("New Chat", systemImage: "plus.bubble")
                        }
                    }

                    Section("Chat Sessions") {
                        if sessions.isEmpty {
                            Text("No chat sessions")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(sessions) { conversation in
                                Button {
                                    viewModel.selectConversation(conversation)
                                    path.append(.chat(conversation.id))
                                } label: {
                                    ConversationRow(conversation: conversation)
                                }
                            }
                            .onDelete { offsets in
                                offsets.map { sessions[$0] }.forEach(viewModel.deleteConversation)
                            }
                        }
                    }
                }
                .navigationTitle(agent.name)
                .onAppear {
                    viewModel.selectAgent(agent)
                }
            } else {
                ContentUnavailableView("Agent Not Found", systemImage: "network.slash")
            }
        }
    }
}

struct RoutedChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let conversationID: String

    var body: some View {
        ChatScreen(viewModel: viewModel)
            .onAppear {
                viewModel.selectConversation(withID: conversationID)
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
            ErrorBanner(message: viewModel.errorMessage)
        }
    }
}

struct AgentRow: View {
    let agent: AgentConnection
    let sessionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.name)
                .font(.headline)
            Text("\(short(agent.address)) - \(sessionCount) sessions")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.headline)
            Text("\(conversation.messages.count) items")
                .foregroundStyle(.secondary)
                .font(.caption)
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
