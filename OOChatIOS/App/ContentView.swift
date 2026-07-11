import SwiftUI
// In charge of organizing three main screens.
struct ContentView: View {
    @StateObject var viewModel: ChatViewModel
    @State private var selectedTab: AppTab = .agents
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.light.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            AgentsView(viewModel: viewModel) {
                selectedTab = .chat
            }
                .tabItem { Label("Agents", systemImage: "network") }
                .tag(AppTab.agents)
            ChatView(viewModel: viewModel)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppTab.chat)
            SettingsView(viewModel: viewModel)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
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
        .preferredColorScheme(AppAppearance(rawValue: appAppearance)?.colorScheme ?? .light)
        .onAppear {
            if AppAppearance(rawValue: appAppearance) == nil {
                appAppearance = AppAppearance.light.rawValue
            }
        }
        .onChange(of: viewModel.pendingInteractionID) {
            guard viewModel.pendingInteractionID != nil else {
                return
            }
            selectedTab = .chat
        }
    }
}

enum AppTab: Hashable {
    case agents
    case chat
    case settings
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: Self { self }

    var label: String {
        switch self {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
