import SwiftUI
// Handle the chat input, mode selection and send button.
struct Composer: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isPromptFocused: Bool
    @State private var showModeMenu = false
    @State private var sheetHeight: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: ComposerMetrics.stackSpacing) {
            if viewModel.shouldShowSlashSkillPicker {
                skillPicker
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            modeMenu
                .padding(.leading, ComposerMetrics.modeLeadingPadding)

            inputBar
        }
        .padding(.horizontal, ComposerMetrics.outerHorizontalPadding)
        .padding(.bottom, ComposerMetrics.outerBottomPadding)
        .onChange(of: viewModel.prompt) {
            viewModel.promptDidChange()
        }
        .onAppear {
            viewModel.prefetchActiveAgentSkills()
        }
    }

    private var skillPicker: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.slashSkillSuggestions) { skill in
                    Button {
                        viewModel.selectSlashSkill(skill)
                        isPromptFocused = true
                    } label: {
                        skillRow(skill)
                    }
                    .buttonStyle(.plain)

                    if skill.id != viewModel.slashSkillSuggestions.last?.id {
                        Divider()
                            .padding(.leading, ComposerMetrics.skillDividerInset)
                    }
                }
            }
        }
        .frame(maxHeight: ComposerMetrics.skillPickerMaxHeight)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: ComposerMetrics.skillPickerCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ComposerMetrics.skillPickerCornerRadius, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .accessibilityLabel("Available skills")
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "command")
                .font(.body.weight(.medium))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("/\(skill.name)")
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ComposerMetrics.skillRowHorizontalPadding)
        .padding(.vertical, ComposerMetrics.skillRowVerticalPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Insert this skill in the message field")
    }

    private var inputBar: some View {
        HStack(alignment: .center, spacing: ComposerMetrics.inputSpacing) {
            TextField("Message the agent", text: $viewModel.prompt, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .focused($isPromptFocused)
                .disabled(viewModel.isProcessing)
                .tint(AppTheme.primary)
                .frame(minHeight: ComposerMetrics.sendButtonSize, alignment: .center)
                .padding(.vertical, ComposerMetrics.inputVerticalPadding)

            sendButton
        }
        .padding(.leading, ComposerMetrics.horizontalPadding)
        .padding(.trailing, ComposerMetrics.trailingPadding)
        .padding(.vertical, ComposerMetrics.verticalPadding)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius, style: .continuous)
                .stroke(Color(.separator).opacity(ComposerMetrics.inputStrokeOpacity), lineWidth: 0.5)
        )
    }

    private var modeMenu: some View {
        Button {
            showModeMenu = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: viewModel.activeMode.icon)
                    .foregroundStyle(AppTheme.primary)

                Text(viewModel.activeMode.label)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, ComposerMetrics.modeHorizontalPadding)
            .padding(.vertical, ComposerMetrics.modeVerticalPadding)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(.separator).opacity(ComposerMetrics.modeStrokeOpacity), lineWidth: 0.5)
            }
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
            .frame(width: ComposerMetrics.sendButtonSize, height: ComposerMetrics.sendButtonSize)
            .glassBackground(in: Circle(), interactive: true, tint: AppTheme.primary)
        }
        .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isProcessing)
        .accessibilityLabel("Send message")
    }

}

private enum ComposerMetrics {
    static let outerHorizontalPadding: CGFloat = 12
    static let outerBottomPadding: CGFloat = 6
    static let horizontalPadding: CGFloat = 16
    static let trailingPadding: CGFloat = 7
    static let verticalPadding: CGFloat = 7
    static let cornerRadius: CGFloat = 27
    static let stackSpacing: CGFloat = 7
    static let inputSpacing: CGFloat = 10
    static let inputVerticalPadding: CGFloat = 2
    static let inputStrokeOpacity: Double = 0.10
    static let modeLeadingPadding: CGFloat = 8
    static let modeHorizontalPadding: CGFloat = 10
    static let modeVerticalPadding: CGFloat = 5
    static let modeStrokeOpacity: Double = 0.08
    static let sendButtonSize: CGFloat = 40
    static let skillPickerMaxHeight: CGFloat = 260
    static let skillPickerCornerRadius: CGFloat = 16
    static let skillRowHorizontalPadding: CGFloat = 14
    static let skillRowVerticalPadding: CGFloat = 11
    static let skillDividerInset: CGFloat = 50
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
        }
    }
}
