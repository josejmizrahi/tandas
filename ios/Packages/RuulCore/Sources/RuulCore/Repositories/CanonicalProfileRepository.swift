import Foundation

/// Foundation-scope repository for the caller's own profile. Wraps the
/// two canonical RPCs (`my_profile`, `update_my_profile`) so feature
/// view models stay decoupled from `RuulRPCClient` — and Views never
/// see Supabase at all (doctrine: iOS no escribe tablas directo).
public struct CanonicalProfileRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// `my_profile() returns public.profiles`. Backend creates a blank
    /// row on first call so this never throws "not found".
    public func myProfile() async throws -> Profile {
        try await rpc.myProfile()
    }

    /// `update_my_profile(...)` — trims caller input before sending so
    /// the wire payload is already canonical. Backend re-trims +
    /// lowercases username defensively.
    public func updateMyProfile(
        displayName: String,
        username: String? = nil,
        avatarURL: String? = nil,
        bio: String? = nil
    ) async throws -> Profile {
        let input = UpdateMyProfileInput(
            pDisplayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            pUsername: username?.nilIfBlankTrimmed,
            pAvatarUrl: avatarURL?.nilIfBlankTrimmed,
            pBio: bio?.nilIfBlankTrimmed
        )
        return try await rpc.updateMyProfile(input)
    }
}

private extension String {
    /// Trims whitespace + newlines. Returns nil if the result is empty,
    /// so optional repository params don't pass empty strings to the RPC.
    var nilIfBlankTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
