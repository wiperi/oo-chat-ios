import SwiftUI
import UIKit

struct ChatShellView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var isSidebarOpen = false
    @State private var dragOffset: CGFloat = 0
    @State private var isPresentingAgents = false
    @State private var isPresentingSettings = false

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = min(proxy.size.width * SidebarShellMetrics.drawerWidthRatio, SidebarShellMetrics.maxDrawerWidth)
            let openOffset = min(drawerWidth, proxy.size.width - SidebarShellMetrics.visibleChatWidth)
            let contentOffset = contentOffset(openOffset: openOffset)
            let progress = sidebarProgress(openOffset: openOffset)
            let cornerRadius = SidebarShellMetrics.cornerRadius * progress

            ZStack(alignment: .leading) {
                ChatSidebarView(
                    viewModel: viewModel,
                    safeAreaInsets: windowSafeAreaInsets,
                    onSelectConversation: { conversation in
                        viewModel.selectConversation(conversation)
                        closeSidebar()
                    },
                    onNewChat: { agent in
                        _ = viewModel.createConversation(for: agent)
                        closeSidebar()
                    },
                    onManageAgents: {
                        isPresentingAgents = true
                    },
                    onSettings: {
                        isPresentingSettings = true
                    }
                )
                .frame(width: drawerWidth)
                .zIndex(0)

                ChatView(viewModel: viewModel) {
                    openSidebar()
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(Color(.systemBackground))
                .disabled(isSidebarOpen)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: cornerRadius,
                        bottomLeadingRadius: cornerRadius,
                        style: .continuous
                    )
                )
                .compositingGroup()
                .shadow(
                    color: .black.opacity(SidebarShellMetrics.shadowOpacity * progress),
                    radius: SidebarShellMetrics.shadowRadius,
                    x: SidebarShellMetrics.shadowOffset.width,
                    y: SidebarShellMetrics.shadowOffset.height
                )
                .offset(x: contentOffset)
                .zIndex(1)

                if progress > 0 {
                    Color.clear
                        .frame(width: proxy.size.width - contentOffset, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .offset(x: contentOffset)
                        .onTapGesture {
                            closeSidebar()
                        }
                        .zIndex(2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color(.systemBackground))
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(sidebarDrag(openOffset: openOffset))
        }
        .ignoresSafeArea()
        .fullScreenCover(isPresented: $isPresentingAgents) {
            AgentsView(viewModel: viewModel) {
                isPresentingAgents = false
                closeSidebar()
            } onClose: {
                isPresentingAgents = false
            }
        }
        .fullScreenCover(isPresented: $isPresentingSettings) {
            SettingsView(viewModel: viewModel) {
                isPresentingSettings = false
            }
        }
    }

    private func openSidebar() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            isSidebarOpen = true
            dragOffset = 0
        }
    }

    private func closeSidebar() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) {
            isSidebarOpen = false
            dragOffset = 0
        }
    }

    private func contentOffset(openOffset: CGFloat) -> CGFloat {
        let baseOffset = isSidebarOpen ? openOffset : CGFloat.zero
        return min(openOffset, max(0, baseOffset + dragOffset))
    }

    private func sidebarProgress(openOffset: CGFloat) -> CGFloat {
        guard openOffset > 0 else {
            return 0
        }
        return contentOffset(openOffset: openOffset) / openOffset
    }

    private func sidebarDrag(openOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: SidebarShellMetrics.dragMinimumDistance, coordinateSpace: .global)
            .onChanged { value in
                if isSidebarOpen {
                    guard value.startLocation.x >= openOffset else {
                        dragOffset = 0
                        return
                    }
                    dragOffset = min(0, value.translation.width)
                } else if value.startLocation.x <= SidebarShellMetrics.openEdgeWidth {
                    dragOffset = max(0, min(openOffset, value.translation.width))
                }
            }
            .onEnded { value in
                let shouldOpen: Bool
                if isSidebarOpen {
                    shouldOpen = value.startLocation.x < openOffset
                        || value.predictedEndTranslation.width > -openOffset * SidebarShellMetrics.closeThreshold
                } else {
                    shouldOpen = value.startLocation.x <= SidebarShellMetrics.openEdgeWidth
                        && value.predictedEndTranslation.width > openOffset * SidebarShellMetrics.openThreshold
                }

                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    isSidebarOpen = shouldOpen
                    dragOffset = 0
                }
            }
    }

    private var windowSafeAreaInsets: EdgeInsets {
        guard
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let window = windowScene.windows.first(where: \.isKeyWindow)
        else {
            return EdgeInsets()
        }

        let insets = window.safeAreaInsets
        return EdgeInsets(
            top: insets.top,
            leading: insets.left,
            bottom: insets.bottom,
            trailing: insets.right
        )
    }
}

// Sidebar metrics and constants.
private enum SidebarShellMetrics {
    static let drawerWidthRatio: CGFloat = 0.76
    static let maxDrawerWidth: CGFloat = 304
    static let visibleChatWidth: CGFloat = 92
    static let cornerRadius: CGFloat = 34
    static let shadowOpacity: Double = 0.08
    static let shadowRadius: CGFloat = 16
    static let shadowOffset = CGSize(width: -2, height: 0)
    static let dragMinimumDistance: CGFloat = 16
    static let openEdgeWidth: CGFloat = 24
    static let closeThreshold: CGFloat = 0.40
    static let openThreshold: CGFloat = 0.33
}
