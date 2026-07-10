import SwiftUI

// Claude-style message rendering: user messages sit in a soft rounded bubble
// on the right; agent replies are plain text on the background.
struct MessageBubble: View {
    let message: ChatMessage
    var onRetry: (() -> Void)? = nil

    var body: some View {
        switch message.role {
        case .user:
            userMessage
        case .agent:
            agentMessage
        case .thinking:
            thinkingMessage
        case .tool:
            toolMessage
        case .error:
            errorMessage
        }
    }

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                deliveryStatus
            }
        }
    }

    private var agentMessage: some View {
        Text(message.content)
            .textSelection(.enabled)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thinkingMessage: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
            Text(message.content)
                .italic()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolMessage: some View {
        ToolCallView(message: message)
    }

    private var errorMessage: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message.content)
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .red.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        switch message.deliveryState {
        case .sent:
            EmptyView()
        case .queued:
            Label("Queued", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 8) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Button("Retry") {
                    onRetry?()
                }
                .font(.caption2.weight(.semibold))
                .accessibilityLabel("Retry sending message")
            }
        }
    }
}

private struct ToolCallView: View {
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

                    Text(invocationSummary)
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
                    Text(invocationSummary)
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

    private var invocationSummary: String {
        let arguments = message.toolArguments ?? [:]
        if let command = stringArgument(named: "cmd", in: arguments)
            ?? stringArgument(named: "command", in: arguments)
            ?? stringArgument(named: "script", in: arguments) {
            return "Ran \(command)"
        }

        let toolName = message.toolName ?? "tool"
        let normalizedName = toolName.lowercased()
        let path = stringArgument(named: "path", in: arguments)
            ?? stringArgument(named: "file", in: arguments)
            ?? stringArgument(named: "url", in: arguments)

        if normalizedName.contains("read"), let path {
            return "Read \(path)"
        }
        if normalizedName.contains("write"), let path {
            return "Wrote \(path)"
        }
        if normalizedName.contains("edit") || normalizedName.contains("patch"), let path {
            return "Updated \(path)"
        }
        if normalizedName.contains("search"), let query = stringArgument(named: "query", in: arguments) {
            return "Searched \(query)"
        }
        if normalizedName.contains("list") || normalizedName.contains("glob"), let path {
            return "Listed \(path)"
        }

        let details = arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(displayValue($0.value))" }
            .joined(separator: " ")
        if details.isEmpty {
            return toolName.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "Ran \(toolName) \(details)"
    }

    private func stringArgument(named name: String, in arguments: [String: JSONValue]) -> String? {
        arguments[name]?.stringValue
    }

    private func displayValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            return "[\(values.count) items]"
        case .object(let values):
            return "[\(values.count) fields]"
        case .null:
            return "null"
        }
    }

    private func detail(label: String, value: String) -> some View {
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
