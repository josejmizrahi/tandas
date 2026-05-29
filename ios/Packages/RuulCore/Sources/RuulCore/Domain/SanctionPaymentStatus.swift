import Foundation

// MARK: - Sanction payment status (V2-G4.1)
//
// Hydrated via `group_sanction_payment_status(p_sanction_id)`. Drives
// the PaySanctionSheet pre-fill (amount_outstanding, not the original
// amount) and the SanctionDetailView progress bar + payment history.
// `obligation_status` is `'open'|'partially_settled'|'settled'|'no_obligation'`;
// `sanction_status` mirrors `group_sanctions.status`.

public struct SanctionPaymentEntry: Codable, Sendable, Hashable, Equatable, Identifiable {
    public let settlementId: UUID
    public let amountClosed: Decimal
    public let paidAt: Date?
    public let paidByMembershipId: UUID?
    public let paidByDisplayName: String?

    public var id: UUID { settlementId }

    enum CodingKeys: String, CodingKey {
        case settlementId       = "settlement_id"
        case amountClosed       = "amount_closed"
        case paidAt             = "paid_at"
        case paidByMembershipId = "paid_by_membership_id"
        case paidByDisplayName  = "paid_by_display_name"
    }
}

public struct SanctionPaymentStatus: Codable, Sendable, Hashable, Equatable {
    public let sanctionId: UUID
    public let amountOriginal: Decimal
    public let amountOutstanding: Decimal
    public let amountPaid: Decimal
    public let unit: String?
    public let obligationStatus: String
    public let sanctionStatus: String
    public let payments: [SanctionPaymentEntry]

    enum CodingKeys: String, CodingKey {
        case sanctionId         = "sanction_id"
        case amountOriginal     = "amount_original"
        case amountOutstanding  = "amount_outstanding"
        case amountPaid         = "amount_paid"
        case unit
        case obligationStatus   = "obligation_status"
        case sanctionStatus     = "sanction_status"
        case payments
    }

    public init(
        sanctionId: UUID,
        amountOriginal: Decimal,
        amountOutstanding: Decimal,
        amountPaid: Decimal,
        unit: String? = nil,
        obligationStatus: String,
        sanctionStatus: String,
        payments: [SanctionPaymentEntry] = []
    ) {
        self.sanctionId = sanctionId
        self.amountOriginal = amountOriginal
        self.amountOutstanding = amountOutstanding
        self.amountPaid = amountPaid
        self.unit = unit
        self.obligationStatus = obligationStatus
        self.sanctionStatus = sanctionStatus
        self.payments = payments
    }
}

public extension SanctionPaymentStatus {
    /// 0...1 fraction for a progress bar. 1.0 when the sanction has
    /// been fully paid OR the obligation is closed without any
    /// remaining amount.
    var progress: Double {
        guard amountOriginal > 0 else { return 0 }
        let frac = (amountPaid as NSDecimalNumber).doubleValue
            / (amountOriginal as NSDecimalNumber).doubleValue
        return min(max(frac, 0), 1)
    }

    var isFullyPaid: Bool { amountOutstanding <= 0 }
    var hasPartialPayments: Bool { amountPaid > 0 && amountOutstanding > 0 }
    var hasObligation: Bool { obligationStatus != "no_obligation" }
}
