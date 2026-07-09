import SwiftUI

struct AgentSessionsView: View {
    @ObservedObject var viewModel: ChatViewModel
    let agentID: String
    let switchToChat: () -> Void

    @State private var searchText = ""
    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var deleteTarget: Conversation?

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
                            Text(short(agent.address))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                                    Button {
                                        renameText = conversation.title
                                        renameTarget = conversation
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                    Button(role: .destructive) {
                                        deleteTarget = conversation
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
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

private func short(_ address: String) -> String {
    guard address.count > 16 else {
        return address.isEmpty ? "No address" : address
    }
    return "\(address.prefix(8))...\(address.suffix(6))"
}
