import Foundation

public struct Member: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let userId: UUID
    public let displayNameOverride: String?
    /// Legacy single-role string ("admin" | "member"). Preserved during the
    /// 2-week paridad window. New code should read `roles` (array).
    public let role: String
    /// Multi-role array. Backfilled by migration 00019: admins get
    /// `[founder, member]`, others `[member]`. V1 active values: founder,
    /// member, host. V2: treasurer, arbiter, observer.
    public let roles: [MemberRole]
    public let active: Bool
    public let joinedAt: Date

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId             = "group_id"
        case userId              = "user_id"
        case displayNameOverride = "display_name_override"
        case role
        case roles
        case active
        case joinedAt            = "joined_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        userId: UUID,
        displayNameOverride: String? = nil,
        role: String = "member",
        roles: [MemberRole] = [.member],
        active: Bool = true,
        joinedAt: Date
    ) {
        self.id = id
        self.groupId = groupId
        self.userId = userId
        self.displayNameOverride = displayNameOverride
        self.role = role
        self.roles = roles
        self.active = active
        self.joinedAt = joinedAt
    }

    /// Tolerant decoder: rows from a not-yet-migrated DB (no `roles` column)
    /// derive `roles` from `role` text so existing code keeps working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                  = try c.decode(UUID.self, forKey: .id)
        self.groupId             = try c.decode(UUID.self, forKey: .groupId)
        self.userId              = try c.decode(UUID.self, forKey: .userId)
        self.displayNameOverride = try c.decodeIfPresent(String.self, forKey: .displayNameOverride)
        self.role                = (try? c.decode(String.self, forKey: .role)) ?? "member"
        if let rolesArray = try? c.decode([MemberRole].self, forKey: .roles), !rolesArray.isEmpty {
            self.roles = rolesArray
        } else {
            // Fallback: derive from legacy role text.
            self.roles = role == "admin" ? [.founder, .member] : [.member]
        }
        self.active   = (try? c.decode(Bool.self, forKey: .active)) ?? true
        self.joinedAt = try c.decode(Date.self, forKey: .joinedAt)
    }

    // MARK: - Convenience

    public var isFounder: Bool { roles.contains(.founder) }
    public var isMember:  Bool { roles.contains(.member)  }
    public var isHost:    Bool { roles.contains(.host)    }
}
