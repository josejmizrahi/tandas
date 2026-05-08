import Foundation
import Supabase

public protocol ProfileRepository: Actor {
    func loadMine() async throws -> Profile
    func updateDisplayName(_ name: String) async throws
}

public actor MockProfileRepository: ProfileRepository {
    private var _profile: Profile

    public init(seed: Profile = Profile(id: UUID(), displayName: "", avatarUrl: nil, phone: nil)) {
        self._profile = seed
    }

    public func loadMine() async throws -> Profile { _profile }

    public func updateDisplayName(_ name: String) async throws {
        _profile.displayName = name
    }
}

public actor LiveProfileRepository: ProfileRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) { self.client = client }

    public func loadMine() async throws -> Profile {
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

    public func updateDisplayName(_ name: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("profiles")
            .update(["display_name": name])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()
    }
}
