import Foundation

/// A member row joined with their `profiles` row for display purposes.
/// Used by `MemberRepository.membersWithProfiles(of:)` so views can render
/// avatar + display name without separate fetches.
struct MemberWithProfile: Identifiable, Sendable, Hashable {
    let member: Member
    let profile: Profile?

    var id: UUID { member.id }

    /// Effective name to render — falls back to the member-row override
    /// if the profile is missing (anon sessions, deleted profiles, etc.).
    var displayName: String {
        if let override = member.displayNameOverride, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        if let p = profile, !p.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return p.displayName
        }
        return "Miembro"
    }

    var avatarURL: URL? {
        profile?.avatarUrl.flatMap(URL.init(string:))
    }
}
