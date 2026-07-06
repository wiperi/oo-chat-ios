import SwiftUI

@main
struct OOChatIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: ChatViewModel())
        }
    }
}
