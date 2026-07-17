import SwiftUI

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
                        AppTheme.outgoingMessageBackground,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                deliveryStatus
            }
        }
    }

    private var agentMessage: some View {
        MarkdownMessageView(content: message.content)
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
        case .cancelled:
            HStack(spacing: 8) {
                Label("Cancelled", systemImage: "stop.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    onRetry?()
                }
                .font(.caption2.weight(.semibold))
                .accessibilityLabel("Retry cancelled message")
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
