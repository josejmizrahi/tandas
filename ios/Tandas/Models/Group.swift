import Foundation

struct Group: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let name: String
    let description: String?
    let groupType: GroupType
    let inviteCode: String
    let createdAt: Date
}

struct GroupDetail: Codable, Sendable {
    let group: Group
    let memberCount: Int
    let myRole: String  // "admin" | "member"
}

struct CreateGroupParams: Sendable {
    let name: String
    let description: String?
    let eventLabel: String
    let currency: String
    let groupType: GroupType
    let defaultDayOfWeek: Int?
    let defaultStartTime: String?  // "HH:mm:ss" wire format
    let defaultLocation: String?
}
