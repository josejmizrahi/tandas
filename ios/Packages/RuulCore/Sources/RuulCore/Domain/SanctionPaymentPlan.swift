import Foundation

// MARK: - Sanction payment plan (V2-G4.2)
//
// Plan que el sancionado declara para pagar en cuotas. Sin cron
// auto-debit (V3): el plan es guía + tracking. Hydrated via
// `group_sanction_payment_plan_active(p_sanction_id)`. La RPC devuelve
// `{active: false}` cuando no hay plan vivo, o el row completo con
// derivados (`installments_paid`, `next_due_at`).

public struct SanctionPaymentPlan: Codable, Sendable, Hashable, Equatable {
    public let active: Bool

    // Populated when active == true:
    public let planId: UUID?
    public let sanctionId: UUID?
    public let totalAmount: Decimal?
    public let installments: Int?
    public let installmentAmount: Decimal?
    public let unit: String?
    public let firstDueAt: Date?
    public let intervalDays: Int?
    public let notes: String?
    public let createdAt: Date?
    public let amountPaid: Decimal?
    public let amountOutstanding: Decimal?
    public let installmentsPaid: Int?
    public let nextDueAt: Date?

    enum CodingKeys: String, CodingKey {
        case active
        case planId             = "plan_id"
        case sanctionId         = "sanction_id"
        case totalAmount        = "total_amount"
        case installments
        case installmentAmount  = "installment_amount"
        case unit
        case firstDueAt         = "first_due_at"
        case intervalDays       = "interval_days"
        case notes
        case createdAt          = "created_at"
        case amountPaid         = "amount_paid"
        case amountOutstanding  = "amount_outstanding"
        case installmentsPaid   = "installments_paid"
        case nextDueAt          = "next_due_at"
    }

    public init(
        active: Bool,
        planId: UUID? = nil,
        sanctionId: UUID? = nil,
        totalAmount: Decimal? = nil,
        installments: Int? = nil,
        installmentAmount: Decimal? = nil,
        unit: String? = nil,
        firstDueAt: Date? = nil,
        intervalDays: Int? = nil,
        notes: String? = nil,
        createdAt: Date? = nil,
        amountPaid: Decimal? = nil,
        amountOutstanding: Decimal? = nil,
        installmentsPaid: Int? = nil,
        nextDueAt: Date? = nil
    ) {
        self.active = active
        self.planId = planId
        self.sanctionId = sanctionId
        self.totalAmount = totalAmount
        self.installments = installments
        self.installmentAmount = installmentAmount
        self.unit = unit
        self.firstDueAt = firstDueAt
        self.intervalDays = intervalDays
        self.notes = notes
        self.createdAt = createdAt
        self.amountPaid = amountPaid
        self.amountOutstanding = amountOutstanding
        self.installmentsPaid = installmentsPaid
        self.nextDueAt = nextDueAt
    }
}

public extension SanctionPaymentPlan {
    var installmentsRemaining: Int {
        guard let total = installments, let paid = installmentsPaid else { return 0 }
        return max(0, total - paid)
    }

    /// 0...1 fraction of installments completed.
    var progress: Double {
        guard let total = installments, total > 0, let paid = installmentsPaid else { return 0 }
        return min(1, Double(paid) / Double(total))
    }

    /// `true` if `next_due_at` is past and the plan is not completed.
    var isOverdue: Bool {
        guard let due = nextDueAt else { return false }
        return due < Date() && installmentsRemaining > 0
    }
}
