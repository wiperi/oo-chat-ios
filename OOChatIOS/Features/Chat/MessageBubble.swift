import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 36)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(12)
                    .background(background)
                    .foregroundStyle(foreground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                deliveryStatus
            }
            if message.role != .user {
                Spacer(minLength: 36)
            }
        }
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        if message.role == .user {
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

    private var background: Color {
        switch message.role {
        case .user:
            return AppTheme.primary
        case .agent:
            return Color(.secondarySystemBackground)
        case .thinking:
            return .yellow.opacity(0.25)
        case .error:
            return .red.opacity(0.18)
        }
    }

    private var foreground: Color {
        message.role == .user ? .white : .primary
    }
}
