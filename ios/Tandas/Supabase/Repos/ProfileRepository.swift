import Foundation
import Supabase

protocol ProfileRepository: Actor {
    func loadMine() async throws -> Profile
    func updateDisplayName(_ name: String) async throws
}

actor MockProfileRepository: ProfileRepository {
    private var _profile: Profile

    init(seed: Profile = Profile(id: UUID(), displayName: "", avatarUrl: nil, phone: nil)) {
        self._profile = seed
    }

    func loadMine() async throws -> Profile { _profile }

    func updateDisplayName(_ name: String) async throws {
        _profile.displayName = name
    }
}

actor LiveProfileRepository: ProfileRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func loadMine() async throws -> Profile {
        let userId = try await client.auth.session.user.id
        let row: Profile = try await client
            .from("profiles")
            .select("id, display_name, avatar_url, phone")
            .eq("id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
        return row
    }

    func updateDisplayName(_ name: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("profiles")
            .update(["display_name": name])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()
    }
}
