import Foundation
import Observation

/// `@MainActor` store for B7 (Notifications). Loads the caller's
/// stored override map and exposes a per-(category, channel)
/// `isEnabled` lookup that defaults to `true` when no override exists.
/// Toggling fires `set_notification_preference(...)` optimistically;
/// failure reverts the local state.
@MainActor
@Observable
public final class NotificationSettingsStore {
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Lookup keyed by `category:channel`. Missing key ⇒ enabled.
    private var overrides: [String: Bool] = [:]

    private let repository: CanonicalNotificationsRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalNotificationsRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public func isEnabled(category: NotificationCategory, channel: NotificationChannel) -> Bool {
        let key = NotificationPreferenceRow.lookupKey(category: category, channel: channel)
        return overrides[key] ?? true
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if overrides.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let rows = try await repository.myPreferences(groupId: groupId)
            var map: [String: Bool] = [:]
            for row in rows {
                map[row.lookupKey] = row.enabled
            }
            overrides = map
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !overrides.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// Optimistic toggle. Updates the local map, fires the backend
    /// upsert, and reverts on failure.
    @discardableResult
    public func setEnabled(
        groupId: UUID,
        category: NotificationCategory,
        channel: NotificationChannel,
        enabled: Bool
    ) async -> Bool {
        let key = NotificationPreferenceRow.lookupKey(category: category, channel: channel)
        let previous = overrides[key]
        overrides[key] = enabled
        do {
            try await repository.setPreference(
                groupId: groupId,
                category: category,
                channel: channel,
                enabled: enabled
            )
            return true
        } catch {
            // Revert.
            if let previous {
                overrides[key] = previous
            } else {
                overrides.removeValue(forKey: key)
            }
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearError() { errorMessage = nil }
}
