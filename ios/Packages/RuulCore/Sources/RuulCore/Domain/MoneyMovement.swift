import Foundation

/// Primitiva 19 (Accounting). One pre-joined row from
/// `group_resource_transactions` as returned by the canonical
/// `group_money_movements(...)` RPC. Each row is an append-only money
/// atom — `transaction_type` distinguishes the flow shape.
///
/// `seq` is the monotonic backend cursor for pagination; the timeline
/// is rendered newest-first. Display names for from/to/paid_by are
/// resolved server-side so the iOS surface never re-joins.
public enum MoneyMovementType: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case income
    case expense
    case transfer
    case contribution
    case refund
    case adjustment
    case allocation
    case payout
    case reversal
    case settlementPayment   = "settlement_payment"
    case finePayment         = "fine_payment"
    case poolCharge          = "pool_charge"
    case bookingCharge       = "booking_charge"
    case other

    public var id: String { rawValue }

    /// Subset of canonical types the A2.b filter chip row surfaces.
    /// Mirrors the plan: gastos · settlements · multas · contribuciones ·
    /// pool charges. Other types (refund/adjustment/allocation/...) show
    /// up under the "Todos" filter but don't get their own chip.
    public static let foundationFilters: [MoneyMovementType] = [
        .expense, .settlementPayment, .finePayment, .contribution, .poolCharge
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .income:            return L10n.MoneyMovements.typeIncome
        case .expense:           return L10n.MoneyMovements.typeExpense
        case .transfer:          return L10n.MoneyMovements.typeTransfer
        case .contribution:      return L10n.MoneyMovements.typeContribution
        case .refund:            return L10n.MoneyMovements.typeRefund
        case .adjustment:        return L10n.MoneyMovements.typeAdjustment
        case .allocation:        return L10n.MoneyMovements.typeAllocation
        case .payout:            return L10n.MoneyMovements.typePayout
        case .reversal:          return L10n.MoneyMovements.typeReversal
        case .settlementPayment: return L10n.MoneyMovements.typeSettlement
        case .finePayment:       return L10n.MoneyMovements.typeFinePayment
        case .poolCharge:        return L10n.MoneyMovements.typePoolCharge
        case .bookingCharge:     return L10n.MoneyMovements.typeBookingCharge
        case .other:             return L10n.MoneyMovements.typeOther
        }
    }

    public var systemImageName: String {
        switch self {
        case .income:            return "arrow.down.circle"
        case .expense:           return "cart"
        case .transfer:          return "arrow.left.arrow.right"
        case .contribution:      return "hands.sparkles"
        case .refund:            return "arrow.uturn.left.circle"
        case .adjustment:        return "slider.horizontal.3"
        case .allocation:        return "square.split.2x2"
        case .payout:            return "banknote"
        case .reversal:          return "arrow.uturn.backward"
        case .settlementPayment: return "checkmark.circle"
        case .finePayment:       return "exclamationmark.bubble"
        case .poolCharge:        return "tray.and.arrow.down"
        case .bookingCharge:     return "calendar.badge.plus"
        case .other:             return "circle"
        }
    }
}

public struct MoneyMovement: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                              // transaction_id
    public let seq: Int64
    public let groupId: UUID
    public let type: MoneyMovementType
    public let amount: Decimal
    public let unit: String
    public let fromMembershipId: UUID?
    public let fromDisplayName: String?
    public let toMembershipId: UUID?
    public let toDisplayName: String?
    public let paidByMembershipId: UUID?
    public let paidByDisplayName: String?
    public let recordedByUserId: UUID?
    public let recordedByDisplayName: String?
    public let sourceEntityKind: String?
    public let sourceEntityId: UUID?
    public let sourceResourceId: UUID?
    public let resourceId: UUID?
    public let reversedEntryId: UUID?
    public let inKind: Bool
    public let splitMode: String?
    /// Pre-joined per-participant breakdown of an expense split. Each
    /// entry carries `membershipId`, the participant's `displayName`
    /// (resolved server-side, may be nil if the row is stale), and the
    /// `amount` they were assigned. `amount` is nil for legacy pre-S1
    /// rows where `split_mode='even'` was stored without per-share
    /// amounts. Decoded straight from the V3-S3 `split_breakdown jsonb`
    /// column on `group_money_movements`.
    public let splitBreakdown: [SplitShareDisplay]?
    public let description: String?

    public struct SplitShareDisplay: Sendable, Equatable, Hashable, Codable {
        public let membershipId: UUID
        public let displayName: String?
        public let amount: Decimal?

        public init(membershipId: UUID, displayName: String?, amount: Decimal?) {
            self.membershipId = membershipId
            self.displayName = displayName
            self.amount = amount
        }

        enum CodingKeys: String, CodingKey {
            case membershipId = "membership_id"
            case displayName  = "display_name"
            case amount
        }

        // Tolerant decode: `amount` may arrive as numeric or as a string
        // (PostgREST sometimes frames numeric as text). displayName may
        // be present with an empty string in some legacy paths — treat
        // empty as nil.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.membershipId = try c.decode(UUID.self, forKey: .membershipId)
            let rawName = try c.decodeIfPresent(String.self, forKey: .displayName)
            self.displayName = (rawName?.isEmpty == true) ? nil : rawName
            if let asDecimal = try? c.decodeIfPresent(Decimal.self, forKey: .amount) {
                self.amount = asDecimal
            } else if let asString = try c.decodeIfPresent(String.self, forKey: .amount),
                      let parsed = Decimal(string: asString) {
                self.amount = parsed
            } else {
                self.amount = nil
            }
        }
    }
    public let occurredAt: Date?
    public let createdAt: Date?
    /// V2-G5 — mandate this movement was recorded under, when the
    /// actor was acting on someone's behalf. nil = self-acting.
    public let mandateId: UUID?

    enum CodingKeys: String, CodingKey {
        case id                       = "transaction_id"
        case seq
        case groupId                  = "group_id"
        case type                     = "transaction_type"
        case amount
        case unit
        case fromMembershipId         = "from_membership_id"
        case fromDisplayName          = "from_display_name"
        case toMembershipId           = "to_membership_id"
        case toDisplayName            = "to_display_name"
        case paidByMembershipId       = "paid_by_membership_id"
        case paidByDisplayName        = "paid_by_display_name"
        case recordedByUserId         = "recorded_by_user_id"
        case recordedByDisplayName    = "recorded_by_display_name"
        case sourceEntityKind         = "source_entity_kind"
        case sourceEntityId           = "source_entity_id"
        case sourceResourceId         = "source_resource_id"
        case resourceId               = "resource_id"
        case reversedEntryId          = "reversed_entry_id"
        case inKind                   = "in_kind"
        case splitMode                = "split_mode"
        case splitBreakdown           = "split_breakdown"
        case description
        case occurredAt               = "occurred_at"
        case createdAt                = "created_at"
        case mandateId                = "mandate_id"
    }

    public init(
        id: UUID,
        seq: Int64,
        groupId: UUID,
        type: MoneyMovementType,
        amount: Decimal,
        unit: String,
        fromMembershipId: UUID? = nil,
        fromDisplayName: String? = nil,
        toMembershipId: UUID? = nil,
        toDisplayName: String? = nil,
        paidByMembershipId: UUID? = nil,
        paidByDisplayName: String? = nil,
        recordedByUserId: UUID? = nil,
        recordedByDisplayName: String? = nil,
        sourceEntityKind: String? = nil,
        sourceEntityId: UUID? = nil,
        sourceResourceId: UUID? = nil,
        resourceId: UUID? = nil,
        reversedEntryId: UUID? = nil,
        inKind: Bool = false,
        splitMode: String? = nil,
        splitBreakdown: [SplitShareDisplay]? = nil,
        description: String? = nil,
        occurredAt: Date? = nil,
        createdAt: Date? = nil,
        mandateId: UUID? = nil
    ) {
        self.id = id
        self.seq = seq
        self.groupId = groupId
        self.type = type
        self.amount = amount
        self.unit = unit
        self.fromMembershipId = fromMembershipId
        self.fromDisplayName = fromDisplayName
        self.toMembershipId = toMembershipId
        self.toDisplayName = toDisplayName
        self.paidByMembershipId = paidByMembershipId
        self.paidByDisplayName = paidByDisplayName
        self.recordedByUserId = recordedByUserId
        self.recordedByDisplayName = recordedByDisplayName
        self.sourceEntityKind = sourceEntityKind
        self.sourceEntityId = sourceEntityId
        self.sourceResourceId = sourceResourceId
        self.resourceId = resourceId
        self.reversedEntryId = reversedEntryId
        self.inKind = inKind
        self.splitMode = splitMode
        self.splitBreakdown = splitBreakdown
        self.description = description
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.mandateId = mandateId
    }

    /// Tolerant decode: unknown `transaction_type` strings drop into
    /// `.other` so a backend that later adds a new flow doesn't crash
    /// the client. Amount accepts either numeric or string (PostgREST
    /// frames `numeric(18,4)` as a JSON string).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.seq = try c.decode(Int64.self, forKey: .seq)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        let rawType = try c.decode(String.self, forKey: .type)
        self.type = MoneyMovementType(rawValue: rawType) ?? .other
        if let asDecimal = try? c.decodeIfPresent(Decimal.self, forKey: .amount) {
            self.amount = asDecimal
        } else if let asString = try c.decodeIfPresent(String.self, forKey: .amount),
                  let parsed = Decimal(string: asString) {
            self.amount = parsed
        } else {
            self.amount = 0
        }
        self.unit = try c.decode(String.self, forKey: .unit)
        self.fromMembershipId = try c.decodeIfPresent(UUID.self, forKey: .fromMembershipId)
        self.fromDisplayName = try c.decodeIfPresent(String.self, forKey: .fromDisplayName)
        self.toMembershipId = try c.decodeIfPresent(UUID.self, forKey: .toMembershipId)
        self.toDisplayName = try c.decodeIfPresent(String.self, forKey: .toDisplayName)
        self.paidByMembershipId = try c.decodeIfPresent(UUID.self, forKey: .paidByMembershipId)
        self.paidByDisplayName = try c.decodeIfPresent(String.self, forKey: .paidByDisplayName)
        self.recordedByUserId = try c.decodeIfPresent(UUID.self, forKey: .recordedByUserId)
        self.recordedByDisplayName = try c.decodeIfPresent(String.self, forKey: .recordedByDisplayName)
        self.sourceEntityKind = try c.decodeIfPresent(String.self, forKey: .sourceEntityKind)
        self.sourceEntityId = try c.decodeIfPresent(UUID.self, forKey: .sourceEntityId)
        self.sourceResourceId = try c.decodeIfPresent(UUID.self, forKey: .sourceResourceId)
        self.resourceId = try c.decodeIfPresent(UUID.self, forKey: .resourceId)
        self.reversedEntryId = try c.decodeIfPresent(UUID.self, forKey: .reversedEntryId)
        self.inKind = (try c.decodeIfPresent(Bool.self, forKey: .inKind)) ?? false
        self.splitMode = try c.decodeIfPresent(String.self, forKey: .splitMode)
        self.splitBreakdown = try c.decodeIfPresent([SplitShareDisplay].self, forKey: .splitBreakdown)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.mandateId = try c.decodeIfPresent(UUID.self, forKey: .mandateId)
    }
}

public extension MoneyMovement {
    /// Best human-facing timestamp: the wall-clock `occurred_at` falls
    /// back to `created_at` for older rows.
    var when: Date? { occurredAt ?? createdAt }

    /// True for entries that reverse a previous one (UI shows them with
    /// a strikethrough hint).
    var isReversal: Bool { reversedEntryId != nil || type == .reversal }

    /// One-line headline for a row: the counterparty when present,
    /// description otherwise, type-label as last resort.
    var headline: String {
        if let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty {
            return desc
        }
        if let to = toDisplayName, !to.isEmpty {
            return to
        }
        if let from = fromDisplayName, !from.isEmpty {
            return from
        }
        return String(localized: type.label)
    }

    /// Compact counterparty subtitle ("De Ana → A Mateo" / "Al grupo").
    var counterpartyLabel: String? {
        switch type {
        case .settlementPayment, .finePayment, .poolCharge, .bookingCharge:
            if let to = toDisplayName { return "→ \(to)" }
            return nil
        case .expense, .income, .transfer, .refund, .allocation, .payout, .contribution, .adjustment, .reversal, .other:
            if let from = fromDisplayName, let to = toDisplayName {
                return "\(from) → \(to)"
            }
            if let from = fromDisplayName { return from }
            if let to = toDisplayName { return "→ \(to)" }
            return nil
        }
    }
}
