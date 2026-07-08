import Foundation

protocol ConversationRepository {
    func load() -> ChatSnapshot
    func save(_ snapshot: ChatSnapshot)
}
