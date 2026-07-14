import SwiftUI

struct ToolCallView: View {
    let message: ChatMessage
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(AppTheme.primary)
                        .frame(width: 18)

                    Text(ToolActionSummary.completed(
                        toolName: message.toolName ?? "tool",
                        arguments: message.toolArguments ?? [:]
                    ))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    status

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tool call: \(message.toolName ?? "Tool")")
            .accessibilityValue("\(statusLabel), \(isExpanded ? "expanded" : "collapsed")")

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 14) {
                    Text(ToolActionSummary.completed(
                        toolName: message.toolName ?? "tool",
                        arguments: message.toolArguments ?? [:]
                    ))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !message.content.isEmpty {
                        detail(
                            label: message.toolState == .failed ? "Error" : "Output",
                            value: message.content
                        )
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityIdentifier("toolCall.\(message.id)")
    }

    @ViewBuilder
    private var status: some View {
        switch message.toolState ?? .running {
        case .running:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(statusLabel)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(statusLabel)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
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
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
