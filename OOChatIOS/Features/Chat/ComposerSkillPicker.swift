import SwiftUI

extension Composer {
    var skillPicker: some View {
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
            tint: Color(.secondarySystemBackground).opacity(ComposerMetrics.skillPickerGlassTintOpacity),
            fallback: Color(.secondarySystemBackground)
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

    func skillRow(_ skill: AgentSkill) -> some View {
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

    var skillPickerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ComposerMetrics.skillPickerCornerRadius, style: .continuous)
    }

    var skillPickerHeight: CGFloat {
        let rowCount = CGFloat(viewModel.slashSkillSuggestions.count)
        return min(
            rowCount * ComposerMetrics.skillRowEstimatedHeight,
            ComposerMetrics.skillPickerMaxHeight
        )
    }
}

private struct SkillSuggestionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.tertiarySystemFill) : Color.clear)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(AppMotion.press, value: configuration.isPressed)
    }
}
