import SwiftUI

// In charge of organizing the main chat shell.
struct ContentView: View {
    @StateObject var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue

    var body: some View {
        ChatShellView(viewModel: viewModel, startsOnAgents: viewModel.agents.isEmpty)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 1) {
                if viewModel.shouldShowOfflineBanner {
                    OfflineBanner {
                        viewModel.retryConnectivity()
                    } onDismiss: {
                        viewModel.dismissOfflineBanner()
                    }
                    .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
                }
                ErrorBanner(message: viewModel.errorMessage) {
                    viewModel.dismissError()
                }
            }
        }
        .animation(
            AppMotion.contentArrival(reduceMotion: reduceMotion),
            value: viewModel.shouldShowOfflineBanner
        )
        .animation(
            AppMotion.contentArrival(reduceMotion: reduceMotion),
            value: viewModel.errorMessage
        )
        .tint(AppTheme.primary)
        .preferredColorScheme(AppAppearance(rawValue: appAppearance)?.colorScheme)
        .onAppear {
            if AppAppearance(rawValue: appAppearance) == nil {
                appAppearance = AppAppearance.system.rawValue
            }
        }
    }
}
