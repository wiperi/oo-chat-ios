import SwiftUI
// The screen of connect and add agent.
struct AddAgentView: View {
    @ObservedObject var viewModel: ChatViewModel
    let onConnected: (AgentConnection) -> Void

    var body: some View {
        List {
            Section {
                Text("Paste an OpenOnion agent address to start chatting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("AGENT ADDRESS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)          
                    // Input agent address.
                    TextField(
                        "0xb974... or paste agent address",
                        text: $viewModel.agentAddressDraft,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("No endpoint URL for oo-chat workflow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    Task {
                        if let agent = await viewModel.connectToAgent() {
                            onConnected(agent)
                        }
                    }
                } label: {
                    Text("Connect")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .leading) {
                            if viewModel.isConnecting {
                                ProgressView()
                                    .tint(.white)
                                    .padding(.leading, 16)
                            }
                        }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                .disabled(
                    viewModel.isConnecting ||
                        viewModel.agentAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("Add Agent")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Connection Failed", isPresented: connectionFailedBinding) {
            Button("OK", role: .cancel) {
                viewModel.connectionFailureMessage = nil
            }
        } message: {
            Text(viewModel.connectionFailureMessage ?? "")
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
