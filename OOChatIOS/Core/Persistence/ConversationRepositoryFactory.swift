import Foundation

enum ConversationRepositoryFactory {
    static func make(defaults: UserDefaults = .standard) -> ConversationRepository {
        do {
            return try SwiftDataConversationRepository(defaults: defaults)
        } catch {
            fatalError("SwiftData container failed to initialize: \(error)")
        }
    }
}
