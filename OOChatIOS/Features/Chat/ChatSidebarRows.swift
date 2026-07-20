import SwiftUI

struct SidebarAgentRow: View {
    let agent: AgentConnection
    let isExpanded: Bool
    let isOnline: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onEdit: () -> Void
    let onAddChat: () -> Void
    let onShowQRCode: (URL) -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: SidebarMetrics.agentRowSpacing) {
                Image(systemName: "chevron.forward")
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarMetrics.chevronWidth, height: SidebarMetrics.agentRowHeight)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                HStack(spacing: SidebarMetrics.agentAvatarSpacing) {
                    Text(agentInitial(for: agent))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .frame(width: SidebarMetrics.avatarSize, height: SidebarMetrics.avatarSize)
                        .background(Color(.quaternarySystemFill), in: Circle())

                    HStack(spacing: SidebarMetrics.agentNameSpacing) {
                        Text(agent.name)
                            .font(.body)
                            .lineLimit(1)

                        if isOnline {
                            Circle()
                                .fill(Color(.systemGreen))
                                .frame(width: SidebarMetrics.statusDotSize, height: SidebarMetrics.statusDotSize)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.90))
        .contextMenu {
            Button {
                onRename()
            } label: {
                sidebarContextMenuLabel("Rename", systemImage: "pencil", color: Color(.label))
            }
            .tint(Color(.label))

            Button {
                onEdit()
            } label: {
                sidebarContextMenuLabel("Edit Agent", systemImage: "slider.horizontal.3", color: Color(.label))
            }
            .tint(Color(.label))

            Button {
                onAddChat()
            } label: {
                sidebarContextMenuLabel("Add Chat", systemImage: "plus.bubble", color: Color(.label))
            }
            .tint(Color(.label))

            if let shareURL = AgentShareURL.url(for: agent.address) {
                ShareLink(item: shareURL) {
                    sidebarContextMenuLabel("Share Link", systemImage: "square.and.arrow.up", color: Color(.label))
                }
                .tint(Color(.label))

                Button {
                    onShowQRCode(shareURL)
                } label: {
                    sidebarContextMenuLabel("Show QR Code", systemImage: "qrcode", color: Color(.label))
                }
                .tint(Color(.label))
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                sidebarContextMenuLabel("Delete", systemImage: "trash", color: AppTheme.destructive)
            }
            .tint(AppTheme.destructive)
        }
    }

    private func agentInitial(for agent: AgentConnection) -> String {
        guard let first = agent.name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "A"
        }
        return String(first).uppercased()
    }
}

struct SidebarConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let activityState: ConversationActivityState?
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: SidebarMetrics.sessionContentSpacing) {
                    Image(systemName: "message")
                        .imageScale(.medium)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: SidebarMetrics.sessionIconWidth)

                    Text(conversation.title)
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    ConversationActivityIndicator(state: activityState)
                }
                .padding(.leading, SidebarMetrics.sessionIndent)
            }
        }
        .buttonStyle(SidebarConversationButtonStyle(isSelected: isSelected))
        .listRowInsets(SidebarMetrics.conversationRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button {
                onRename()
            } label: {
                sidebarContextMenuLabel("Rename", systemImage: "pencil", color: Color(.label))
            }
            .tint(Color(.label))

            Button(role: .destructive) {
                onDelete()
            } label: {
                sidebarContextMenuLabel("Delete", systemImage: "trash", color: AppTheme.destructive)
            }
            .tint(AppTheme.destructive)
        }
        .accessibilityAction(named: Text("Delete")) {
            onDelete()
        }
        .accessibilityAction(named: Text("Rename")) {
            onRename()
        }
    }
}

struct ConversationStatusDot: View {
    let state: ConversationActivityState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: SidebarMetrics.statusDotSize, height: SidebarMetrics.statusDotSize)
            .overlay {
                Circle()
                    .stroke(
                        Color(.systemBackground),
                        lineWidth: SidebarMetrics.activityIndicatorStrokeWidth
                    )
            }
            .accessibilityLabel(accessibilityLabel)
    }

    private var color: Color {
        switch state {
        case .actionRequired:
            return Color(.systemYellow)
        case .completedUnread:
            return Color(.systemBlue)
        case .failedDelivery:
            return Color(.systemRed)
        case .working:
            return AppTheme.primary
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .actionRequired:
            return "Action required"
        case .working:
            return "Agent working"
        case .completedUnread:
            return "Background task completed"
        case .failedDelivery:
            return "Message failed to send"
        }
    }
}

private struct ConversationActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: ConversationActivityState?

    var body: some View {
        ZStack {
            if let state {
                indicator(for: state)
                    .id(state)
                    .transition(AppMotion.statusTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(
            width: SidebarMetrics.activityIndicatorSlotSize,
            height: SidebarMetrics.activityIndicatorSlotSize
        )
        .animation(AppMotion.statusChange, value: state)
    }

    @ViewBuilder
    private func indicator(for state: ConversationActivityState) -> some View {
        switch state {
        case .actionRequired, .completedUnread:
            ConversationStatusDot(state: state)
        case .working:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Agent working")
        case .failedDelivery:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(.systemRed))
                .accessibilityLabel("Message failed to send")
        }
    }
}

private func sidebarContextMenuLabel(_ title: String, systemImage: String, color: Color) -> some View {
    Label {
        Text(title)
            .foregroundStyle(color)
    } icon: {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
    }
    .tint(color)
}
