import SwiftUI
// Handle the chat input, mode selection and send button.
struct Composer: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isPromptFocused: Bool
    @State private var showModeMenu = false
    @State private var sheetHeight: CGFloat = 400

    var body: some View {
        VStack(spacing: 12) {
            TextField("Message the agent", text: $viewModel.prompt, axis: .vertical)
                .lineLimit(1...4)
                .focused($isPromptFocused)
                .disabled(viewModel.isProcessing)

            HStack(alignment: .center, spacing: 10) {
                modeMenu
                Spacer()
                sendButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassBackground(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var modeMenu: some View {
        Button {
            showModeMenu = true
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
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.activeConversation == nil || viewModel.isProcessing)
        .accessibilityLabel("Chat mode: \(viewModel.activeMode.label)")
        .sheet(isPresented: $showModeMenu) {
            modeSheet
                .presentationDetents([.height(sheetHeight)])
                .presentationDragIndicator(.visible)
        }
    }

    private var modeSheet: some View {
        VStack(spacing: 0) {
            Text("Response Mode")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(ChatMode.allCases) { mode in
                Button {
                    viewModel.setMode(mode)
                    showModeMenu = false
                } label: {
                    modeRow(for: mode)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { sheetHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newValue in
                        sheetHeight = newValue
                    }
            }
        }
    }

    private func modeRow(for mode: ChatMode) -> some View {
        HStack(spacing: 14) {
            Image(systemName: mode.icon)
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 40, height: 40)
                .background(
                    AppTheme.primary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(mode.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if viewModel.activeMode == mode {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
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
            .glassBackground(in: Circle(), interactive: true, tint: AppTheme.primary)
        }
        .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isProcessing)
        .accessibilityLabel("Send message")
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
            return "Ask before file edits and commands"
        case .plan:
            return "Research first, then review the plan"
        case .accept:
            return "Trust the agent to edit without asking"
        case .ulw:
            return "Work autonomously for up to 100 turns"
        }
    }
}
