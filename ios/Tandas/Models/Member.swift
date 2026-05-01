import Foundation

struct Member: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let groupId: UUID
    let userId: UUID
    let displayNameOverride: String?
    let role: String  // "admin" | "member"
    let active: Bool
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupId             = "group_id"
        case userId              = "user_id"
        case displayNameOverride = "display_name_override"
        case role
        case active
        case joinedAt            = "joined_at"
    }
}
