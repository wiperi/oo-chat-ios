import SwiftUI

struct AgentFormDraft: Identifiable {
    let id = UUID()
    let agentID: String?
    var name: String
    var address: String
    var token: String

    init(agent: AgentConnection? = nil) {
        self.agentID = agent?.id
        self.name = agent?.name ?? ""
        self.address = agent?.address ?? ""
        self.token = agent?.token ?? ""
    }

    var title: String {
        agentID == nil ? "Add Agent" : "Edit Agent"
    }
}

struct AgentFormView: View {
    @State private var draft: AgentFormDraft
    @State private var validationMessage: String?
    let onSave: (AgentFormDraft) -> Bool
    let onCancel: () -> Void

    init(draft: AgentFormDraft, onSave: @escaping (AgentFormDraft) -> Bool, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.words)
                    TextField("Agent address", text: $draft.address, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: draft.address) {
                            validationMessage = nil
                        }
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    SecureField("Token (stored only)", text: $draft.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Saved with this configuration; not used for ConnectOnion connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard HostedAgentClient.isHostedAgentAddress(
                            draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
                        ) else {
                            validationMessage = "Enter a hosted agent address in 0x-prefixed Ed25519 format."
                            return
                        }
                        if !onSave(draft) {
                            validationMessage = "Unable to save this agent configuration."
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
