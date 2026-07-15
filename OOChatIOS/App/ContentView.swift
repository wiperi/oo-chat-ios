import SwiftUI

// In charge of organizing the main chat shell.
struct ContentView: View {
    @StateObject var viewModel: ChatViewModel
    @State private var isShowingAgentsScreen = false
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue

    var body: some View {
        Group {
            if isShowingAgentsScreen || viewModel.agents.isEmpty {
                AgentsView(viewModel: viewModel) {
                    isShowingAgentsScreen = false
                }
            } else {
                ChatShellView(viewModel: viewModel)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 1) {
                if viewModel.shouldShowOfflineBanner {
                    OfflineBanner {
                        viewModel.retryConnectivity()
                    } onDismiss: {
                        viewModel.dismissOfflineBanner()
                    }
                }
                ErrorBanner(message: viewModel.errorMessage) {
                    viewModel.dismissError()
                }
            }
        }
        .tint(AppTheme.primary)
        .preferredColorScheme(AppAppearance(rawValue: appAppearance)?.colorScheme)
        .onAppear {
            if AppAppearance(rawValue: appAppearance) == nil {
                appAppearance = AppAppearance.system.rawValue
            }
            isShowingAgentsScreen = viewModel.agents.isEmpty
        }
        .onChange(of: viewModel.agents.isEmpty) {
            if viewModel.agents.isEmpty {
                isShowingAgentsScreen = true
            }
        }
        .onChange(of: viewModel.pendingInteractionID) {
            guard viewModel.pendingInteractionID != nil else {
                return
            }
            if !viewModel.agents.isEmpty {
                isShowingAgentsScreen = false
            }
        }
    }
}
