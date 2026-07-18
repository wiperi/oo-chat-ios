import Combine

/// Settings consumes a small read/action surface instead of the entire chat feature model.
@MainActor
protocol SettingsFeatureModel: ObservableObject {
    var identity: StoredIdentity? { get }
    var connectionState: ConnectionState { get }
    var activeConversation: Conversation? { get }

    func reconnect() async
}

extension ChatViewModel: SettingsFeatureModel {}
