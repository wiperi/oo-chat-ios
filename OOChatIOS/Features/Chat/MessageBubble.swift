import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 36)
            }
            Text(message.content)
                .padding(12)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if message.role != .user {
                Spacer(minLength: 36)
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
