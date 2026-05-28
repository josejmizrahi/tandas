import Foundation

/// Primitiva 9 (Contribuciones). Mirrors `public.group_contributions`
/// via `group_contributions_active(...)`. Captura aportes
/// no-monetarios como first-class: care, moderation, hosting, docs,
/// labor, time, idea, content, contact, asset, trust.
///
/// Doctrina "registrar ≠ aprobar": cualquier miembro registra su
/// propia contribución en status=`claimed`. Verificación (flip a
/// `verified`) llega en slice posterior.
public enum ContributionType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case money
    case labor
    case time
    case idea
    case care
    case moderation
    case content
    case contact
    case asset
    case hosting
    case docs
    case trust
    case other

    public var id: String { rawValue }

    /// Order shown in pickers + sections. Money first because it's
    /// the most concrete, "other" last as a catch-all.
    public static let displayOrder: [ContributionType] = [
        .care, .moderation, .hosting, .labor, .time, .idea,
        .content, .docs, .contact, .asset, .trust, .money, .other
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .money:      return L10n.Contributions.typeMoney
        case .labor:      return L10n.Contributions.typeLabor
        case .time:       return L10n.Contributions.typeTime
        case .idea:       return L10n.Contributions.typeIdea
        case .care:       return L10n.Contributions.typeCare
        case .moderation: return L10n.Contributions.typeModeration
        case .content:    return L10n.Contributions.typeContent
        case .contact:    return L10n.Contributions.typeContact
        case .asset:      return L10n.Contributions.typeAsset
        case .hosting:    return L10n.Contributions.typeHosting
        case .docs:       return L10n.Contributions.typeDocs
        case .trust:      return L10n.Contributions.typeTrust
        case .other:      return L10n.Contributions.typeOther
        }
    }

    public var systemImageName: String {
        switch self {
        case .money:      return "creditcard"
        case .labor:      return "hammer"
        case .time:       return "clock"
        case .idea:       return "lightbulb"
        case .care:       return "heart"
        case .moderation: return "scale.3d"
        case .content:    return "doc.richtext"
        case .contact:    return "person.crop.circle.badge.plus"
        case .asset:      return "shippingbox"
        case .hosting:    return "house"
        case .docs:       return "doc.text"
        case .trust:      return "hands.sparkles"
        case .other:      return "circle"
        }
    }
}

public enum ContributionStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case claimed
    case verified
    case rejected
    case rewarded

    public var label: LocalizedStringResource {
        switch self {
        case .claimed:  return L10n.Contributions.statusClaimed
        case .verified: return L10n.Contributions.statusVerified
        case .rejected: return L10n.Contributions.statusRejected
        case .rewarded: return L10n.Contributions.statusRewarded
        }
    }
}

public struct GroupContribution: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                              // contribution_id
    public let groupId: UUID
    public let membershipId: UUID
    public let memberDisplayName: String?
    public let type: ContributionType
    public let amount: Decimal?
    public let unit: String?
    public let title: String?
    public let description: String?
    public let sourceResourceId: UUID?
    public let sourceTransactionId: UUID?
    public let status: ContributionStatus
    public let verifiedBy: UUID?
    public let verifiedByDisplayName: String?
    public let occurredAt: Date?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                       = "contribution_id"
        case groupId                  = "group_id"
        case membershipId             = "membership_id"
        case memberDisplayName        = "member_display_name"
        case type                     = "contribution_type"
        case amount
        case unit
        case title
        case description
        case sourceResourceId         = "source_resource_id"
        case sourceTransactionId      = "source_transaction_id"
        case status
        case verifiedBy               = "verified_by"
        case verifiedByDisplayName    = "verified_by_display_name"
        case occurredAt               = "occurred_at"
        case createdAt                = "created_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        membershipId: UUID,
        memberDisplayName: String? = nil,
        type: ContributionType,
        amount: Decimal? = nil,
        unit: String? = nil,
        title: String? = nil,
        description: String? = nil,
        sourceResourceId: UUID? = nil,
        sourceTransactionId: UUID? = nil,
        status: ContributionStatus = .claimed,
        verifiedBy: UUID? = nil,
        verifiedByDisplayName: String? = nil,
        occurredAt: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.membershipId = membershipId
        self.memberDisplayName = memberDisplayName
        self.type = type
        self.amount = amount
        self.unit = unit
        self.title = title
        self.description = description
        self.sourceResourceId = sourceResourceId
        self.sourceTransactionId = sourceTransactionId
        self.status = status
        self.verifiedBy = verifiedBy
        self.verifiedByDisplayName = verifiedByDisplayName
        self.occurredAt = occurredAt
        self.createdAt = createdAt
    }

    /// Tolerant decode: unknown type/status → safe defaults. Amount
    /// accepts numeric or string (PostgREST numeric framing).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.membershipId = try c.decode(UUID.self, forKey: .membershipId)
        self.memberDisplayName = try c.decodeIfPresent(String.self, forKey: .memberDisplayName)
        let rawType = try c.decode(String.self, forKey: .type)
        self.type = ContributionType(rawValue: rawType) ?? .other
        if let asDecimal = try? c.decodeIfPresent(Decimal.self, forKey: .amount) {
            self.amount = asDecimal
        } else if let asString = try c.decodeIfPresent(String.self, forKey: .amount) {
            self.amount = Decimal(string: asString)
        } else {
            self.amount = nil
        }
        self.unit = try c.decodeIfPresent(String.self, forKey: .unit)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.sourceResourceId = try c.decodeIfPresent(UUID.self, forKey: .sourceResourceId)
        self.sourceTransactionId = try c.decodeIfPresent(UUID.self, forKey: .sourceTransactionId)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "claimed"
        self.status = ContributionStatus(rawValue: rawStatus) ?? .claimed
        self.verifiedBy = try c.decodeIfPresent(UUID.self, forKey: .verifiedBy)
        self.verifiedByDisplayName = try c.decodeIfPresent(String.self, forKey: .verifiedByDisplayName)
        self.occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public extension GroupContribution {
    var isVerified: Bool { status == .verified }
    var isQuantified: Bool { amount != nil && unit != nil }

    var when: Date? { occurredAt ?? createdAt }

    /// Headline for list rows: title first, description second,
    /// otherwise the type label.
    var headline: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return desc
        }
        return String(localized: type.label)
    }
}
