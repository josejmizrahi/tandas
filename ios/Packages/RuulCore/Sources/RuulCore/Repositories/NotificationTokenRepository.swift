import Foundation
import Supabase

public protocol NotificationTokenRepository: Actor {
    func registerToken(_ token: String) async throws
    func revokeToken(_ token: String) async throws
    func listMyDevices() async throws -> [NotificationDevice]
    func revoke(deviceId: UUID) async throws
}

public actor MockNotificationTokenRepository: NotificationTokenRepository {
    public private(set) var tokens: Set<String> = []
    private var seedDevices: [NotificationDevice]

    public init(seedDevices: [NotificationDevice] = []) {
        self.seedDevices = seedDevices
    }

    public func registerToken(_ token: String) async throws {
        tokens.insert(token)
    }

    public func revokeToken(_ token: String) async throws {
        tokens.remove(token)
    }

    public func listMyDevices() async throws -> [NotificationDevice] {
        seedDevices
    }

    public func revoke(deviceId: UUID) async throws {
        seedDevices.removeAll(where: { $0.id == deviceId })
    }
}

public actor LiveNotificationTokenRepository: NotificationTokenRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func registerToken(_ token: String) async throws {
        let userId = try await client.auth.session.user.id
        struct Payload: Encodable {
            let user_id: String
            let token: String
            let platform: String
        }
        try await client
            .from("notification_tokens")
            .upsert(
                Payload(
                    user_id: userId.uuidString.lowercased(),
                    token: token,
                    platform: "ios"
                ),
                onConflict: "user_id,token"
            )
            .execute()
    }

    public func revokeToken(_ token: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("notification_tokens")
            .delete()
            .eq("user_id", value: userId.uuidString.lowercased())
            .eq("token", value: token)
            .execute()
    }

    public func listMyDevices() async throws -> [NotificationDevice] {
        let userId = try await client.auth.session.user.id
        return try await client
            .from("notification_tokens")
            .select()
            .eq("user_id", value: userId.uuidString.lowercased())
            .order("updated_at", ascending: false)
            .execute()
            .value
    }

    public func revoke(deviceId: UUID) async throws {
        try await client
            .from("notification_tokens")
            .delete()
            .eq("id", value: deviceId.uuidString.lowercased())
            .execute()
    }
}
