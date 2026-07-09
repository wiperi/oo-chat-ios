import SwiftUI

struct Composer: View {
    @ObservedObject var viewModel: ChatViewModel

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
                    .disabled(viewModel.isProcessing)
                Button(viewModel.isProcessing ? "..." : "Send") {
                    viewModel.sendPrompt()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isProcessing)
            }
        }
        .padding()
        .background(.bar)
    }

    private var modeBinding: Binding<ChatMode> {
        Binding(
            get: { viewModel.activeMode },
            set: { viewModel.setMode($0) }
        )
    }
}
