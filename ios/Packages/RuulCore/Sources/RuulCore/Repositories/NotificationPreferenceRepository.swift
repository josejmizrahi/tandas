import Foundation
import Supabase

public struct NotificationPreference: Identifiable, Sendable, Hashable, Codable {
    public let userId: UUID
    public let notificationType: String
    public let enabled: Bool
    public let updatedAt: Date

    public var id: String { "\(userId.uuidString)|\(notificationType)" }

    public enum CodingKeys: String, CodingKey {
        case enabled
        case userId           = "user_id"
        case notificationType = "notification_type"
        case updatedAt        = "updated_at"
    }
}

public protocol NotificationPreferenceRepository: Actor {
    func loadMine() async throws -> [NotificationPreference]
    func set(type: String, enabled: Bool) async throws
}

public actor MockNotificationPreferenceRepository: NotificationPreferenceRepository {
    public var prefs: [NotificationPreference]

    public init(seed: [NotificationPreference] = []) {
        self.prefs = seed
    }

    public func loadMine() async throws -> [NotificationPreference] {
        prefs
    }

    public func set(type: String, enabled: Bool) async throws {
        prefs.removeAll(where: { $0.notificationType == type })
        prefs.append(NotificationPreference(
            userId: UUID(),
            notificationType: type,
            enabled: enabled,
            updatedAt: .now
        ))
    }
}

public actor LiveNotificationPreferenceRepository: NotificationPreferenceRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func loadMine() async throws -> [NotificationPreference] {
        let userId = try await client.auth.session.user.id
        return try await client
            .from("notification_preferences")
            .select()
            .eq("user_id", value: userId.uuidString.lowercased())
            .execute()
            .value
    }

    public func set(type: String, enabled: Bool) async throws {
        struct Params: Encodable {
            let p_type: String
            let p_enabled: Bool
        }
        try await client
            .rpc("set_notification_preference", params: Params(p_type: type, p_enabled: enabled))
            .execute()
    }
}
