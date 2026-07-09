import SwiftUI

enum AgentRoute: Hashable {
    case sessions(String)
}

struct AgentsView: View {
    @ObservedObject var viewModel: ChatViewModel
    let switchToChat: () -> Void
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
                    AgentSessionsView(
                        viewModel: viewModel,
                        agentID: agentID,
                        switchToChat: switchToChat
                    )
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
                ErrorBanner(message: viewModel.errorMessage) {
                    viewModel.dismissError()
                }
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
