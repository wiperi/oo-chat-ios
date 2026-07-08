import Foundation

/// Persistence boundary for chat state. Callers depend on this protocol, not on a
/// concrete store, so the backing engine (currently `UserDefaults` + JSON) can be
/// swapped without touching the view-model, and tests can inject an in-memory double.
protocol ConversationRepository {
    /// Returns the persisted snapshot, migrating any legacy format on the way out.
    func load() -> ChatSnapshot

    /// Persists the full snapshot.
    func save(_ snapshot: ChatSnapshot)
}
