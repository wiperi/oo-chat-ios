import SwiftUI

enum AgentRoute: Hashable {
    case addAgent
    case sessions(String)
}

struct AgentsView: View {
    @ObservedObject var viewModel: ChatViewModel
    let switchToChat: () -> Void
    @State private var path: [AgentRoute] = []

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
                        }
                        .onDelete { offsets in
                            offsets.map { viewModel.agents[$0] }.forEach(viewModel.deleteAgent)
                        }
                    }
                }
            }
            .listSectionSpacing(16)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AgentRoute.self) { route in
                switch route {
                case .addAgent:
                    AddAgentView(viewModel: viewModel) { agent in
                        path = [.sessions(agent.id)]
                    }
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
                    viewModel.agentAddressDraft = ""
                    path.append(.addAgent)
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
        }
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
