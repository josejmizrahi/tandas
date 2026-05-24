import Foundation

/// SharedMoney Phase 4.5 brick A: per-member contribution breakdown
/// for a single source resource. Aggregates `ledger_entries` filtered
/// to `(source_resource_id, type='contribution')` grouped by the
/// contributing `from_member_id`.
///
/// Powers the "Tú: $X (40%) · Socio: $Y (60%)" surface inside the
/// Resource Money Block. The canonical test case (warehouse, per
/// `doctrine_in_kind_contributions.md`) needs this to derive
/// participation %.
///
/// Aggregation policy
/// ==================
/// Only `type='contribution'` rows feed the breakdown. Reimbursements
/// (`type='expense'`, from=NULL → to=member) flow money OUT of the
/// pool to a member; they don't represent member capital injection,
/// so they're excluded. The doctrine pushes capital contributions to
/// be recorded as `contribution` regardless of cash vs in-kind.
///
/// `in_kind` flag (Phase 4.5 brick C) is per-entry metadata; this
/// projection sums total contribution per member without distinguishing
/// cash vs in-kind. A future surface can break those out separately
/// from the same underlying entries.
public struct ResourceMemberContribution: Identifiable, Hashable, Sendable {
    public let memberId: UUID
    public let contributedCents: Int64
    /// How many ledger entries this member has against the resource.
    /// UI can use this for "5 aportes" hints, distinct from amount.
    public let entryCount: Int

    public var id: UUID { memberId }

    public init(
        memberId: UUID,
        contributedCents: Int64,
        entryCount: Int
    ) {
        self.memberId = memberId
        self.contributedCents = contributedCents
        self.entryCount = entryCount
    }
}
