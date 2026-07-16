import SwiftUI
// Sidebar view for the chat shell.
struct ChatSidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    let safeAreaInsets: EdgeInsets
    let onSelectConversation: (Conversation) -> Void
    let onNewChat: (AgentConnection) -> Void
    let onManageAgents: () -> Void
    let onSettings: () -> Void

    @State private var expandedAgentIDs = Set<String>()
    @State private var deleteTarget: Conversation?
    @State private var focusedAgentID: String?

    var body: some View {
        VStack(spacing: 0) {
            sidebarList

            footer
        }
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
        .onAppear {
            if expandedAgentIDs.isEmpty {
                expandedAgentIDs = Set(viewModel.agents.prefix(1).map(\.id))
            }
            if let activeAgentID = viewModel.activeAgentID {
                expandedAgentIDs.insert(activeAgentID)
                focusedAgentID = activeAgentID
            } else {
                focusedAgentID = viewModel.agents.first?.id
            }
        }
        .onChange(of: viewModel.activeAgentID) {
            if let activeAgentID = viewModel.activeAgentID {
                expandedAgentIDs.insert(activeAgentID)
                focusedAgentID = activeAgentID
            }
        }
        .alert("Delete Chat", isPresented: isDeleting, presenting: deleteTarget) { conversation in
            Button("Delete", role: .destructive) {
                viewModel.deleteConversation(conversation)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: { conversation in
            Text("\"\(conversation.title)\" will be permanently deleted.")
        }
    }

    private var sidebarList: some View {
        List {
            Section {
                header
                    .listRowInsets(
                        EdgeInsets(
                            top: safeAreaInsets.top + SidebarMetrics.headerTopPadding,
                            leading: SidebarMetrics.outerLeading,
                            bottom: SidebarMetrics.headerBottomPadding,
                            trailing: SidebarMetrics.outerTrailing
                        )
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                Button(action: onManageAgents) {
                    Label("Agents", systemImage: "globe")
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.primary)
                .buttonStyle(SidebarPressedRowButtonStyle())
                .listRowInsets(SidebarMetrics.primaryRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                if viewModel.agents.isEmpty {
                    Text("No agents connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowInsets(SidebarMetrics.emptyRowInsets)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(viewModel.agents) { agent in
                        agentRows(for: agent)
                    }
                }
            } header: {
                agentsHeader
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, SidebarMetrics.minimumRowHeight)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.headerSpacing) {
            HStack(spacing: SidebarMetrics.headerLogoSpacing) {
                Image("OnionLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: SidebarMetrics.logoSize, height: SidebarMetrics.logoSize)

                Text("oo-chat")
                    .font(.title3.bold())
                    .lineLimit(1)
            }

            HStack(spacing: SidebarMetrics.statusSpacing) {
                Circle()
                    .fill(viewModel.onlineAgentCount > 0 ? Color(.systemGreen) : Color(.tertiaryLabel))
                    .frame(width: SidebarMetrics.statusDotSize, height: SidebarMetrics.statusDotSize)

                Text(connectionSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var agentsHeader: some View {
        HStack {
            Text("AGENTS")
            Spacer()
            Text("\(viewModel.agents.count)")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, SidebarMetrics.sectionHeaderHorizontalPadding)
    }

    private var footer: some View {
        HStack {
            Button {
                if let agent = newChatAgent {
                    onNewChat(agent)
                }
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SidebarMetrics.newChatHorizontalPadding)
                    .frame(height: SidebarMetrics.footerButtonSize)
                    .background(AppTheme.primary, in: Capsule())
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .disabled(newChatAgent == nil)
            .accessibilityLabel("New Chat")

            Spacer()

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .imageScale(.large)
                    .foregroundStyle(.primary)
                    .frame(width: SidebarMetrics.footerButtonSize, height: SidebarMetrics.footerButtonSize)
                    .glassBackground(in: Circle(), interactive: true, tint: Color(.systemBackground))
                    .overlay {
                        Circle()
                            .stroke(Color(.separator).opacity(SidebarMetrics.settingsButtonStrokeOpacity), lineWidth: 0.5)
                    }
                    .shadow(
                        color: Color(.label).opacity(SidebarMetrics.settingsButtonShadowOpacity),
                        radius: SidebarMetrics.settingsButtonShadowRadius,
                        x: 0,
                        y: SidebarMetrics.settingsButtonShadowYOffset
                    )
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .tint(Color(.label))
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, SidebarMetrics.outerLeading)
        .padding(.bottom, safeAreaInsets.bottom + SidebarMetrics.footerBottomPadding)
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    private var newChatAgent: AgentConnection? {
        focusedAgent ?? viewModel.activeAgent ?? viewModel.agents.first
    }

    private var focusedAgent: AgentConnection? {
        guard let focusedAgentID else {
            return nil
        }
        return viewModel.agent(withID: focusedAgentID)
    }

    @ViewBuilder
    private func agentRows(for agent: AgentConnection) -> some View {
        agentRow(for: agent)
            .listRowInsets(SidebarMetrics.agentRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

        if expandedAgentIDs.contains(agent.id) {
            let conversations = viewModel.conversations(for: agent)
            if conversations.isEmpty {
                Text("No chat sessions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(SidebarMetrics.emptySessionRowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(conversations) { conversation in
                    conversationButton(conversation)
                }
            }
        }
    }

    private func agentRow(for agent: AgentConnection) -> some View {
        let isOnline = viewModel.isAgentOnline(agent)
        return HStack(spacing: SidebarMetrics.agentRowSpacing) {
            Button {
                toggleAgent(agent)
            } label: {
                Image(systemName: expandedAgentIDs.contains(agent.id) ? "chevron.down" : "chevron.forward")
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarMetrics.chevronWidth, height: SidebarMetrics.agentRowHeight)
            }
            .buttonStyle(.plain)

            Button {
                toggleAgent(agent)
            } label: {
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
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                focusedAgentID = agent.id
                onNewChat(agent)
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .tint(Color(.systemBlue))
        }
        .contextMenu {
            Button {
                focusedAgentID = agent.id
                onNewChat(agent)
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
    }

    private func conversationButton(_ conversation: Conversation) -> some View {
        let isSelected = viewModel.activeConversationID == conversation.id

        return Button {
            focusedAgentID = conversation.agentID
            onSelectConversation(conversation)
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

                    if viewModel.hasPendingInteraction(forConversationID: conversation.id) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color(.systemOrange))
                            .accessibilityLabel("Approval required")
                    } else if viewModel.isProcessing(conversationID: conversation.id) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Agent working")
                    }
                }
                .padding(.leading, SidebarMetrics.sessionIndent)
            }
        }
        .buttonStyle(SidebarConversationButtonStyle(isSelected: isSelected))
        .listRowInsets(SidebarMetrics.conversationRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = conversation
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(Color(.systemRed))
        }
        .contextMenu {
            Button(role: .destructive) {
                deleteTarget = conversation
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text("Delete")) {
            deleteTarget = conversation
        }
    }

    private var connectionSummary: String {
        let count = viewModel.onlineAgentCount
        let noun = count == 1 ? "agent" : "agents"
        return "\(count) \(noun) online"
    }

    private func toggleAgent(_ agent: AgentConnection) {
        focusedAgentID = agent.id
        if expandedAgentIDs.contains(agent.id) {
            expandedAgentIDs.remove(agent.id)
        } else {
            expandedAgentIDs.insert(agent.id)
        }
    }

    private func agentInitial(for agent: AgentConnection) -> String {
        guard let first = agent.name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "A"
        }
        return String(first).uppercased()
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
}

// Sidebar metrics and constants.
private enum SidebarMetrics {
    static let outerLeading: CGFloat = 22
    static let outerTrailing: CGFloat = 18
    static let rowLeading: CGFloat = 22
    static let compactRowLeading: CGFloat = 12
    static let compactRowTrailing: CGFloat = 10
    static let headerTopPadding: CGFloat = 18
    static let headerBottomPadding: CGFloat = 18
    static let headerSpacing: CGFloat = 12
    static let headerLogoSpacing: CGFloat = 12
    static let logoSize: CGFloat = 34
    static let statusSpacing: CGFloat = 10
    static let statusDotSize: CGFloat = 8
    static let sectionHeaderHorizontalPadding: CGFloat = 10
    static let minimumRowHeight: CGFloat = 0
    static let footerButtonSize: CGFloat = 50
    static let footerBottomPadding: CGFloat = 20
    static let newChatHorizontalPadding: CGFloat = 18
    static let settingsButtonStrokeOpacity: Double = 0.20
    static let settingsButtonShadowOpacity: Double = 0.07
    static let settingsButtonShadowRadius: CGFloat = 14
    static let settingsButtonShadowYOffset: CGFloat = 6
    static let chevronWidth: CGFloat = 24
    static let agentRowSpacing: CGFloat = 8
    static let agentRowHeight: CGFloat = 34
    static let avatarSize: CGFloat = 32
    static let agentAvatarSpacing: CGFloat = 10
    static let agentNameSpacing: CGFloat = 8
    static let sessionIndent: CGFloat = 44
    static let sessionIconWidth: CGFloat = 18
    static let sessionContentSpacing: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 10
    static let conversationTextLeading = rowLeading + rowHorizontalPadding + sessionIndent + sessionIconWidth + sessionContentSpacing

    static let primaryRowInsets = EdgeInsets(top: 2, leading: compactRowLeading, bottom: 2, trailing: compactRowTrailing)
    static let emptyRowInsets = EdgeInsets(top: 8, leading: rowLeading, bottom: 8, trailing: outerTrailing)
    static let agentRowInsets = EdgeInsets(top: 4, leading: rowLeading, bottom: 4, trailing: 14)
    static let conversationRowInsets = EdgeInsets(top: 0, leading: rowLeading, bottom: 0, trailing: compactRowTrailing)
    static let emptySessionRowInsets = EdgeInsets(top: 6, leading: conversationTextLeading, bottom: 6, trailing: outerTrailing)
}
