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

    public enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
        case phone
        case timezone
        case locale
    }

    public init(
        id: UUID,
        displayName: String,
        avatarUrl: String?,
        phone: String?,
        timezone: String = "America/Mexico_City",
        locale: String = "es-MX"
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.phone = phone
        self.timezone = timezone
        self.locale = locale
    }

    public var needsOnboarding: Bool { displayName.trimmingCharacters(in: .whitespaces).isEmpty }
}
