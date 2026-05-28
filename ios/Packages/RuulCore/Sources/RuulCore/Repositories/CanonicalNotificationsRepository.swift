import Foundation

/// Foundation-scope repository for B7 (Notifications). Wraps
/// `my_notification_preferences(...)` and `set_notification_preference(...)`.
/// iOS curates the canonical (category, channel) grid in domain; the
/// backend only stores explicit overrides — anything missing = enabled.
public struct CanonicalNotificationsRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func myPreferences(groupId: UUID) async throws -> [NotificationPreferenceRow] {
        try await rpc.myNotificationPreferences(groupId: groupId)
    }

    public func setPreference(
        groupId: UUID,
        category: NotificationCategory,
        channel: NotificationChannel,
        enabled: Bool
    ) async throws {
        try await rpc.setNotificationPreference(
            SetNotificationPreferenceInput(
                groupId: groupId,
                category: category.rawValue,
                channel: channel.rawValue,
                enabled: enabled
            )
        )
    }
}
