import SwiftUI
// Handle the chat input, mode selection and send button.
struct Composer: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: modeBinding) {
                ForEach(ChatMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.activeConversation == nil || viewModel.isProcessing)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message the agent", text: $viewModel.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($isPromptFocused)
                    .disabled(viewModel.isProcessing)
                Button(viewModel.isProcessing ? "..." : "Send") {
                    viewModel.sendPrompt()
                    isPromptFocused = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isProcessing)
            }
        }
        .padding()
        .background(.bar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isPromptFocused = false
                }
            }
        }
    }

    private var modeBinding: Binding<ChatMode> {
        Binding(
            get: { viewModel.activeMode },
            set: { viewModel.setMode($0) }
        )
    }
}
