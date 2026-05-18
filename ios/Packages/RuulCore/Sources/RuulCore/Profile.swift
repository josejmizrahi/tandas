import Foundation

public struct Profile: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var displayName: String
    public var avatarUrl: String?
    public var phone: String?
    /// IANA timezone identifier (e.g., `America/Mexico_City`). Per-user
    /// override; falls back to the group's timezone at the rule-engine
    /// boundary when the caller is group-scoped. Default seeded by mig
    /// 00173 — never null.
    public var timezone: String
    /// BCP-47 locale tag (e.g., `es-MX`). Drives client-side date/number
    /// formatting. Default seeded by mig 00173 — never null.
    public var locale: String
    /// True when this profile is an admin-created stand-in for someone
    /// who has not yet registered (mig 00310). Post-claim the profile row
    /// is deleted; only the merged auth.users row remains, so any value
    /// you read here in production is always for an unclaimed placeholder.
    public var isPlaceholder: Bool
    /// Set only by the decline flow to stamp a placeholder that the real
    /// person reviewed and rejected (mig 00310, 00317). On accept the
    /// profile row is deleted, so claimedAt remains nil for any profile
    /// you can still read.
    public var claimedAt: Date?

    public enum CodingKeys: String, CodingKey {
        case id
        case displayName   = "display_name"
        case avatarUrl     = "avatar_url"
        case phone
        case timezone
        case locale
        case isPlaceholder = "is_placeholder"
        case claimedAt     = "claimed_at"
    }

    public init(
        id: UUID,
        displayName: String,
        avatarUrl: String?,
        phone: String?,
        timezone: String = "America/Mexico_City",
        locale: String = "es-MX",
        isPlaceholder: Bool = false,
        claimedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.phone = phone
        self.timezone = timezone
        self.locale = locale
        self.isPlaceholder = isPlaceholder
        self.claimedAt = claimedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        self.phone = try c.decodeIfPresent(String.self, forKey: .phone)
        self.timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "America/Mexico_City"
        self.locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "es-MX"
        self.isPlaceholder = try c.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
        self.claimedAt = try c.decodeIfPresent(Date.self, forKey: .claimedAt)
    }

    public var needsOnboarding: Bool { displayName.trimmingCharacters(in: .whitespaces).isEmpty }
}
