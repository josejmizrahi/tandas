import Foundation
import Supabase

protocol NotificationTokenRepository: Actor {
    func registerToken(_ token: String) async throws
    func revokeToken(_ token: String) async throws
}

actor MockNotificationTokenRepository: NotificationTokenRepository {
    private(set) var tokens: Set<String> = []

    func registerToken(_ token: String) async throws {
        tokens.insert(token)
    }

    func revokeToken(_ token: String) async throws {
        tokens.remove(token)
    }
}

actor LiveNotificationTokenRepository: NotificationTokenRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func registerToken(_ token: String) async throws {
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

    func revokeToken(_ token: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("notification_tokens")
            .delete()
            .eq("user_id", value: userId.uuidString.lowercased())
            .eq("token", value: token)
            .execute()
    }
}
