import Foundation

/// Primitiva 23 (Representación). Mirrors `public.group_mandates` via
/// `group_mandates_active(...)`. A mandate is a revocable, scoped
/// delegation — distinct from a role: a role is a persistent
/// position; a mandate is "you speak for the group about X until Y".
///
/// Foundation slice ships read-active + grant + revoke. Per-mandate
/// fulfilment + audit history are deferred.
public enum MandatePrincipalType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case group
    case committee
    case role
    case membership

    public var id: String { rawValue }

    public var label: LocalizedStringResource {
        switch self {
        case .group:      return L10n.Mandates.principalGroup
        case .committee:  return L10n.Mandates.principalCommittee
        case .role:       return L10n.Mandates.principalRole
        case .membership: return L10n.Mandates.principalMembership
        }
    }
}

public enum MandateType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case speak
    case sign
    case vote
    case negotiate
    case spend
    case represent
    case delegate
    case other

    public var id: String { rawValue }

    public static let displayOrder: [MandateType] = [
        .represent, .speak, .sign, .vote, .negotiate, .spend, .delegate, .other
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .speak:     return L10n.Mandates.typeSpeak
        case .sign:      return L10n.Mandates.typeSign
        case .vote:      return L10n.Mandates.typeVote
        case .negotiate: return L10n.Mandates.typeNegotiate
        case .spend:     return L10n.Mandates.typeSpend
        case .represent: return L10n.Mandates.typeRepresent
        case .delegate:  return L10n.Mandates.typeDelegate
        case .other:     return L10n.Mandates.typeOther
        }
    }

    public var systemImageName: String {
        switch self {
        case .speak:     return "bubble.left.and.bubble.right"
        case .sign:      return "signature"
        case .vote:      return "checkmark.seal"
        case .negotiate: return "person.line.dotted.person"
        case .spend:     return "creditcard"
        case .represent: return "person.crop.rectangle.badge.checkmark"
        case .delegate:  return "arrow.right.circle"
        case .other:     return "circle"
        }
    }
}

public enum MandateStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case active
    case expired
    case revoked
    case fulfilled

    public var label: LocalizedStringResource {
        switch self {
        case .active:    return L10n.Mandates.statusActive
        case .expired:   return L10n.Mandates.statusExpired
        case .revoked:   return L10n.Mandates.statusRevoked
        case .fulfilled: return L10n.Mandates.statusFulfilled
        }
    }

    public var isActive: Bool { self == .active }
}

public struct GroupMandate: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                                  // mandate_id
    public let groupId: UUID
    public let principalType: MandatePrincipalType
    public let principalId: UUID?
    public let representativeMembershipId: UUID
    public let representativeDisplayName: String?
    public let type: MandateType
    public let status: MandateStatus
    public let startsAt: Date?
    public let endsAt: Date?
    public let sourceDecisionId: UUID?
    public let grantedBy: UUID?
    public let grantedByDisplayName: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                          = "mandate_id"
        case groupId                     = "group_id"
        case principalType               = "principal_type"
        case principalId                 = "principal_id"
        case representativeMembershipId  = "representative_membership_id"
        case representativeDisplayName   = "representative_display_name"
        case type                        = "mandate_type"
        case status
        case startsAt                    = "starts_at"
        case endsAt                      = "ends_at"
        case sourceDecisionId            = "source_decision_id"
        case grantedBy                   = "granted_by"
        case grantedByDisplayName        = "granted_by_display_name"
        case createdAt                   = "created_at"
        case updatedAt                   = "updated_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        principalType: MandatePrincipalType,
        principalId: UUID? = nil,
        representativeMembershipId: UUID,
        representativeDisplayName: String? = nil,
        type: MandateType,
        status: MandateStatus = .active,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        sourceDecisionId: UUID? = nil,
        grantedBy: UUID? = nil,
        grantedByDisplayName: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.principalType = principalType
        self.principalId = principalId
        self.representativeMembershipId = representativeMembershipId
        self.representativeDisplayName = representativeDisplayName
        self.type = type
        self.status = status
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.sourceDecisionId = sourceDecisionId
        self.grantedBy = grantedBy
        self.grantedByDisplayName = grantedByDisplayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decode: unknown enums fall back to safe defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        let rawPrincipal = try c.decodeIfPresent(String.self, forKey: .principalType) ?? "group"
        self.principalType = MandatePrincipalType(rawValue: rawPrincipal) ?? .group
        self.principalId = try c.decodeIfPresent(UUID.self, forKey: .principalId)
        self.representativeMembershipId = try c.decode(UUID.self, forKey: .representativeMembershipId)
        self.representativeDisplayName = try c.decodeIfPresent(String.self, forKey: .representativeDisplayName)
        let rawType = try c.decode(String.self, forKey: .type)
        self.type = MandateType(rawValue: rawType) ?? .other
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        self.status = MandateStatus(rawValue: rawStatus) ?? .active
        self.startsAt = try c.decodeIfPresent(Date.self, forKey: .startsAt)
        self.endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        self.sourceDecisionId = try c.decodeIfPresent(UUID.self, forKey: .sourceDecisionId)
        self.grantedBy = try c.decodeIfPresent(UUID.self, forKey: .grantedBy)
        self.grantedByDisplayName = try c.decodeIfPresent(String.self, forKey: .grantedByDisplayName)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

public extension GroupMandate {
    /// `true` when the mandate has no end date (open-ended).
    var isOpenEnded: Bool { endsAt == nil }
}
