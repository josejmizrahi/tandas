import Foundation

struct Member: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let groupId: UUID
    let userId: UUID
    let displayNameOverride: String?
    let role: String  // "admin" | "member"
    let active: Bool
    let joinedAt: Date
}
