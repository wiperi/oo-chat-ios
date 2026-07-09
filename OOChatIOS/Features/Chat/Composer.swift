import SwiftUI
// Handle the chat input, mode selection and send button.
struct Composer: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            TextField("Message the agent", text: $viewModel.prompt, axis: .vertical)
                .lineLimit(1...4)
                .focused($isPromptFocused)
                .disabled(viewModel.isProcessing)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )

            HStack(alignment: .center, spacing: 10) {
                modeMenu
                Spacer()
                sendButton
            }
        }
        .padding()
        .background(.bar)
    }

    private var modeMenu: some View {
        Menu {
            ForEach(ChatMode.allCases) { mode in
                Toggle(isOn: isSelectedBinding(for: mode)) {
                    Text(mode.label)
                    Text(mode.detail)
                    Image(systemName: mode.icon)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: viewModel.activeMode.icon)
                Text(viewModel.activeMode.label)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .disabled(viewModel.activeConversation == nil || viewModel.isProcessing)
        .accessibilityLabel("Chat mode: \(viewModel.activeMode.label)")
    }

    private var sendButton: some View {
        Button {
            viewModel.sendPrompt()
            isPromptFocused = false
        } label: {
            Group {
                if viewModel.isProcessing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 36, height: 36)
            .background(AppTheme.primary, in: Circle())
        }
        .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isProcessing)
        .accessibilityLabel("Send message")
    }

    private func isSelectedBinding(for mode: ChatMode) -> Binding<Bool> {
        Binding(
            get: { viewModel.activeMode == mode },
            set: { isOn in
                if isOn {
                    viewModel.setMode(mode)
                }
            }
        )
    }
}

// Presentation details for each mode, kept out of the model layer.
private extension ChatMode {
    var icon: String {
        switch self {
        case .safe:
            return "shield"
        case .plan:
            return "list.bullet.clipboard"
        case .accept:
            return "checkmark.circle"
        case .ulw:
            return "bolt.fill"
        }
    }

    var detail: String {
        switch self {
        case .safe:
            return "Asks before making changes"
        case .plan:
            return "Plans before acting"
        case .accept:
            return "Auto-accepts edits"
        case .ulw:
            return "Runs autonomously, up to 100 turns"
        }
    }
}
