import Foundation

/// A member row joined with their `profiles` row for display purposes.
/// Used by `MemberRepository.membersWithProfiles(of:)` so views can render
/// avatar + display name without separate fetches.
public struct MemberWithProfile: Identifiable, Sendable, Hashable {
    public let member: Member
    public let profile: Profile?

    public init(member: Member, profile: Profile?) {
        self.member = member
        self.profile = profile
    }

    public var id: UUID { member.id }

    /// Effective name to render — falls back to the member-row override
    /// if the profile is missing (anon sessions, deleted profiles, etc.).
    public var displayName: String {
        if let override = member.displayNameOverride, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        if let p = profile, !p.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return p.displayName
        }
        return "Miembro"
    }

    public var avatarURL: URL? {
        profile?.avatarUrl.flatMap(URL.init(string:))
    }
}
