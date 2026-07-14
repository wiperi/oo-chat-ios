import SwiftUI

struct ToolCallView: View {
    let message: ChatMessage
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton

            if isExpanded {
                Divider()
                    .padding(.leading, 40)

                VStack(alignment: .leading, spacing: 10) {
                    detail(label: "Action", value: summary)

                    if !message.content.isEmpty {
                        detail(
                            label: message.toolState == .failed ? "Error" : "Output",
                            value: message.content
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityIdentifier("toolCall.\(message.id)")
    }

    private var headerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                statusIcon

                VStack(alignment: .leading, spacing: 1) {
                    Text(summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tool call: \(message.toolName ?? "Tool")")
        .accessibilityValue("\(statusLabel), \(isExpanded ? "expanded" : "collapsed")")
    }

    private var summary: String {
        ToolActionSummary.completed(
            toolName: message.toolName ?? "tool",
            arguments: message.toolArguments ?? [:]
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.toolState ?? .running {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityLabel(statusLabel)
        case .completed:
            Label(statusLabel, systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .frame(width: 24, height: 24)
                .background(
                    Color.green.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityLabel(statusLabel)
        case .failed:
            Label(statusLabel, systemImage: "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .frame(width: 24, height: 24)
                .background(
                    Color.red.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityLabel(statusLabel)
        }
    }

    private var statusLabel: String {
        switch message.toolState ?? .running {
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}

private extension ToolCallView {
    func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }
}
