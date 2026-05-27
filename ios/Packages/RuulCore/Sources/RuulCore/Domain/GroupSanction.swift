import Foundation

/// Primitiva 11 (Sanciones). Mirrors `public.group_sanctions`. Read
/// rows arrive via `group_sanctions_active(...)` (pre-joined with the
/// target/issuer display names); writes happen via `issue_sanction(...)`.
///
/// Doctrina: "Sanciones > fines". Tipos no monetarios renderizan
/// distinto (warning sin monto, suspension con duración, repair_task
/// con checklist, etc.). The 8-kind catalog matches the backend
/// CHECK constraint exactly so the iOS decoder is total over the
/// canonical row.
public enum SanctionKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case warning
    case monetary
    case suspension
    case lossOfRole       = "loss_of_role"
    case expulsion
    case repairTask       = "repair_task"
    case reputationNote   = "reputation_note"
    case other

    public var id: String { rawValue }

    /// Kinds the Foundation slice lets users *create* via
    /// `IssueSanctionSheet`. Heavier kinds (suspension/loss_of_role/
    /// expulsion) mutate membership state + roles and land in a later
    /// slice with their own confirmation UX.
    public static let foundationIssuable: [SanctionKind] = [
        .warning, .monetary, .repairTask, .reputationNote, .other
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .warning:        return L10n.Sanctions.kindWarning
        case .monetary:       return L10n.Sanctions.kindMonetary
        case .suspension:     return L10n.Sanctions.kindSuspension
        case .lossOfRole:     return L10n.Sanctions.kindLossOfRole
        case .expulsion:      return L10n.Sanctions.kindExpulsion
        case .repairTask:     return L10n.Sanctions.kindRepairTask
        case .reputationNote: return L10n.Sanctions.kindReputationNote
        case .other:          return L10n.Sanctions.kindOther
        }
    }

    public var subtitle: LocalizedStringResource {
        switch self {
        case .warning:        return L10n.Sanctions.kindWarningSubtitle
        case .monetary:       return L10n.Sanctions.kindMonetarySubtitle
        case .suspension:     return L10n.Sanctions.kindSuspensionSubtitle
        case .lossOfRole:     return L10n.Sanctions.kindLossOfRoleSubtitle
        case .expulsion:      return L10n.Sanctions.kindExpulsionSubtitle
        case .repairTask:     return L10n.Sanctions.kindRepairTaskSubtitle
        case .reputationNote: return L10n.Sanctions.kindReputationNoteSubtitle
        case .other:          return L10n.Sanctions.kindOtherSubtitle
        }
    }

    public var systemImageName: String {
        switch self {
        case .warning:        return "exclamationmark.bubble"
        case .monetary:       return "creditcard"
        case .suspension:     return "pause.circle"
        case .lossOfRole:     return "person.badge.minus"
        case .expulsion:      return "person.crop.circle.badge.xmark"
        case .repairTask:     return "wrench.and.screwdriver"
        case .reputationNote: return "bookmark"
        case .other:          return "circle"
        }
    }

    /// True for kinds that require amount+unit on the wire.
    public var requiresAmount: Bool { self == .monetary }
}

public enum SanctionStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case proposed
    case active
    case disputed
    case reversed
    case completed
    case cancelled

    public var isOpen: Bool {
        switch self {
        case .proposed, .active, .disputed: return true
        case .reversed, .completed, .cancelled: return false
        }
    }

    public var label: LocalizedStringResource {
        switch self {
        case .proposed:  return L10n.Sanctions.statusProposed
        case .active:    return L10n.Sanctions.statusActive
        case .disputed:  return L10n.Sanctions.statusDisputed
        case .reversed:  return L10n.Sanctions.statusReversed
        case .completed: return L10n.Sanctions.statusCompleted
        case .cancelled: return L10n.Sanctions.statusCancelled
        }
    }
}

public struct GroupSanction: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                        // sanction_id
    public let groupId: UUID
    public let targetMembershipId: UUID
    public let targetDisplayName: String
    public let issuedByMembershipId: UUID?
    public let issuedByDisplayName: String?
    public let kind: SanctionKind
    public let status: SanctionStatus
    public let amount: Decimal?
    public let unit: String?
    public let reason: String
    public let startsAt: Date?
    public let endsAt: Date?
    public let obligationId: UUID?
    public let disputeId: UUID?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                   = "sanction_id"
        case groupId              = "group_id"
        case targetMembershipId   = "target_membership_id"
        case targetDisplayName    = "target_display_name"
        case issuedByMembershipId = "issued_by_membership_id"
        case issuedByDisplayName  = "issued_by_display_name"
        case kind                 = "sanction_kind"
        case status
        case amount
        case unit
        case reason
        case startsAt             = "starts_at"
        case endsAt               = "ends_at"
        case obligationId         = "obligation_id"
        case disputeId            = "dispute_id"
        case createdAt            = "created_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        targetMembershipId: UUID,
        targetDisplayName: String,
        issuedByMembershipId: UUID? = nil,
        issuedByDisplayName: String? = nil,
        kind: SanctionKind,
        status: SanctionStatus = .active,
        amount: Decimal? = nil,
        unit: String? = nil,
        reason: String,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        obligationId: UUID? = nil,
        disputeId: UUID? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.targetMembershipId = targetMembershipId
        self.targetDisplayName = targetDisplayName
        self.issuedByMembershipId = issuedByMembershipId
        self.issuedByDisplayName = issuedByDisplayName
        self.kind = kind
        self.status = status
        self.amount = amount
        self.unit = unit
        self.reason = reason
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.obligationId = obligationId
        self.disputeId = disputeId
        self.createdAt = createdAt
    }

    /// Tolerant decode: unknown kind/status fall back to safe defaults
    /// so a forward-compatible backend never crashes the client.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.targetMembershipId = try c.decode(UUID.self, forKey: .targetMembershipId)
        self.targetDisplayName = try c.decode(String.self, forKey: .targetDisplayName)
        self.issuedByMembershipId = try c.decodeIfPresent(UUID.self, forKey: .issuedByMembershipId)
        self.issuedByDisplayName = try c.decodeIfPresent(String.self, forKey: .issuedByDisplayName)
        let rawKind = try c.decode(String.self, forKey: .kind)
        self.kind = SanctionKind(rawValue: rawKind) ?? .other
        let rawStatus = try c.decode(String.self, forKey: .status)
        self.status = SanctionStatus(rawValue: rawStatus) ?? .active
        // PostgREST returns `numeric(18,4)` as a JSON string to preserve
        // precision; accept both shapes so the canonical row decodes
        // regardless of how the backend driver framed it.
        if let asDecimal = try? c.decodeIfPresent(Decimal.self, forKey: .amount) {
            self.amount = asDecimal
        } else if let asString = try c.decodeIfPresent(String.self, forKey: .amount) {
            self.amount = Decimal(string: asString)
        } else {
            self.amount = nil
        }
        self.unit = try c.decodeIfPresent(String.self, forKey: .unit)
        self.reason = try c.decode(String.self, forKey: .reason)
        self.startsAt = try c.decodeIfPresent(Date.self, forKey: .startsAt)
        self.endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        self.obligationId = try c.decodeIfPresent(UUID.self, forKey: .obligationId)
        self.disputeId = try c.decodeIfPresent(UUID.self, forKey: .disputeId)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public extension GroupSanction {
    var isMonetary: Bool { kind == .monetary }
    var isDisputed: Bool { status == .disputed }
}
