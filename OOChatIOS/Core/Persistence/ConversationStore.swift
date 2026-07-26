import Foundation

final class ConversationStore {
    private let conversationsKey = "connectonion.native-ios.conversations"
    private let activeKey = "connectonion.native-ios.activeConversation"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> ([Conversation], String?) {
        guard let data = UserDefaults.standard.data(forKey: conversationsKey),
              let conversations = try? decoder.decode([Conversation].self, from: data) else {
            return ([Conversation()], nil)
        }
        return (conversations.sorted { $0.updatedAt > $1.updatedAt }, UserDefaults.standard.string(forKey: activeKey))
    }

    func save(_ conversations: [Conversation], activeID: String?) {
        if let data = try? encoder.encode(conversations) {
            UserDefaults.standard.set(data, forKey: conversationsKey)
        }
        UserDefaults.standard.set(activeID, forKey: activeKey)
    }
}
