import SwiftUI

struct AgentSessionsView<Model: AgentsFeatureModel>: View {
    @ObservedObject var viewModel: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let agentID: String
    let switchToChat: () -> Void

    @State private var searchText = ""
    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var deleteTarget: Conversation?
    @State private var isPresentingQRCode = false

    private var agent: AgentConnection? {
        viewModel.agent(withID: agentID)
    }

    private var sessions: [Conversation] {
        guard let agent else {
            return []
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return viewModel.conversations(for: agent)
        }
        return viewModel.searchConversations(trimmed, for: agent)
    }

    var body: some View {
        Group {
            if let agent {
                List {
                    Section("Agent") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.name)
                                .font(.headline)
                            Text("Endpoint")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(short(agent.address))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !agent.token.isEmpty {
                                Label("Token stored", systemImage: "key.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Connection") {
                        Button {
                            viewModel.selectAgent(agent)
                            Task {
                                if await viewModel.connectToAgent() != nil {
                                    switchToChat()
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Label("Connect", systemImage: "bolt.horizontal.circle")
                                    .fontWeight(.semibold)

                                ZStack {
                                    if viewModel.isConnecting {
                                        ProgressView()
                                            .transition(connectingIndicatorTransition)
                                    }
                                }
                                .frame(width: 20, height: 20)
                            }
                            .animation(
                                AppMotion.stateChange(reduceMotion: reduceMotion),
                                value: viewModel.isConnecting
                            )
                        }
                        .foregroundStyle(AppTheme.primary)
                        .disabled(viewModel.isConnecting)
                    }

                    Section {
                        Button {
                            _ = viewModel.createConversation(for: agent)
                            switchToChat()
                        } label: {
                            Label("New Chat", systemImage: "plus.bubble")
                        }
                    }

                    Section("Chat Sessions") {
                        if sessions.isEmpty {
                            Text(searchText.isEmpty ? "No chat sessions" : "No matching chats")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(sessions) { conversation in
                                Button {
                                    viewModel.selectConversation(conversation)
                                    switchToChat()
                                } label: {
                                    ConversationRow(conversation: conversation)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteTarget = conversation
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(AppTheme.destructive)
                                    Button {
                                        renameText = conversation.title
                                        renameTarget = conversation
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(AppTheme.primary)
                                }
                            }
                        }
                    }
                }
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search chats"
                )
                .navigationTitle(agent.name)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if let url = AgentShareURL.url(for: agent.address) {
                            Menu {
                                ShareLink(item: url) {
                                    Label("Share Link", systemImage: "square.and.arrow.up")
                                }
                                Button {
                                    isPresentingQRCode = true
                                } label: {
                                    Label("Show QR Code", systemImage: "qrcode")
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share agent")
                        }
                    }
                }
                .sheet(isPresented: $isPresentingQRCode) {
                    if let url = AgentShareURL.url(for: agent.address) {
                        AgentQRCodeShareView(url: url)
                    }
                }
                .onAppear {
                    viewModel.selectAgent(agent)
                }
                .alert("Rename Chat", isPresented: isRenaming) {
                    TextField("Title", text: $renameText)
                    Button("Cancel", role: .cancel) { renameTarget = nil }
                    Button("Save") {
                        if let target = renameTarget {
                            viewModel.renameConversation(target, to: renameText)
                        }
                        renameTarget = nil
                    }
                } message: {
                    Text("Enter a new name for this chat.")
                }
                .alert("Delete Chat", isPresented: isDeleting, presenting: deleteTarget) { conversation in
                    Button("Delete", role: .destructive) {
                        viewModel.deleteConversation(conversation)
                        deleteTarget = nil
                    }
                    Button("Cancel", role: .cancel) { deleteTarget = nil }
                } message: { conversation in
                    Text("\"\(conversation.title)\" will be permanently deleted.")
                }
            } else {
                ContentUnavailableView("Agent Not Found", systemImage: "network.slash")
            }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var connectingIndicatorTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.985))
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
            if !agent.token.isEmpty {
                Label("Token stored", systemImage: "key.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
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

private func short(_ address: String) -> String {
    guard address.count > 16 else {
        return address.isEmpty ? "No address" : address
    }
    return "\(address.prefix(8))...\(address.suffix(6))"
}
