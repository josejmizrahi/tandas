import Foundation

struct Profile: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var displayName: String
    var avatarUrl: String?
    var phone: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
        case phone
    }

    var needsOnboarding: Bool { displayName.trimmingCharacters(in: .whitespaces).isEmpty }
}
