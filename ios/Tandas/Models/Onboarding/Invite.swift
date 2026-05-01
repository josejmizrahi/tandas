import Foundation

struct Invite: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let groupId: UUID
    let invitedBy: UUID
    let phoneE164: String?
    let usedAt: Date?
    let usedByUserId: UUID?
    let expiresAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupId       = "group_id"
        case invitedBy     = "invited_by"
        case phoneE164     = "phone_e164"
        case usedAt        = "used_at"
        case usedByUserId  = "used_by_user_id"
        case expiresAt     = "expires_at"
        case createdAt     = "created_at"
    }
}

/// Read-only preview returned by GET /invite_preview?invite_code=eq.X.
/// No sensitive fields, suitable for anon access.
struct InvitePreview: Codable, Sendable, Hashable {
    let groupId: UUID
    let groupName: String
    let coverImageName: String?
    let eventLabel: String
    let frequencyType: String?
    let inviteCode: String
    let groupCreatedAt: Date
    let memberCount: Int
    let recentMemberNames: [String]?

    enum CodingKeys: String, CodingKey {
        case groupId            = "group_id"
        case groupName          = "group_name"
        case coverImageName     = "cover_image_name"
        case eventLabel         = "event_label"
        case frequencyType      = "frequency_type"
        case inviteCode         = "invite_code"
        case groupCreatedAt     = "group_created_at"
        case memberCount        = "member_count"
        case recentMemberNames  = "recent_member_names"
    }
}

struct PendingInvite: Identifiable, Sendable, Hashable {
    let id: UUID
    let phoneE164: String
    let displayName: String?       // from contact picker, optional
    var sentAt: Date?

    init(id: UUID = UUID(), phoneE164: String, displayName: String?, sentAt: Date? = nil) {
        self.id = id
        self.phoneE164 = phoneE164
        self.displayName = displayName
        self.sentAt = sentAt
    }
}
