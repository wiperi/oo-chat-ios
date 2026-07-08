import Foundation

enum ConversationRepositoryFactory {
    static func make(defaults: UserDefaults = .standard) -> ConversationRepository {
        let legacy = ConversationStore(defaults: defaults)
        guard let swiftData = try? SwiftDataConversationRepository(defaults: defaults) else {
            return legacy
        }
        ConversationStoreMigration.migrateIfNeeded(from: legacy, to: swiftData, defaults: defaults)
        return swiftData
    }
}

enum ConversationStoreMigration {
    static let migratedKey = "connectonion.native-ios.swiftdata.migrated"

    static func migrateIfNeeded(
        from legacy: ConversationRepository,
        to swiftData: ConversationRepository,
        defaults: UserDefaults
    ) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defer { defaults.set(true, forKey: migratedKey) }

        guard swiftData.load() == .empty else { return }
        let legacySnapshot = legacy.load()
        guard legacySnapshot != .empty else { return }
        swiftData.save(legacySnapshot)
    }
}
