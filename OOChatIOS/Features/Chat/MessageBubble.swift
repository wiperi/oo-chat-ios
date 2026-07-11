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

enum ToolActionSummary {
    static func completed(toolName: String, arguments: [String: JSONValue]) -> String {
        summary(
            toolName: toolName,
            arguments: arguments,
            commandPrefix: "Ran",
            writePrefix: "Wrote",
            editPrefix: "Updated",
            searchPrefix: "Searched",
            listPrefix: "Listed"
        )
    }

    static func requested(toolName: String, arguments: [String: JSONValue]) -> String {
        summary(
            toolName: toolName,
            arguments: arguments,
            commandPrefix: "Run",
            writePrefix: "Write",
            editPrefix: "Update",
            searchPrefix: "Search",
            listPrefix: "List"
        )
    }

    static func argumentsDescription(_ arguments: [String: JSONValue]) -> String {
        arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \(displayValue($0.value))" }
            .joined(separator: "\n")
    }

    private static func summary(
        toolName: String,
        arguments: [String: JSONValue],
        commandPrefix: String,
        writePrefix: String,
        editPrefix: String,
        searchPrefix: String,
        listPrefix: String
    ) -> String {
        if let command = stringArgument(named: "cmd", in: arguments)
            ?? stringArgument(named: "command", in: arguments)
            ?? stringArgument(named: "script", in: arguments) {
            return "\(commandPrefix) \(command)"
        }

        let normalizedName = toolName.lowercased()
        let path = stringArgument(named: "path", in: arguments)
            ?? stringArgument(named: "file", in: arguments)
            ?? stringArgument(named: "url", in: arguments)

        if normalizedName.contains("read"), let path {
            return "Read \(path)"
        }
        if normalizedName.contains("write"), let path {
            return "\(writePrefix) \(path)"
        }
        if normalizedName.contains("edit") || normalizedName.contains("patch"), let path {
            return "\(editPrefix) \(path)"
        }
        if normalizedName.contains("search"), let query = stringArgument(named: "query", in: arguments) {
            return "\(searchPrefix) \(query)"
        }
        if normalizedName.contains("list") || normalizedName.contains("glob"), let path {
            return "\(listPrefix) \(path)"
        }

        let details = argumentsDescription(arguments)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ": ", with: "=")
        if details.isEmpty {
            return toolName.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "\(commandPrefix) \(toolName) \(details)"
    }

    private static func stringArgument(named name: String, in arguments: [String: JSONValue]) -> String? {
        arguments[name]?.stringValue
    }

    private static func displayValue(_ value: JSONValue) -> String {
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

struct ApprovalCard: View {
    let approval: PendingApproval
    var onAllowOnce: () -> Void
    var onTrustSession: () -> Void
    var onReject: () -> Void
    var onStop: () -> Void
    var onExplain: () -> Void

    private var request: ToolApprovalRequest {
        approval.request
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let description = request.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            argumentList

            if !request.batchRemaining.isEmpty {
                Text("\(request.batchRemaining.count) more action\(request.batchRemaining.count == 1 ? "" : "s") waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            actionRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission requested for \(request.tool)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(AppTheme.primary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Permission requested")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(ToolActionSummary.requested(
                    toolName: request.tool,
                    arguments: request.arguments
                ))
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            }

            Spacer(minLength: 4)

            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Waiting for your decision")
        }
    }

    @ViewBuilder
    private var argumentList: some View {
        let details = ToolActionSummary.argumentsDescription(request.arguments)
        if !details.isEmpty {
            Text(details)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
    }

    private var actionRow: some View {
        VStack(spacing: 8) {
            Button {
                onAllowOnce()
            } label: {
                Label("Allow once", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
            .accessibilityIdentifier("approval.allowOnce.\(request.id)")

            HStack(spacing: 8) {
                Button {
                    onTrustSession()
                } label: {
                    Label("Trust for session", systemImage: "checkmark.shield.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("approval.trustSession.\(request.id)")

                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("Reject", systemImage: "xmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("approval.reject.\(request.id)")
            }

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    onStop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("approval.stop.\(request.id)")

                Button {
                    onExplain()
                } label: {
                    Label("Explain", systemImage: "questionmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("approval.explain.\(request.id)")
            }
        }
    }
}

struct UlwCheckpointCard: View {
    let checkpoint: PendingUlwCheckpoint
    var onContinue: () -> Void
    var onAcceptEdits: () -> Void
    var onSafeMode: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Ultra Work checkpoint", systemImage: "bolt.fill")
                .font(.headline)
                .foregroundStyle(AppTheme.primary)

            Text("Completed \(checkpoint.request.turnsUsed) of \(checkpoint.request.maxTurns) turns")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Continue (+100 turns)", action: onContinue)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("ulw.continue.\(checkpoint.id)")

            HStack(spacing: 8) {
                Button("Accept Edits", action: onAcceptEdits)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ulw.acceptEdits.\(checkpoint.id)")
                Button("Safe Mode", action: onSafeMode)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ulw.safe.\(checkpoint.id)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

struct PlanReviewCard: View {
    let review: PendingPlanReview
    var onApprove: () -> Void
    var onRequestChanges: (String?) -> Void

    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Review implementation plan", systemImage: "list.bullet.clipboard")
                .font(.headline)
                .foregroundStyle(AppTheme.primary)

            ScrollView {
                Text(review.request.planContent)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .padding(10)
            .background(
                Color(.tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            TextField("Feedback for changes (optional)", text: $feedback, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            Button("Approve & Implement", action: onApprove)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("plan.approve.\(review.id)")

            Button("Request Changes") {
                onRequestChanges(feedback)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("plan.requestChanges.\(review.id)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}
