import Foundation

/// Primitiva 2 (Membership Boundary) projection — one row per
/// person who has a relationship with the group RIGHT NOW. Backed
/// by the canonical `group_membership_boundary(p_group_id)` RPC.
///
/// Distinguishes two kinds in `boundary_kind`:
/// - `.membership` — a real `group_memberships` row (`membership_id`
///   set, `invite_id` nil).
/// - `.invite` — a pending `group_invites` row that hasn't been
///   accepted yet (`invite_id` set, `membership_id` nil). The display
///   name falls back to email/phone when no profile exists yet.
public enum MembershipBoundaryKind: String, Codable, Sendable, Hashable {
    case membership
    case invite
}

public struct MembershipBoundaryItem: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                            // boundary_id
    public let kind: MembershipBoundaryKind
    public let membershipId: UUID?
    public let inviteId: UUID?
    public let userId: UUID?
    public let displayName: String
    public let username: String?
    public let avatarURL: URL?
    public let status: MembershipStatus
    public let membershipType: MembershipType
    public let roleNames: [String]
    public let joinedAt: Date?
    public let invitedAt: Date?
    public let isCurrentUser: Bool

    enum CodingKeys: String, CodingKey {
        case id              = "boundary_id"
        case kind            = "boundary_kind"
        case membershipId    = "membership_id"
        case inviteId        = "invite_id"
        case userId          = "user_id"
        case displayName     = "display_name"
        case username
        case avatarURL       = "avatar_url"
        case status
        case membershipType  = "membership_type"
        case roleNames       = "role_names"
        case joinedAt        = "joined_at"
        case invitedAt       = "invited_at"
        case isCurrentUser   = "is_current_user"
    }

    public init(
        id: UUID,
        kind: MembershipBoundaryKind,
        membershipId: UUID? = nil,
        inviteId: UUID? = nil,
        userId: UUID? = nil,
        displayName: String,
        username: String? = nil,
        avatarURL: URL? = nil,
        status: MembershipStatus = .active,
        membershipType: MembershipType = .member,
        roleNames: [String] = [],
        joinedAt: Date? = nil,
        invitedAt: Date? = nil,
        isCurrentUser: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.membershipId = membershipId
        self.inviteId = inviteId
        self.userId = userId
        self.displayName = displayName
        self.username = username
        self.avatarURL = avatarURL
        self.status = status
        self.membershipType = membershipType
        self.roleNames = roleNames
        self.joinedAt = joinedAt
        self.invitedAt = invitedAt
        self.isCurrentUser = isCurrentUser
    }

    /// Tolerates malformed enum values (defaulting to safe variants)
    /// and unparseable avatar URLs so a forward-compatible backend
    /// row never crashes the client.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        let rawKind = try c.decode(String.self, forKey: .kind)
        self.kind = MembershipBoundaryKind(rawValue: rawKind) ?? .membership
        self.membershipId = try c.decodeIfPresent(UUID.self, forKey: .membershipId)
        self.inviteId = try c.decodeIfPresent(UUID.self, forKey: .inviteId)
        self.userId = try c.decodeIfPresent(UUID.self, forKey: .userId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        if let raw = try c.decodeIfPresent(String.self, forKey: .avatarURL),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.avatarURL = URL(string: raw)
        } else {
            self.avatarURL = nil
        }
        let rawStatus = try c.decode(String.self, forKey: .status)
        self.status = MembershipStatus(rawValue: rawStatus) ?? .active
        let rawType = try c.decode(String.self, forKey: .membershipType)
        self.membershipType = MembershipType(rawValue: rawType) ?? .member
        self.roleNames = (try c.decodeIfPresent([String].self, forKey: .roleNames)) ?? []
        self.joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt)
        self.invitedAt = try c.decodeIfPresent(Date.self, forKey: .invitedAt)
        self.isCurrentUser = (try c.decodeIfPresent(Bool.self, forKey: .isCurrentUser)) ?? false
    }
}

// MARK: - Presentation helpers

public extension MembershipBoundaryItem {
    var isPendingInvite: Bool { kind == .invite }
    var isActiveMembership: Bool { kind == .membership && status == .active }

    /// True only when a Foundation member-detail surface would be
    /// safe to push for this row. Invite rows return false (no
    /// membership yet); membership rows true.
    var canNavigateToMember: Bool {
        kind == .membership && membershipId != nil
    }

    /// Two-letter monogram fallback when no `avatarURL` exists.
    var initials: String {
        let parts = displayName
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "?" }
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        let joined = letters.joined()
        return joined.isEmpty ? "?" : joined.uppercased()
    }

    /// Short row subtitle:
    /// - invite rows: "Invitación pendiente"
    /// - membership w/ roles: first role (+N)
    /// - else nil so the row collapses to a single line
    var subtitle: String? {
        if kind == .invite { return "Invitación pendiente" }
        guard let first = roleNames.first else { return nil }
        if roleNames.count > 1 {
            return "\(first) · +\(roleNames.count - 1)"
        }
        return first
    }

    /// VoiceOver-ready composite label.
    var accessibilityLabelText: String {
        var parts: [String] = [displayName]
        if kind == .invite {
            parts.append("Invitación pendiente")
        } else if !roleNames.isEmpty {
            parts.append(roleNames.joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
    }

    /// Lossy projection so existing `MemberRowView` / `MemberAvatarView`
    /// (designed around `MemberListItem`) can render boundary items
    /// without duplicating the avatar/badge code. Note that invite
    /// rows lose the "Invitación pendiente" subtitle in this
    /// projection — Views that care should consume `subtitle` from
    /// the boundary item directly.
    var asMemberListItem: MemberListItem {
        MemberListItem(
            id: id,
            userId: userId,
            displayName: displayName,
            avatarURL: avatarURL,
            status: status,
            membershipType: membershipType,
            roleNames: roleNames,
            joinedAt: joinedAt,
            isCurrentUser: isCurrentUser
        )
    }
}
