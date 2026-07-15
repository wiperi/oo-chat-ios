import SwiftUI
// Sidebar button styles.
struct SidebarPressedRowButtonStyle: ButtonStyle {
    var isHighlighted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if configuration.isPressed || isHighlighted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.quaternarySystemFill))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed || isHighlighted)
    }
}

struct SidebarFooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isEnabled)
    }
}

struct SidebarConversationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color(.label) : Color(.secondaryLabel))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background {
                if isSelected || configuration.isPressed {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.quaternarySystemFill))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}
