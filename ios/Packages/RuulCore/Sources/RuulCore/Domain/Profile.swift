import Foundation

/// Caller's own profile row, as returned by `my_profile()` /
/// `update_my_profile(...)`. Mirrors `public.profiles` 1:1; iOS never
/// writes to the table directly so this is the only shape the
/// Foundation layer sees.
///
/// `display_name` is intentionally `String?` — it may be null for
/// freshly bootstrapped rows (Apple sign-in without name + first OTP
/// flow). `ProfileStore.requiresProfileCompletion` is the canonical
/// check; UI uses `resolvedDisplayName` for safe fallback rendering.
public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let username: String?
    public let displayName: String?
    public let avatarURL: URL?
    public let bio: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case bio
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID,
        username: String? = nil,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        bio: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decoder tolerates `avatar_url` strings that are not valid URLs
    /// (the canonical RPC accepts free-form text — Storage validation
    /// is out of scope this slice). Anything non-parseable becomes nil
    /// rather than failing the whole decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        if let raw = try c.decodeIfPresent(String.self, forKey: .avatarURL),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.avatarURL = URL(string: raw)
        } else {
            self.avatarURL = nil
        }
        self.bio = try c.decodeIfPresent(String.self, forKey: .bio)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

public extension Profile {
    /// True only when `displayName` exists and contains at least one
    /// non-whitespace character. Drives the onboarding nudge.
    var hasUsableDisplayName: Bool {
        guard let raw = displayName else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Best-effort label for any UI that needs to render *something*.
    /// Falls back through displayName → username → "Miembro" (the
    /// last resort lives here, not in Views, so members/money/invites
    /// never have to repeat the dance).
    var resolvedDisplayName: String {
        if let raw = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        if let user = username?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            return user
        }
        return "Miembro"
    }
}
