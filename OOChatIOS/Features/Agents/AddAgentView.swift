import SwiftUI

struct AgentFormDraft: Identifiable {
    let id = UUID()
    let agentID: String?
    var name: String
    var address: String
    var token: String
    var shouldConnectAfterSave = false

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: AgentFormDraft
    @State private var validationMessage: String?
    @State private var isPresentingScanner = false
    @State private var scannedAddress: String?
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
                            if draft.address != scannedAddress {
                                draft.shouldConnectAfterSave = false
                            }
                        }
                    if draft.agentID == nil {
                        Button {
                            guard AgentQRCodeScannerView.isSupported else {
                                validationMessage = "Camera scanning is unavailable. Enter the agent address manually."
                                return
                            }
                            isPresentingScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                    }
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
                    }
                    SecureField("Token (stored only)", text: $draft.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Saved with this configuration; not used for ConnectOnion connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
                .animation(
                    AppMotion.contentArrival(reduceMotion: reduceMotion),
                    value: validationMessage
                )
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
                            validationMessage = "Couldn't save this agent. Double-check the address is a valid 0x-prefixed Ed25519 key, then try again."
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .fullScreenCover(isPresented: $isPresentingScanner) {
            AgentQRCodeScannerView(
                onCode: handleScannedCode,
                onUnavailable: handleScannerUnavailable
            )
        }
    }

    private func handleScannedCode(_ code: String) {
        isPresentingScanner = false
        guard let address = AgentQRCodePayload.address(from: code) else {
            validationMessage = "This QR code does not contain a valid agent address."
            return
        }

        scannedAddress = address
        draft.address = address
        draft.shouldConnectAfterSave = true
        validationMessage = nil
    }

    private func handleScannerUnavailable(_ message: String) {
        isPresentingScanner = false
        validationMessage = message
    }
}
