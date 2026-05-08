import Foundation

public struct Profile: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var displayName: String
    public var avatarUrl: String?
    public var phone: String?

    public enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
        case phone
    }

    public init(id: UUID, displayName: String, avatarUrl: String?, phone: String?) {
        self.id = id
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.phone = phone
    }

    public var needsOnboarding: Bool { displayName.trimmingCharacters(in: .whitespaces).isEmpty }
}
