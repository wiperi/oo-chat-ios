import SwiftUI

enum AgentRoute: Hashable {
    case sessions(String)
}

struct AgentsView: View {
    @ObservedObject var viewModel: ChatViewModel
    let switchToChat: () -> Void
    @State private var path: [AgentRoute] = []
    @State private var agentDraft: AgentFormDraft?
    @State private var pendingDeleteAgent: AgentConnection?

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDeleteAgent = agent
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(AppTheme.destructive)
                                Button {
                                    agentDraft = AgentFormDraft(agent: agent)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(AppTheme.primary)
                            }
                        }
                    }
                }
            }
            .listSectionSpacing(16)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AgentRoute.self) { route in
                switch route {
                case .sessions(let agentID):
                    AgentSessionsView(
                        viewModel: viewModel,
                        agentID: agentID,
                        switchToChat: switchToChat
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("ConnectOnion")
                        .font(.largeTitle.bold())
                        .foregroundStyle(AppTheme.primary)
                        .offset(y: 6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    agentDraft = AgentFormDraft()
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(FloatingAddButtonStyle())
                .padding(.trailing, 24)
                .padding(.bottom, 24)
                .accessibilityLabel("Add Agent")
            }
            .overlay(alignment: .bottom) {
                ErrorBanner(message: viewModel.errorMessage) {
                    viewModel.dismissError()
                }
            }
            .alert("Delete Agent?", isPresented: deleteAgentBinding) {
                Button("Delete", role: .destructive) {
                    if let agent = pendingDeleteAgent {
                        viewModel.deleteAgent(agent)
                    }
                    pendingDeleteAgent = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteAgent = nil
                }
            } message: {
                Text("This removes the saved token and chat sessions for \(pendingDeleteAgent?.name ?? "this agent").")
            }
            .sheet(item: $agentDraft) { draft in
                AgentFormView(draft: draft) { savedDraft in
                    if let agent = viewModel.saveAgent(
                        id: savedDraft.agentID,
                        name: savedDraft.name,
                        address: savedDraft.address,
                        token: savedDraft.token
                    ) {
                        agentDraft = nil
                        path = [.sessions(agent.id)]
                        return true
                    }
                    return false
                } onCancel: {
                    agentDraft = nil
                }
            }
        }
    }

    private var deleteAgentBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteAgent != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteAgent = nil
                }
            }
        )
    }
}

private struct FloatingAddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(AppTheme.primary, in: Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .shadow(
                color: AppTheme.primary.opacity(configuration.isPressed ? 0.16 : 0.28),
                radius: configuration.isPressed ? 4 : 12,
                y: configuration.isPressed ? 2 : 6
            )
            .animation(
                .spring(response: 0.22, dampingFraction: 0.65),
                value: configuration.isPressed
            )
    }
}
