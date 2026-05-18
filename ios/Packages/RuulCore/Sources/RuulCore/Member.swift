import Foundation

public struct Member: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let userId: UUID
    public let displayNameOverride: String?
    /// Multi-role array. Backfilled by migration 00019: admins get
    /// `[founder, member]`, others `[member]`. V1 active values: founder,
    /// member, host. V2: treasurer, arbiter, observer.
    ///
    /// Only the V1 cases known to `MemberRole` materialise here.
    /// `rawRoles` carries the FULL jsonb array (including custom roles
    /// declared by templates or via `assign_role`) so Phase 5 UI can
    /// roundtrip arbitrary strings like `seat_owner` / `treasurer_aux`
    /// without losing them on encode.
    public let roles: [MemberRole]
    /// Verbatim string list from `group_members.roles` jsonb. Source of
    /// truth for Phase 5 role-stack rendering; survives custom role ids
    /// the `MemberRole` enum doesn't know about. Always a superset of
    /// the typed `roles` field.
    public let rawRoles: [String]
    public let active: Bool
    public let joinedAt: Date
    /// Timestamp the member transitioned to active=false. Null when active.
    /// Stamped by trigger (mig 00180).
    public let leftAt: Date?
    /// Provenance string. One of `founder_seed`, `invite_code`,
    /// `admin_add`, `unknown`. Stamped by trigger (mig 00180).
    public let joinedVia: String?
    /// Invite code snapshot when `joinedVia == "invite_code"`. The
    /// group's current invite_code may have rotated since.
    public let joinedViaInviteCode: String?

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId             = "group_id"
        case userId              = "user_id"
        case displayNameOverride = "display_name_override"
        case roles
        case active
        case joinedAt            = "joined_at"
        case leftAt              = "left_at"
        case joinedVia           = "joined_via"
        case joinedViaInviteCode = "joined_via_invite_code"
    }

    public init(
        id: UUID,
        groupId: UUID,
        userId: UUID,
        displayNameOverride: String? = nil,
        roles: [MemberRole] = [.member],
        rawRoles: [String]? = nil,
        active: Bool = true,
        joinedAt: Date,
        leftAt: Date? = nil,
        joinedVia: String? = nil,
        joinedViaInviteCode: String? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.userId = userId
        self.displayNameOverride = displayNameOverride
        self.roles = roles
        self.rawRoles = rawRoles ?? roles.map(\.rawValue)
        self.active = active
        self.joinedAt = joinedAt
        self.leftAt = leftAt
        self.joinedVia = joinedVia
        self.joinedViaInviteCode = joinedViaInviteCode
    }

    /// Tolerant decoder. Decodes `roles` as `[String]` first so custom
    /// role ids (`seat_owner`, `treasurer_aux`) roundtrip via `rawRoles`
    /// even when they are not declared in the V1 `MemberRole` enum.
    /// The typed `roles: [MemberRole]` field then projects only the
    /// known cases for legacy call-sites that pattern-match on the enum.
    ///
    /// V24.2 (mig 00303): the legacy `group_members.role` text column was
    /// dropped. Member no longer carries it; rawRoles is the only source.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                  = try c.decode(UUID.self, forKey: .id)
        self.groupId             = try c.decode(UUID.self, forKey: .groupId)
        self.userId              = try c.decode(UUID.self, forKey: .userId)
        self.displayNameOverride = try c.decodeIfPresent(String.self, forKey: .displayNameOverride)

        let decodedRaw = (try? c.decode([String].self, forKey: .roles)) ?? []
        self.rawRoles = decodedRaw.isEmpty ? ["member"] : decodedRaw
        self.roles = self.rawRoles.compactMap(MemberRole.init(rawValue:))

        self.active   = (try? c.decode(Bool.self, forKey: .active)) ?? true
        self.joinedAt = try c.decode(Date.self, forKey: .joinedAt)
        self.leftAt              = try c.decodeIfPresent(Date.self,   forKey: .leftAt)
        self.joinedVia           = try c.decodeIfPresent(String.self, forKey: .joinedVia)
        self.joinedViaInviteCode = try c.decodeIfPresent(String.self, forKey: .joinedViaInviteCode)
    }

    /// Encodes the FULL `rawRoles` array (custom roles included) so
    /// round-tripping a decoded Member through `Encoder` doesn't drop
    /// roles the V1 `MemberRole` enum doesn't know about.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(groupId, forKey: .groupId)
        try c.encode(userId, forKey: .userId)
        try c.encodeIfPresent(displayNameOverride, forKey: .displayNameOverride)
        try c.encode(rawRoles, forKey: .roles)
        try c.encode(active, forKey: .active)
        try c.encode(joinedAt, forKey: .joinedAt)
        try c.encodeIfPresent(leftAt, forKey: .leftAt)
        try c.encodeIfPresent(joinedVia, forKey: .joinedVia)
        try c.encodeIfPresent(joinedViaInviteCode, forKey: .joinedViaInviteCode)
    }

    // MARK: - Convenience

    public var isFounder: Bool { holdsRole("founder") }
    public var isMember:  Bool { holdsRole("member")  }
    public var isHost:    Bool { holdsRole("host")    }

    /// Mig 00262 split admin (capability) from founder (identity);
    /// mig 00290 backfilled 'admin' into every founder's roles[];
    /// mig 00299 made `is_group_admin` (server) read jsonb only;
    /// mig 00303 dropped the role text column entirely.
    public var isAdmin: Bool {
        holdsRole("admin")
    }

    /// Stable membership check that works for both typed `MemberRole`
    /// cases and custom role ids stored in `rawRoles`. Case-sensitive,
    /// matching jsonb semantics.
    public func holdsRole(_ id: String) -> Bool {
        rawRoles.contains(id)
    }
}
