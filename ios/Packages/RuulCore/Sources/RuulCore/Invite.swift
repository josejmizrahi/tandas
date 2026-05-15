import Foundation

public struct Invite: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let invitedBy: UUID
    public let phoneE164: String?
    public let usedAt: Date?
    public let usedByUserId: UUID?
    public let expiresAt: Date
    public let createdAt: Date

    public init(id: UUID, groupId: UUID, invitedBy: UUID, phoneE164: String?, usedAt: Date?, usedByUserId: UUID?, expiresAt: Date, createdAt: Date) {
        self.id = id
        self.groupId = groupId
        self.invitedBy = invitedBy
        self.phoneE164 = phoneE164
        self.usedAt = usedAt
        self.usedByUserId = usedByUserId
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    public enum CodingKeys: String, CodingKey {
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

/// Read-only preview returned by `GET /invite_preview?invite_code=eq.X`.
/// Capability-agnostic post BigBang (mig 00078): only identity + membership.
/// Phase 2 will add a sibling view that joins active ResourceSeries for
/// richer previews (e.g. "weekly dinner — Cena #14 this Thursday").
public struct InvitePreview: Codable, Sendable, Hashable {
    public let groupId: UUID
    public let groupName: String
    public let coverImageName: String?
    public let inviteCode: String
    public let groupCreatedAt: Date
    public let memberCount: Int
    public let recentMemberNames: [String]?

    public init(groupId: UUID, groupName: String, coverImageName: String?, inviteCode: String, groupCreatedAt: Date, memberCount: Int, recentMemberNames: [String]?) {
        self.groupId = groupId
        self.groupName = groupName
        self.coverImageName = coverImageName
        self.inviteCode = inviteCode
        self.groupCreatedAt = groupCreatedAt
        self.memberCount = memberCount
        self.recentMemberNames = recentMemberNames
    }

    public enum CodingKeys: String, CodingKey {
        case groupId            = "group_id"
        case groupName          = "group_name"
        case coverImageName     = "cover_image_name"
        case inviteCode         = "invite_code"
        case groupCreatedAt     = "group_created_at"
        case memberCount        = "member_count"
        case recentMemberNames  = "recent_member_names"
    }
}

public struct PendingInvite: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let phoneE164: String
    public let displayName: String?
    public var sentAt: Date?

    public init(id: UUID = UUID(), phoneE164: String, displayName: String?, sentAt: Date? = nil) {
        self.id = id
        self.phoneE164 = phoneE164
        self.displayName = displayName
        self.sentAt = sentAt
    }
}
