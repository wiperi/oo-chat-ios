import SwiftUI
// The entry of app.
@main
struct OOChatIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: ChatViewModel())
        }
    }
}
