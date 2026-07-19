import SwiftUI
// Sidebar view for the chat shell.
struct ChatSidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let safeAreaInsets: EdgeInsets
    let isSidebarOpen: Bool
    @Binding var isSearchFocused: Bool
    let selection: ChatSidebarSelection?
    let onSelectConversation: (Conversation) -> Void
    let onAddChat: (AgentConnection) -> Void
    let onConnected: () -> Void
    let onSettings: () -> Void

    @State private var expandedAgentIDs = Set<String>()
    @State private var deleteTarget: Conversation?
    @State private var conversationRenameTarget: Conversation?
    @State private var conversationRenameText = ""
    @State private var agentRenameTarget: AgentConnection?
    @State private var agentRenameText = ""
    @State private var agentDeleteTarget: AgentConnection?
    @State private var agentFormDraft: AgentFormDraft?
    @State private var qrCodeShareURL: URL?
    @State private var focusedAgentID: String?
    @State private var isSearchVisible = false
    @State private var sidebarSearchText = ""
    @FocusState private var isSearchFieldFocused: Bool

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
        .onChange(of: isSidebarOpen) {
            if !isSidebarOpen {
                resetSidebarSearch()
            }
        }
        .onChange(of: isSearchFieldFocused) {
            isSearchFocused = isSearchFieldFocused
        }
        .onChange(of: isSearchFocused) {
            if !isSearchFocused {
                isSearchFieldFocused = false
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
        .alert("Rename Chat", isPresented: isRenamingConversation, presenting: conversationRenameTarget) { conversation in
            TextField("Title", text: $conversationRenameText)
            Button("Cancel", role: .cancel) {
                conversationRenameTarget = nil
                conversationRenameText = ""
            }
            Button("Save") {
                renameConversation(conversation)
            }
            .disabled(conversationRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { conversation in
            Text("Enter a new name for \(conversation.title).")
        }
        .alert("Rename Agent", isPresented: isRenamingAgent, presenting: agentRenameTarget) { agent in
            TextField("Name", text: $agentRenameText)
            Button("Cancel", role: .cancel) {
                agentRenameTarget = nil
                agentRenameText = ""
            }
            Button("Save") {
                renameAgent(agent)
            }
            .disabled(agentRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { agent in
            Text("Enter a new name for \(agent.name).")
        }
        .alert("Delete Agent?", isPresented: isDeletingAgent, presenting: agentDeleteTarget) { agent in
            Button("Delete", role: .destructive) {
                viewModel.deleteAgent(agent)
                agentDeleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                agentDeleteTarget = nil
            }
        } message: { agent in
            Text("This removes \(agent.name) and its chat sessions.")
        }
        .sheet(isPresented: isPresentingQRCodeShare) {
            if let qrCodeShareURL {
                AgentQRCodeShareView(url: qrCodeShareURL)
            }
        }
        .sheet(item: $agentFormDraft) { draft in
            AgentFormView(draft: draft) { savedDraft in
                saveAgentDraft(savedDraft)
            } onCancel: {
                agentFormDraft = nil
            }
        }
    }

    private var sidebarList: some View {
        List {
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

            agentsHeader
                .listRowInsets(
                    EdgeInsets(
                        top: SidebarMetrics.agentsHeaderTopPadding,
                        leading: SidebarMetrics.outerLeading,
                        bottom: SidebarMetrics.agentsHeaderBottomPadding,
                        trailing: SidebarMetrics.outerTrailing
                    )
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if viewModel.agents.isEmpty {
                Text("No agents connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(SidebarMetrics.emptyRowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if visibleAgents.isEmpty {
                Text("No matches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(SidebarMetrics.emptyRowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(visibleAgents) { agent in
                    agentRows(for: agent)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, SidebarMetrics.minimumRowHeight)
        .animation(
            AppMotion.stateChange(reduceMotion: reduceMotion),
            value: expandedAgentIDs
        )
    }

    private var searchQuery: String {
        sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty
    }

    private var visibleAgents: [AgentConnection] {
        guard isSearching else {
            return viewModel.agents
        }

        return viewModel.agents.filter { agent in
            agentMatches(agent, query: searchQuery)
                || !matchingConversations(for: agent, query: searchQuery).isEmpty
        }
    }

    private var sidebarResultCount: Int {
        guard isSearching else {
            return visibleAgents.count
        }

        return visibleAgents.reduce(0) { count, agent in
            count
                + (agentMatches(agent, query: searchQuery) ? 1 : 0)
                + matchingConversations(for: agent, query: searchQuery).count
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.headerSpacing) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: SidebarMetrics.headerSpacing) {
                    brandTitle
                    connectionStatus
                }
                .padding(.top, SidebarMetrics.brandTopPadding)
                .padding(.trailing, SidebarMetrics.headerIconButtonSize + SidebarMetrics.headerTrailingSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)

                searchToggleButton
                    .offset(y: SidebarMetrics.searchButtonVerticalOffset)
            }

            if isSearchVisible {
                searchField
                    .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
            }
        }
    }

    private var brandTitle: some View {
        HStack(spacing: SidebarMetrics.headerLogoSpacing) {
            Image("OnionLogo")
                .resizable()
                .scaledToFit()
                .frame(width: SidebarMetrics.logoSize, height: SidebarMetrics.logoSize)

            Text("oo-chat")
                .font(.title3.bold())
                .lineLimit(1)
        }
    }

    private var connectionStatus: some View {
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

    private var searchToggleButton: some View {
        Button {
            toggleSidebarSearch()
        } label: {
            Image(systemName: isSearchVisible ? "xmark" : "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.primary)
                .frame(width: SidebarMetrics.headerIconButtonSize, height: SidebarMetrics.headerIconButtonSize)
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
        .accessibilityLabel(isSearchVisible ? "Close search" : "Search")
    }

    private var searchField: some View {
        HStack(spacing: SidebarMetrics.searchFieldSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.secondaryLabel))

            TextField("Search", text: $sidebarSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFieldFocused)

            if !sidebarSearchText.isEmpty {
                Button {
                    sidebarSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: SidebarMetrics.searchClearButtonSize, height: SidebarMetrics.searchClearButtonSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, SidebarMetrics.searchFieldHorizontalPadding)
        .frame(height: SidebarMetrics.searchFieldHeight)
        .background(Color(.secondarySystemFill), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private var agentsHeader: some View {
        HStack {
            Text(isSearching ? "SEARCH RESULTS" : "AGENTS")
            Spacer()
            Text("\(sidebarResultCount)")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, SidebarMetrics.sectionHeaderHorizontalPadding)
    }

    private var footer: some View {
        HStack {
            Button(action: beginAddingAgent) {
                Label("New Agent", systemImage: "person.badge.plus")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SidebarMetrics.footerButtonHorizontalPadding)
                    .frame(height: SidebarMetrics.footerButtonSize)
                    .background(AppTheme.primary, in: Capsule())
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .accessibilityLabel("Add Agent")

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

    @ViewBuilder
    private func agentRows(for agent: AgentConnection) -> some View {
        agentRow(for: agent)
            .listRowInsets(SidebarMetrics.agentRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

        if expandedAgentIDs.contains(agent.id) || isSearching {
            let conversations = visibleConversations(for: agent)
            if conversations.isEmpty {
                if !isSearching {
                    Text("No chat sessions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(AppMotion.disclosure(reduceMotion: reduceMotion))
                        .listRowInsets(SidebarMetrics.emptySessionRowInsets)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(conversations) { conversation in
                    conversationButton(conversation)
                        .transition(AppMotion.disclosure(reduceMotion: reduceMotion))
                }
            }
        }
    }

    private func visibleConversations(for agent: AgentConnection) -> [Conversation] {
        let conversations = viewModel.conversations(for: agent)
        guard isSearching else {
            return conversations
        }

        return matchingConversations(for: agent, query: searchQuery)
    }

    private func matchingConversations(for agent: AgentConnection, query: String) -> [Conversation] {
        viewModel.searchConversations(query, for: agent)
    }

    private func agentMatches(_ agent: AgentConnection, query: String) -> Bool {
        agent.name.localizedStandardContains(query)
            || agent.address.localizedStandardContains(query)
    }

    private func toggleSidebarSearch() {
        let shouldShowSearch = !isSearchVisible
        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
            isSearchVisible = shouldShowSearch
            if !shouldShowSearch {
                sidebarSearchText = ""
            }
        }

        if shouldShowSearch {
            DispatchQueue.main.async {
                isSearchFieldFocused = true
                isSearchFocused = true
            }
        } else {
            resetSidebarSearch()
        }
    }

    private func resetSidebarSearch() {
        isSearchVisible = false
        sidebarSearchText = ""
        isSearchFieldFocused = false
        isSearchFocused = false
    }

    private func agentRow(for agent: AgentConnection) -> some View {
        let isOnline = viewModel.isAgentOnline(agent)
        return Button {
            toggleAgent(agent)
        } label: {
            HStack(spacing: SidebarMetrics.agentRowSpacing) {
                Image(systemName: "chevron.forward")
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarMetrics.chevronWidth, height: SidebarMetrics.agentRowHeight)
                    .rotationEffect(.degrees(expandedAgentIDs.contains(agent.id) ? 90 : 0))

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
                beginRenaming(agent)
            } label: {
                contextMenuLabel("Rename", systemImage: "pencil", color: Color(.label))
            }
            .tint(Color(.label))

            Button {
                beginEditing(agent)
            } label: {
                contextMenuLabel("Edit Agent", systemImage: "slider.horizontal.3", color: Color(.label))
            }
            .tint(Color(.label))

            Button {
                focusedAgentID = agent.id
                expandedAgentIDs.insert(agent.id)
                onAddChat(agent)
            } label: {
                contextMenuLabel("Add Chat", systemImage: "plus.bubble", color: Color(.label))
            }
            .tint(Color(.label))

            if let shareURL = AgentShareURL.url(for: agent.address) {
                ShareLink(item: shareURL) {
                    contextMenuLabel("Share Link", systemImage: "square.and.arrow.up", color: Color(.label))
                }
                .tint(Color(.label))

                Button {
                    qrCodeShareURL = shareURL
                } label: {
                    contextMenuLabel("Show QR Code", systemImage: "qrcode", color: Color(.label))
                }
                .tint(Color(.label))
            }

            Button(role: .destructive) {
                agentDeleteTarget = agent
            } label: {
                contextMenuLabel("Delete", systemImage: "trash", color: AppTheme.destructive)
            }
            .tint(AppTheme.destructive)
        }
    }

    private func conversationButton(_ conversation: Conversation) -> some View {
        let isSelected = selection == .conversation(conversation.id)

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
        .contextMenu {
            Button {
                beginRenaming(conversation)
            } label: {
                contextMenuLabel("Rename", systemImage: "pencil", color: Color(.label))
            }
            .tint(Color(.label))

            Button(role: .destructive) {
                deleteTarget = conversation
            } label: {
                contextMenuLabel("Delete", systemImage: "trash", color: AppTheme.destructive)
            }
            .tint(AppTheme.destructive)
        }
        .accessibilityAction(named: Text("Delete")) {
            deleteTarget = conversation
        }
        .accessibilityAction(named: Text("Rename")) {
            beginRenaming(conversation)
        }
    }

    private var connectionSummary: String {
        let count = viewModel.onlineAgentCount
        let noun = count == 1 ? "agent" : "agents"
        return "\(count) \(noun) online"
    }

    private func toggleAgent(_ agent: AgentConnection) {
        focusedAgentID = agent.id
        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
            if expandedAgentIDs.contains(agent.id) {
                expandedAgentIDs.remove(agent.id)
            } else {
                expandedAgentIDs.insert(agent.id)
            }
        }
    }

    private func beginRenaming(_ agent: AgentConnection) {
        focusedAgentID = agent.id
        agentRenameText = agent.name
        agentRenameTarget = agent
    }

    private func beginAddingAgent() {
        agentFormDraft = AgentFormDraft()
    }

    private func beginEditing(_ agent: AgentConnection) {
        focusedAgentID = agent.id
        agentFormDraft = AgentFormDraft(agent: agent)
    }

    private func saveAgentDraft(_ savedDraft: AgentFormDraft) -> Bool {
        guard let agent = viewModel.saveAgent(
            id: savedDraft.agentID,
            name: savedDraft.name,
            address: savedDraft.address,
            token: savedDraft.token
        ) else {
            return false
        }

        focusedAgentID = agent.id
        expandedAgentIDs.insert(agent.id)
        agentFormDraft = nil

        if savedDraft.shouldConnectAfterSave {
            connect(agent)
        }

        return true
    }

    private func connect(_ agent: AgentConnection) {
        focusedAgentID = agent.id
        expandedAgentIDs.insert(agent.id)
        viewModel.selectAgent(agent)

        Task { @MainActor in
            if await viewModel.connectToAgent() != nil {
                onConnected()
            }
        }
    }

    private func renameAgent(_ agent: AgentConnection) {
        let trimmedName = agentRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            agentRenameTarget = nil
            agentRenameText = ""
        }

        guard !trimmedName.isEmpty else {
            return
        }

        _ = viewModel.saveAgent(
            id: agent.id,
            name: trimmedName,
            address: agent.address,
            token: agent.token
        )
    }

    private func beginRenaming(_ conversation: Conversation) {
        focusedAgentID = conversation.agentID
        conversationRenameText = conversation.title
        conversationRenameTarget = conversation
    }

    private func renameConversation(_ conversation: Conversation) {
        let trimmedTitle = conversationRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            conversationRenameTarget = nil
            conversationRenameText = ""
        }

        guard !trimmedTitle.isEmpty else {
            return
        }

        viewModel.renameConversation(conversation, to: trimmedTitle)
    }

    private func contextMenuLabel(_ title: String, systemImage: String, color: Color) -> some View {
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

    private func agentInitial(for agent: AgentConnection) -> String {
        guard let first = agent.name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "A"
        }
        return String(first).uppercased()
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var isRenamingConversation: Binding<Bool> {
        Binding(
            get: { conversationRenameTarget != nil },
            set: { isPresented in
                if !isPresented {
                    conversationRenameTarget = nil
                    conversationRenameText = ""
                }
            }
        )
    }

    private var isRenamingAgent: Binding<Bool> {
        Binding(
            get: { agentRenameTarget != nil },
            set: { isPresented in
                if !isPresented {
                    agentRenameTarget = nil
                    agentRenameText = ""
                }
            }
        )
    }

    private var isDeletingAgent: Binding<Bool> {
        Binding(get: { agentDeleteTarget != nil }, set: { if !$0 { agentDeleteTarget = nil } })
    }

    private var isPresentingQRCodeShare: Binding<Bool> {
        Binding(
            get: { qrCodeShareURL != nil },
            set: { isPresented in
                if !isPresented {
                    qrCodeShareURL = nil
                }
            }
        )
    }
}

enum ChatSidebarSelection: Equatable {
    case conversation(String)
}

// Sidebar metrics and constants.
private enum SidebarMetrics {
    static let outerLeading: CGFloat = 22
    static let outerTrailing: CGFloat = 18
    static let rowLeading: CGFloat = 22
    static let compactRowLeading: CGFloat = 12
    static let compactRowTrailing: CGFloat = 10
    static let headerTopPadding: CGFloat = 8
    static let headerBottomPadding: CGFloat = 26
    static let headerSpacing: CGFloat = 12
    static let headerLogoSpacing: CGFloat = 12
    static let brandTopPadding: CGFloat = -3
    static let headerTrailingSpacing: CGFloat = 12
    static let headerIconButtonSize: CGFloat = 44
    static let searchButtonVerticalOffset: CGFloat = -8
    static let logoSize: CGFloat = 34
    static let statusSpacing: CGFloat = 10
    static let statusDotSize: CGFloat = 8
    static let searchFieldSpacing: CGFloat = 8
    static let searchFieldHorizontalPadding: CGFloat = 12
    static let searchFieldHeight: CGFloat = 42
    static let searchClearButtonSize: CGFloat = 24
    static let agentsHeaderTopPadding: CGFloat = 0
    static let agentsHeaderBottomPadding: CGFloat = 10
    static let sectionHeaderHorizontalPadding: CGFloat = 10
    static let minimumRowHeight: CGFloat = 0
    static let footerButtonSize: CGFloat = 50
    static let footerBottomPadding: CGFloat = 20
    static let footerButtonHorizontalPadding: CGFloat = 18
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
    static let sessionIndent: CGFloat = 36
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
