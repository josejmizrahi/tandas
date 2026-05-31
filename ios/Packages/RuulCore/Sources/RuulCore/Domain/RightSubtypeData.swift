import Foundation

/// V3 Resources Deep — Fase B.4. Decodes the `subtype` jsonb returned
/// by `group_resource_detail(...)` when `resource_type='right'`.
/// Mirrors `public.group_resource_rights` 1:1.
public struct RightSubtypeData: Decodable, Sendable, Hashable {
    public let resourceId: UUID
    public let rightKind: String?
    public let holderMembershipId: UUID?
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let expiredAt: Date?
    public let revokedAt: Date?
    public let transferable: Bool?
    public let conditions: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case resourceId          = "resource_id"
        case rightKind           = "right_kind"
        case holderMembershipId  = "holder_membership_id"
        case grantedAt           = "granted_at"
        case expiresAt           = "expires_at"
        case expiredAt           = "expired_at"
        case revokedAt           = "revoked_at"
        case transferable
        case conditions
        case createdAt           = "created_at"
        case updatedAt           = "updated_at"
    }

    public init(
        resourceId: UUID,
        rightKind: String? = nil,
        holderMembershipId: UUID? = nil,
        grantedAt: Date? = nil,
        expiresAt: Date? = nil,
        expiredAt: Date? = nil,
        revokedAt: Date? = nil,
        transferable: Bool? = nil,
        conditions: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.resourceId = resourceId
        self.rightKind = rightKind
        self.holderMembershipId = holderMembershipId
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.expiredAt = expiredAt
        self.revokedAt = revokedAt
        self.transferable = transferable
        self.conditions = conditions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId         = try c.decode(UUID.self, forKey: .resourceId)
        self.rightKind          = try c.decodeIfPresent(String.self, forKey: .rightKind)
        self.holderMembershipId = try c.decodeIfPresent(UUID.self, forKey: .holderMembershipId)
        self.grantedAt          = try c.decodeIfPresent(Date.self, forKey: .grantedAt)
        self.expiresAt          = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.expiredAt          = try c.decodeIfPresent(Date.self, forKey: .expiredAt)
        self.revokedAt          = try c.decodeIfPresent(Date.self, forKey: .revokedAt)
        self.transferable       = try c.decodeIfPresent(Bool.self, forKey: .transferable)
        self.conditions         = try c.decodeIfPresent(String.self, forKey: .conditions)
        self.createdAt          = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt          = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public enum LifecycleState: Sendable, Hashable {
        case unassigned
        case active
        case expired
        case revoked
    }

    public var lifecycleState: LifecycleState {
        if revokedAt != nil { return .revoked }
        if expiredAt != nil { return .expired }
        if holderMembershipId == nil { return .unassigned }
        return .active
    }
}

/// Suggested right kinds whitelist. Backend currently accepts any
/// non-empty text, so the iOS picker narrows to a stable set; users
/// can still grant arbitrary kinds programmatically.
public enum ResourceRightKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case access
    case membership
    case seat
    case benefit
    case other

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .access:     return L10n.Resources.rightKindAccess
        case .membership: return L10n.Resources.rightKindMembership
        case .seat:       return L10n.Resources.rightKindSeat
        case .benefit:    return L10n.Resources.rightKindBenefit
        case .other:      return L10n.Resources.rightKindOther
        }
    }
}
