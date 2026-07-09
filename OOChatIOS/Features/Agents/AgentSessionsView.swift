import SwiftUI

struct AgentSessionsView: View {
    @ObservedObject var viewModel: ChatViewModel
    let agentID: String
    let switchToChat: () -> Void

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
                            _ = viewModel.createConversation(for: agent)
                            switchToChat()
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
                                    switchToChat()
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
