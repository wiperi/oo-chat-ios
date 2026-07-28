import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void

    init(
        viewModel: ChatViewModel,
        showsComposer: Bool = true,
        showsSidebarButton: Bool = true,
        onOpenSidebar: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.showsComposer = showsComposer
        self.showsSidebarButton = showsSidebarButton
        self.onOpenSidebar = onOpenSidebar
    }

    var body: some View {
        NavigationStack {
            ChatScreen(
                viewModel: viewModel,
                showsComposer: showsComposer,
                showsSidebarButton: showsSidebarButton,
                onOpenSidebar: onOpenSidebar
            )
        }
    }
}

struct ChatScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    var showsSidebarButton: Bool = true
    let onOpenSidebar: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bottomAnchorY: CGFloat = 0
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var shouldFollowLatest = true
    @State private var promptFocusRequest = 0
    @State private var isPromptFocused = false
    private let bottomAnchorID = "chat.bottomAnchor"
    private let scrollCoordinateSpace = "chat.scroll"

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = viewModel.activeConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if shouldShowEmptyState(for: conversation) {
                                EmptyChatState(
                                    agentName: viewModel.activeAgent?.name ?? "Your agent",
                                    showsSuggestions: showsComposer
                                ) { suggestion in
                                    viewModel.prompt = suggestion.prompt
                                    promptFocusRequest += 1
                                }
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: max(0, scrollViewportHeight - 32),
                                    alignment: .bottom
                                )
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            ForEach(timelineEntries(for: conversation)) { entry in
                                timelineView(for: entry)
                                    .id(entry.id)
                                    .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let approval = viewModel.activePendingApproval {
                                ApprovalCard(approval: approval) {
                                    viewModel.allowPendingApprovalOnce(id: approval.id)
                                } onTrustSession: {
                                    viewModel.trustPendingApprovalForSession(id: approval.id)
                                } onReject: {
                                    viewModel.rejectPendingApproval(id: approval.id)
                                } onStop: {
                                    viewModel.stopPendingApproval(id: approval.id)
                                } onExplain: {
                                    viewModel.explainPendingApproval(id: approval.id)
                                }
                                .id("pendingApproval")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let checkpoint = viewModel.activePendingUlwCheckpoint {
                                UlwCheckpointCard(checkpoint: checkpoint) {
                                    viewModel.continueUlw(id: checkpoint.id)
                                } onAcceptEdits: {
                                    viewModel.switchModeFromUlwCheckpoint(id: checkpoint.id, to: .accept)
                                } onSafeMode: {
                                    viewModel.switchModeFromUlwCheckpoint(id: checkpoint.id, to: .safe)
                                }
                                .id("pendingUlwCheckpoint")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let review = viewModel.activePendingPlanReview {
                                PlanReviewCard(review: review) {
                                    viewModel.approvePendingPlan(id: review.id)
                                } onRequestChanges: { feedback in
                                    viewModel.requestPlanChanges(id: review.id, feedback: feedback)
                                }
                                .id("pendingPlanReview")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let pending = viewModel.activePendingAskUser {
                                AskUserCard(pending: pending) { answer in
                                    viewModel.answerPendingAskUser(id: pending.id, answer: answer)
                                }
                                .id("pendingAskUser")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ChatBottomAnchorPreferenceKey.self,
                                            value: geometry.frame(
                                                in: .named(scrollCoordinateSpace)
                                            ).maxY
                                        )
                                    }
                                }
                        }
                        .id(conversation.id)
                        .transition(conversationTransition)
                        .padding(.horizontal)
                        .padding(.vertical, 16)
                        .frame(maxWidth: ChatReadableWidth.maximum)
                        .frame(maxWidth: .infinity)
                        .animation(
                            AppMotion.contentArrival(reduceMotion: reduceMotion),
                            value: conversation.messages.map(\.id)
                        )
                        .animation(
                            AppMotion.contentArrival(reduceMotion: reduceMotion),
                            value: viewModel.pendingInteractionID
                        )
                    }
                    .coordinateSpace(name: scrollCoordinateSpace)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ChatViewportHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: scrollUpdate(for: conversation)) { previous, current in
                        guard shouldFollowLatest else {
                            return
                        }
                        scrollToBottom(
                            proxy,
                            animated: current.isNewMessage(comparedTo: previous)
                        )
                    }
                    .onChange(of: viewModel.pendingInteractionID) {
                        if let interactionID = viewModel.pendingInteractionID {
                            withAnimation(AppMotion.contentArrival(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(scrollTarget(for: interactionID), anchor: .bottom)
                            }
                        }
                    }
                    .onPreferenceChange(ChatBottomAnchorPreferenceKey.self) { value in
                        bottomAnchorY = value
                        updateFollowLatest()
                    }
                    .onPreferenceChange(ChatViewportHeightPreferenceKey.self) { value in
                        let wasFollowingLatest = shouldFollowLatest
                        scrollViewportHeight = value
                        updateFollowLatest()
                        if isPromptFocused && wasFollowingLatest {
                            scrollToBottom(proxy)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if showsComposer {
                            Composer(
                                viewModel: viewModel,
                                focusRequest: promptFocusRequest
                            ) { isFocused in
                                isPromptFocused = isFocused
                                guard isFocused, shouldFollowLatest else {
                                    return
                                }
                                scrollToBottomAfterKeyboardLayout(proxy)
                            }
                                .padding(.top, 8)
                                .background {
                                    ChatSurfacePalette.backgroundBase
                                        .ignoresSafeArea(edges: .bottom)
                                }
                        }
                    }
                }
            } else {
                ContentUnavailableView("No Conversation", systemImage: "bubble.left")
            }
        }
        .background {
            ChatScreenBackdrop()
                .ignoresSafeArea()
        }
        .navigationTitle(viewModel.activeConversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(viewModel.activeConversation?.title ?? "Chat")
                        .font(.headline)
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    HStack {
                        StatusPill(state: viewModel.connectionState)
                    }
                    .contentTransition(.opacity)
                }
                .animation(
                    AppMotion.stateChange(reduceMotion: reduceMotion),
                    value: viewModel.activeConversationID
                )
            }

            if showsSidebarButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onOpenSidebar()
                    } label: {
                        Image(systemName: "sidebar.left")
                            .overlay(alignment: .topTrailing) {
                                if let state = viewModel.backgroundActivityState {
                                    ConversationStatusDot(state: state)
                                        .offset(x: 4, y: -3)
                                        .transition(AppMotion.statusTransition(reduceMotion: reduceMotion))
                                }
                            }
                            .animation(AppMotion.statusChange, value: viewModel.backgroundActivityState)
                    }
                    .accessibilityLabel(backgroundAttentionLabel)
                }
            }
        }
    }

    private func shouldShowEmptyState(for conversation: Conversation) -> Bool {
        conversation.messages.isEmpty && viewModel.pendingInteractionID == nil
    }

    private var backgroundAttentionLabel: String {
        switch viewModel.backgroundActivityState {
        case .actionRequired:
            return "Open sidebar, action required"
        case .failedDelivery:
            return "Open sidebar, a message failed to send"
        case .completedUnread:
            return "Open sidebar, background task completed"
        case .working, nil:
            return "Open sidebar"
        }
    }

    private func scrollTarget(for interactionID: String) -> String {
        if interactionID == viewModel.activePendingApproval?.id {
            return "pendingApproval"
        }
        if interactionID == viewModel.activePendingUlwCheckpoint?.id {
            return "pendingUlwCheckpoint"
        }
        if interactionID == viewModel.activePendingPlanReview?.id {
            return "pendingPlanReview"
        }
        return "pendingAskUser"
    }

    private func shouldShowMessage(_ message: ChatMessage, in conversationID: String) -> Bool {
        !viewModel.isToolCallCoveredByPendingApproval(message, in: conversationID)
    }

    private func timelineEntries(for conversation: Conversation) -> [ChatTimelineEntry] {
        ChatTimelineBuilder.entries(
            from: conversation.messages.filter {
                shouldShowMessage($0, in: conversation.id)
            }
        )
    }

    @ViewBuilder
    private func timelineView(for entry: ChatTimelineEntry) -> some View {
        switch entry {
        case .message(let message):
            MessageBubble(message: message) {
                viewModel.retryMessage(message)
            }
        case .toolCallGroup(let messages):
            ToolCallGroupView(messages: messages)
        }
    }

    private func scrollUpdate(for conversation: Conversation) -> ChatScrollUpdate {
        let message = conversation.messages.last
        return ChatScrollUpdate(
            conversationID: conversation.id,
            messageCount: conversation.messages.count,
            messageID: message?.id,
            contentLength: message?.content.count ?? 0,
            deliveryState: message?.deliveryState.rawValue ?? "",
            toolState: message?.toolState?.rawValue ?? ""
        )
    }

    private func updateFollowLatest() {
        guard scrollViewportHeight > 0 else {
            return
        }
        shouldFollowLatest = bottomAnchorY - scrollViewportHeight
            <= ChatScrollMetrics.followThreshold
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func scrollToBottomAfterKeyboardLayout(_ proxy: ScrollViewProxy) {
        scrollToBottom(proxy)
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatScrollMetrics.keyboardFollowUpDelay) {
            guard isPromptFocused else {
                return
            }
            scrollToBottom(proxy)
        }
    }

    private var conversationTransition: AnyTransition {
        guard !reduceMotion else {
            return .opacity
        }

        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 10, y: 0)),
            removal: .opacity
        )
    }
}

private struct ChatScreenBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ChatSurfacePalette.backgroundBase

            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        ChatSurfacePalette.darkTopWash,
                        ChatSurfacePalette.darkMidnight,
                        ChatSurfacePalette.darkLowerInk,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [
                        AppTheme.primary.opacity(0.14),
                        AppTheme.primary.opacity(0.05),
                        AppTheme.primary.opacity(0),
                    ],
                    center: UnitPoint(x: 0.50, y: 0.40),
                    startRadius: 18,
                    endRadius: 320
                )
                .blendMode(.screen)

                RadialGradient(
                    colors: [
                        ChatSurfacePalette.darkWarmLift,
                        ChatSurfacePalette.darkWarmLift.opacity(0),
                    ],
                    center: UnitPoint(x: 0.18, y: 0.16),
                    startRadius: 10,
                    endRadius: 260
                )
                .blendMode(.screen)
            }
        }
    }
}

private enum ChatSurfacePalette {
    static let backgroundBase = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 7.0 / 255.0, green: 6.0 / 255.0, blue: 10.0 / 255.0, alpha: 1)
        } else {
            return .systemBackground
        }
    })

    static let darkTopWash = Color(red: 13.0 / 255.0, green: 10.0 / 255.0, blue: 18.0 / 255.0)
    static let darkMidnight = Color(red: 6.0 / 255.0, green: 5.0 / 255.0, blue: 9.0 / 255.0)
    static let darkLowerInk = Color(red: 3.0 / 255.0, green: 3.0 / 255.0, blue: 5.0 / 255.0)
    static let darkWarmLift = Color(red: 76.0 / 255.0, green: 48.0 / 255.0, blue: 128.0 / 255.0)
        .opacity(0.07)
}

struct EmptyChatState: View {
    let agentName: String
    let showsSuggestions: Bool
    let onSelectSuggestion: (ChatStarterSuggestion) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var logoPulse = false

    var body: some View {
        VStack(spacing: EmptyChatMetrics.sectionSpacing) {
            VStack(spacing: EmptyChatMetrics.headingSpacing) {
                brandMark

                Text("What can we work on")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(EmptyChatPalette.heading)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: EmptyChatMetrics.headingMaximumWidth)
            }

            if showsSuggestions {
                LazyVGrid(columns: suggestionColumns, spacing: EmptyChatMetrics.chipSpacing) {
                    ForEach(ChatStarterSuggestion.defaults) { suggestion in
                        suggestionButton(for: suggestion)
                    }
                }
                .frame(maxWidth: EmptyChatMetrics.suggestionGroupMaximumWidth)
            }
        }
        .padding(.top, EmptyChatMetrics.topOffset)
        .padding(.vertical, EmptyChatMetrics.verticalPadding)
        .accessibilityLabel("Start with \(agentName)")
        .accessibilityElement(children: .contain)
    }

    private var brandMark: some View {
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AppTheme.primary.opacity(
                                EmptyChatMetrics.logoOuterAuraCoreOpacity(for: colorScheme)
                            ),
                            AppTheme.primary.opacity(
                                EmptyChatMetrics.logoOuterAuraEdgeOpacity(for: colorScheme)
                            ),
                            AppTheme.primary.opacity(0),
                        ],
                        center: .center,
                        startRadius: EmptyChatMetrics.logoOuterAuraStartRadius,
                        endRadius: EmptyChatMetrics.logoOuterAuraEndRadius
                    )
                )
                .frame(
                    width: EmptyChatMetrics.logoOuterAuraSize,
                    height: EmptyChatMetrics.logoOuterAuraSize
                )
                .blur(radius: EmptyChatMetrics.logoOuterAuraBlur)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AppTheme.primary.opacity(
                                EmptyChatMetrics.logoAuraCoreOpacity(for: colorScheme)
                            ),
                            AppTheme.primary.opacity(
                                EmptyChatMetrics.logoAuraEdgeOpacity(for: colorScheme)
                            ),
                            AppTheme.primary.opacity(0),
                        ],
                        center: .center,
                        startRadius: EmptyChatMetrics.logoAuraStartRadius,
                        endRadius: EmptyChatMetrics.logoAuraEndRadius
                    )
                )
                .frame(
                    width: EmptyChatMetrics.logoAuraSize,
                    height: EmptyChatMetrics.logoAuraSize
                )
                .blur(radius: EmptyChatMetrics.logoAuraBlur)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            EmptyChatPalette.logoBacklightCore,
                            EmptyChatPalette.logoBacklightEdge,
                            EmptyChatPalette.logoBacklightEdge.opacity(0),
                        ],
                        center: .center,
                        startRadius: EmptyChatMetrics.logoBacklightStartRadius,
                        endRadius: EmptyChatMetrics.logoBacklightEndRadius
                    )
                )
                .frame(
                    width: EmptyChatMetrics.logoBacklightSize,
                    height: EmptyChatMetrics.logoBacklightSize
                )
                .blur(radius: EmptyChatMetrics.logoBacklightBlur)

            Image("OnionLogo")
                .resizable()
                .scaledToFit()
                .frame(
                    width: EmptyChatMetrics.logoSize,
                    height: EmptyChatMetrics.logoSize
                )
                .opacity(EmptyChatMetrics.logoImageOpacity(for: colorScheme))
                .offset(y: EmptyChatMetrics.logoImageVerticalOffset)
                .shadow(
                    color: EmptyChatPalette.logoShadow.opacity(
                        EmptyChatMetrics.logoShadowOpacity(
                            isActive: logoPulse,
                            colorScheme: colorScheme
                        )
                    ),
                    radius: logoPulse ? EmptyChatMetrics.logoActiveShadowRadius : EmptyChatMetrics.logoIdleShadowRadius,
                    y: logoPulse ? EmptyChatMetrics.logoActiveShadowOffset : EmptyChatMetrics.logoIdleShadowOffset
                )
        }
        .frame(
            width: EmptyChatMetrics.logoStageSize,
            height: EmptyChatMetrics.logoStageSize
        )
        .scaleEffect(logoPulse && !reduceMotion ? 1.015 : 1)
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: EmptyChatMetrics.logoPulseDuration)
                    .repeatForever(autoreverses: true),
            value: logoPulse
        )
        .onAppear {
            guard !reduceMotion else {
                return
            }
            logoPulse = true
        }
        .accessibilityHidden(true)
    }

    private var suggestionColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }

        return [
            GridItem(.flexible(), spacing: EmptyChatMetrics.chipSpacing),
            GridItem(.flexible()),
        ]
    }

    private func suggestionButton(for suggestion: ChatStarterSuggestion) -> some View {
        Button {
            onSelectSuggestion(suggestion)
        } label: {
            suggestionChip(suggestion)
        }
        .buttonStyle(EmptyChatSuggestionButtonStyle())
        .accessibilityHint("\(suggestion.detail). Adds this starter to the message field")
    }

    private func suggestionChip(_ suggestion: ChatStarterSuggestion) -> some View {
        let chipShape = RoundedRectangle(
            cornerRadius: EmptyChatMetrics.chipCornerRadius,
            style: .continuous
        )

        return HStack(spacing: EmptyChatMetrics.chipContentSpacing) {
            Image(systemName: suggestion.systemImage)
                .font(.footnote.weight(.regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(EmptyChatPalette.chipIcon)
                .frame(
                    width: EmptyChatMetrics.chipIconSize,
                    height: EmptyChatMetrics.chipIconSize
                )

            Text(suggestion.title)
                .font(.subheadline.weight(.regular))
                .foregroundStyle(EmptyChatPalette.chipText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, EmptyChatMetrics.chipHorizontalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: EmptyChatMetrics.chipMinimumHeight,
            alignment: .leading
        )
        .background(
            EmptyChatPalette.chipFill,
            in: chipShape
        )
        .overlay {
            chipShape
                .stroke(
                    EmptyChatPalette.chipStroke,
                    lineWidth: 0.5
                )
        }
        .shadow(
            color: EmptyChatPalette.chipShadow,
            radius: EmptyChatMetrics.chipShadowRadius,
            y: EmptyChatMetrics.chipShadowOffset
        )
        .contentShape(chipShape)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyChatSuggestionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let chipShape = RoundedRectangle(
            cornerRadius: EmptyChatMetrics.chipCornerRadius,
            style: .continuous
        )

        configuration.label
            .overlay {
                chipShape
                    .fill(EmptyChatPalette.chipPressedFill)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                chipShape
                    .stroke(
                        EmptyChatPalette.chipPressedStroke,
                        lineWidth: configuration.isPressed ? 1 : 0
                    )
                    .opacity(configuration.isPressed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .animation(AppMotion.press, value: configuration.isPressed)
            .animation(AppMotion.press, value: isEnabled)
    }
}

struct ChatStarterSuggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let prompt: String

    static let defaults = [
        ChatStarterSuggestion(
            id: "plan-feature",
            title: "Plan a feature",
            detail: "Shape an idea into clear next steps",
            systemImage: "checklist",
            prompt: "Help me plan a feature. Ask for the goal and constraints, then give me a focused implementation plan."
        ),
        ChatStarterSuggestion(
            id: "review-code",
            title: "Review code",
            detail: "Find concrete issues and improvements",
            systemImage: "doc.text.magnifyingglass",
            prompt: "Review the relevant code for correctness, clarity, and maintainability. Prioritize concrete issues."
        ),
        ChatStarterSuggestion(
            id: "debug-problem",
            title: "Debug issue",
            detail: "Trace the cause and smallest fix",
            systemImage: "wrench.adjustable",
            prompt: "Help me debug a problem. Start by asking for the symptoms and expected behavior."
        ),
        ChatStarterSuggestion(
            id: "explain-project",
            title: "Explain project",
            detail: "Map the architecture and data flow",
            systemImage: "square.stack.3d.up",
            prompt: "Explain this project's architecture and trace the main data flow in plain language."
        ),
    ]
}

private enum EmptyChatPalette {
    static let heading = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 214.0 / 255.0, green: 199.0 / 255.0, blue: 246.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 122.0 / 255.0, green: 92.0 / 255.0, blue: 166.0 / 255.0, alpha: 1)
        }
    })

    static let chipText = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 225.0 / 255.0, green: 216.0 / 255.0, blue: 239.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 60.0 / 255.0, green: 53.0 / 255.0, blue: 72.0 / 255.0, alpha: 1)
        }
    })

    static let chipIcon = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 188.0 / 255.0, green: 158.0 / 255.0, blue: 248.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 124.0 / 255.0, green: 73.0 / 255.0, blue: 222.0 / 255.0, alpha: 0.72)
        }
    })

    static let chipFill = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 40.0 / 255.0, green: 36.0 / 255.0, blue: 49.0 / 255.0, alpha: 0.76)
        } else {
            return UIColor(red: 250.0 / 255.0, green: 248.0 / 255.0, blue: 253.0 / 255.0, alpha: 0.78)
        }
    })

    static let chipStroke = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 189.0 / 255.0, green: 154.0 / 255.0, blue: 248.0 / 255.0, alpha: 0.18)
        } else {
            return UIColor(red: 126.0 / 255.0, green: 88.0 / 255.0, blue: 208.0 / 255.0, alpha: 0.08)
        }
    })

    static let chipPressedFill = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 129.0 / 255.0, green: 84.0 / 255.0, blue: 228.0 / 255.0, alpha: 0.18)
        } else {
            return UIColor(red: 124.0 / 255.0, green: 73.0 / 255.0, blue: 222.0 / 255.0, alpha: 0.10)
        }
    })

    static let chipPressedStroke = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 178.0 / 255.0, green: 143.0 / 255.0, blue: 247.0 / 255.0, alpha: 0.28)
        } else {
            return UIColor(red: 124.0 / 255.0, green: 73.0 / 255.0, blue: 222.0 / 255.0, alpha: 0.22)
        }
    })

    static let chipShadow = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0, alpha: 0.28)
        } else {
            return UIColor(white: 0, alpha: 0.02)
        }
    })

    static let logoBacklightCore = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 222.0 / 255.0, green: 208.0 / 255.0, blue: 255.0 / 255.0, alpha: 0.14)
        } else {
            return UIColor(white: 1, alpha: 0)
        }
    })

    static let logoBacklightEdge = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 152.0 / 255.0, green: 111.0 / 255.0, blue: 244.0 / 255.0, alpha: 0.06)
        } else {
            return UIColor(white: 1, alpha: 0)
        }
    })

    static let logoShadow = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 182.0 / 255.0, green: 146.0 / 255.0, blue: 255.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 109.0 / 255.0, green: 40.0 / 255.0, blue: 217.0 / 255.0, alpha: 1)
        }
    })
}

private enum EmptyChatMetrics {
    static let sectionSpacing: CGFloat = 22
    static let headingSpacing: CGFloat = 6
    static let topOffset: CGFloat = 58
    static let verticalPadding: CGFloat = 36
    static let logoStageSize: CGFloat = 132
    static let logoSize: CGFloat = 72
    static let logoImageVerticalOffset: CGFloat = 1
    static let logoOuterAuraSize: CGFloat = 230
    static let logoOuterAuraStartRadius: CGFloat = 24
    static let logoOuterAuraEndRadius: CGFloat = 124
    static let logoOuterAuraBlur: CGFloat = 38
    static let logoAuraSize: CGFloat = 168
    static let logoAuraStartRadius: CGFloat = 12
    static let logoAuraEndRadius: CGFloat = 92
    static let logoAuraBlur: CGFloat = 28
    static let logoBacklightSize: CGFloat = 104
    static let logoBacklightStartRadius: CGFloat = 5
    static let logoBacklightEndRadius: CGFloat = 56
    static let logoBacklightBlur: CGFloat = 11
    static let logoIdleShadowRadius: CGFloat = 10
    static let logoActiveShadowRadius: CGFloat = 16
    static let logoIdleShadowOffset: CGFloat = 4
    static let logoActiveShadowOffset: CGFloat = 6
    static let logoPulseDuration: TimeInterval = 3.4
    static let headingMaximumWidth: CGFloat = 280
    static let suggestionGroupMaximumWidth: CGFloat = 344
    static let chipSpacing: CGFloat = 7
    static let chipContentSpacing: CGFloat = 6
    static let chipMinimumHeight: CGFloat = 36
    static let chipHorizontalPadding: CGFloat = 12
    static let chipIconSize: CGFloat = 15
    static let chipCornerRadius: CGFloat = 16
    static let chipShadowRadius: CGFloat = 8
    static let chipShadowOffset: CGFloat = 2

    static func logoImageOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.96 : 0.88
    }

    static func logoOuterAuraCoreOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.085 : 0.055
    }

    static func logoOuterAuraEdgeOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.035 : 0.025
    }

    static func logoAuraCoreOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.17 : 0.13
    }

    static func logoAuraEdgeOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.065 : 0.055
    }

    static func logoShadowOpacity(isActive: Bool, colorScheme: ColorScheme) -> Double {
        if colorScheme == .dark {
            return isActive ? 0.20 : 0.13
        }

        return isActive ? 0.12 : 0.07
    }
}

private struct ChatScrollUpdate: Equatable {
    let conversationID: String
    let messageCount: Int
    let messageID: String?
    /// Length rather than the text itself: this is rebuilt on every redraw purely to detect
    /// change, and a streamed reply still grows it by one on each token — copying the whole
    /// body into an Equatable struct per token is pure allocation churn.
    let contentLength: Int
    let deliveryState: String
    let toolState: String

    func isNewMessage(comparedTo previous: ChatScrollUpdate) -> Bool {
        conversationID == previous.conversationID
            && (messageCount != previous.messageCount || messageID != previous.messageID)
    }
}

private enum ChatScrollMetrics {
    static let followThreshold: CGFloat = 80
    static let keyboardFollowUpDelay: DispatchTimeInterval = .milliseconds(250)
}

// Caps the message column so text stays at a readable line length on iPad, where the
// content region is far wider than any phone. Below this width it is inert, so compact
// layouts keep their existing full-bleed behavior.
enum ChatReadableWidth {
    static let maximum: CGFloat = 720
}

private struct ChatBottomAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum ChatTimelineEntry: Identifiable, Equatable {
    case message(ChatMessage)
    case toolCallGroup([ChatMessage])

    var id: String {
        switch self {
        case .message(let message):
            return message.id
        case .toolCallGroup(let messages):
            return messages.first?.id ?? "toolCallGroup"
        }
    }
}

enum ChatTimelineBuilder {
    static func entries(from messages: [ChatMessage]) -> [ChatTimelineEntry] {
        var entries: [ChatTimelineEntry] = []
        var pendingToolCalls: [ChatMessage] = []

        func appendPendingToolCalls() {
            guard !pendingToolCalls.isEmpty else {
                return
            }

            if pendingToolCalls.count == 1, let message = pendingToolCalls.first {
                entries.append(.message(message))
            } else {
                entries.append(.toolCallGroup(pendingToolCalls))
            }
            pendingToolCalls.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if message.role == .tool {
                pendingToolCalls.append(message)
            } else {
                appendPendingToolCalls()
                entries.append(.message(message))
            }
        }

        appendPendingToolCalls()
        return entries
    }
}
