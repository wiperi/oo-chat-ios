import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.light.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Theme", selection: $appAppearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Identity") {
                    Text(viewModel.identity?.address ?? "Creating...")
                        .font(.system(.footnote, design: .monospaced))
                    Text(viewModel.identity?.publicKeyHex ?? "")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section("Session") {
                    LabeledContent("Connection", value: viewModel.connectionState.rawValue)
                    LabeledContent("Session ID", value: viewModel.activeConversation?.id ?? "None")
                    Button("Reconnect") {
                        Task {
                            await viewModel.reconnect()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
