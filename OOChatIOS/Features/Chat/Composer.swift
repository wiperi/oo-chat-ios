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
        .onChange(of: viewModel.activeConversationID) {
            isPromptFocused = viewModel.activeConversationID != nil
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
                    .buttonStyle(SkillSuggestionButtonStyle())

                    if skill.id != viewModel.slashSkillSuggestions.last?.id {
                        Divider()
                            .padding(.leading, ComposerMetrics.skillDividerInset)
                    }
                }
            }
        }
        .frame(height: skillPickerHeight)
        .scrollIndicators(.hidden)
        .glassBackground(
            in: skillPickerShape,
            tint: Color(.secondarySystemBackground).opacity(ComposerMetrics.skillPickerGlassTintOpacity)
        )
        .overlay {
            skillPickerShape
                .stroke(Color(.systemBackground).opacity(ComposerMetrics.skillPickerHighlightOpacity), lineWidth: 0.9)
        }
        .overlay {
            skillPickerShape
                .stroke(Color(.separator).opacity(ComposerMetrics.skillPickerStrokeOpacity), lineWidth: 0.6)
        }
        .clipShape(skillPickerShape)
        .shadow(
            color: .black.opacity(ComposerMetrics.skillPickerShadowOpacity),
            radius: ComposerMetrics.skillPickerShadowRadius,
            y: ComposerMetrics.skillPickerShadowYOffset
        )
        .accessibilityLabel("Available skills")
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        HStack(alignment: .top, spacing: ComposerMetrics.skillRowSpacing) {
            Image(systemName: "command")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.primary)
                .frame(width: ComposerMetrics.skillIconSize, height: ComposerMetrics.skillIconSize)
                .background(
                    AppTheme.primary.opacity(ComposerMetrics.skillIconBackgroundOpacity),
                    in: RoundedRectangle(cornerRadius: ComposerMetrics.skillIconCornerRadius, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("/\(skill.name)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(1)
                        .lineLimit(2)
                }
            }
            .padding(.top, ComposerMetrics.skillTextTopPadding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ComposerMetrics.skillRowHorizontalPadding)
        .padding(.vertical, ComposerMetrics.skillRowVerticalPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Insert this skill in the message field")
    }

    private var skillPickerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ComposerMetrics.skillPickerCornerRadius, style: .continuous)
    }

    private var skillPickerHeight: CGFloat {
        let rowCount = CGFloat(viewModel.slashSkillSuggestions.count)
        return min(
            rowCount * ComposerMetrics.skillRowEstimatedHeight,
            ComposerMetrics.skillPickerMaxHeight
        )
    }

    private var inputBar: some View {
        HStack(alignment: .center, spacing: ComposerMetrics.inputSpacing) {
            TextField("Message the agent", text: $viewModel.prompt, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .focused($isPromptFocused)
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
            if viewModel.isProcessing {
                viewModel.stopActiveResponse()
            } else {
                viewModel.sendPrompt()
                isPromptFocused = false
            }
        } label: {
            Image(systemName: viewModel.isProcessing ? "stop.fill" : "arrow.up")
                .font(viewModel.isProcessing ? .caption.weight(.bold) : .body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: ComposerMetrics.sendButtonSize, height: ComposerMetrics.sendButtonSize)
                .glassBackground(
                    in: Circle(),
                    interactive: true,
                    tint: AppTheme.primary
                )
        }
        .disabled(
            !viewModel.isProcessing
                && viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .accessibilityLabel(viewModel.isProcessing ? "Stop response" : "Send message")
    }

}

private enum ComposerMetrics {
    static let outerHorizontalPadding: CGFloat = 12
    static let outerBottomPadding: CGFloat = 6
    static let horizontalPadding: CGFloat = 16
    static let trailingPadding: CGFloat = 7
    static let verticalPadding: CGFloat = 7
    static let cornerRadius: CGFloat = 27
    static let stackSpacing: CGFloat = 9
    static let inputSpacing: CGFloat = 10
    static let inputVerticalPadding: CGFloat = 2
    static let inputStrokeOpacity: Double = 0.10
    static let modeLeadingPadding: CGFloat = 8
    static let modeHorizontalPadding: CGFloat = 10
    static let modeVerticalPadding: CGFloat = 5
    static let modeStrokeOpacity: Double = 0.08
    static let sendButtonSize: CGFloat = 40
    static let skillPickerMaxHeight: CGFloat = 260
    static let skillPickerCornerRadius: CGFloat = 24
    static let skillPickerGlassTintOpacity: Double = 0.78
    static let skillPickerHighlightOpacity: Double = 0.70
    static let skillPickerStrokeOpacity: Double = 0.22
    static let skillPickerShadowOpacity: Double = 0.13
    static let skillPickerShadowRadius: CGFloat = 30
    static let skillPickerShadowYOffset: CGFloat = 10
    static let skillRowSpacing: CGFloat = 12
    static let skillRowEstimatedHeight: CGFloat = 82
    static let skillRowHorizontalPadding: CGFloat = 14
    static let skillRowVerticalPadding: CGFloat = 12
    static let skillIconSize: CGFloat = 34
    static let skillIconCornerRadius: CGFloat = 9
    static let skillIconBackgroundOpacity: Double = 0.08
    static let skillTextTopPadding: CGFloat = 1
    static let skillDividerInset: CGFloat = 60
}

private struct SkillSuggestionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.tertiarySystemFill) : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
