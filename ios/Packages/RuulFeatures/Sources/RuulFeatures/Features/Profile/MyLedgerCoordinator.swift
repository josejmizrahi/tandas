import Foundation
import Observation
import OSLog
import RuulCore

/// Cross-group personal ledger surface. Loads every `ledger_entries` row
/// where the current user is the `from_member` or `to_member` across all
/// groups they belong to, then projects per-group + global aggregates.
///
/// The repository's `listForMember` query is keyed on `group_members.id`
/// (the join row), not `auth.users.id`. Each group the user is part of
/// has a distinct member row, so we resolve them once on refresh by
/// walking `app.groups` and fetching `membersWithProfiles` per group —
/// the cached directory pattern used everywhere else in the app.
@Observable @MainActor
public final class MyLedgerCoordinator {
    public struct GroupLedger: Identifiable, Hashable {
        public let group: RuulCore.Group
        public let myMemberId: UUID
        public let entries: [LedgerEntry]
        public let paidCents: Int64
        public let receivedCents: Int64

        public var id: UUID { group.id }
        public var netCents: Int64 { receivedCents - paidCents }
    }

    public let userId: UUID
    public let allGroups: [RuulCore.Group]

    public private(set) var ledgers: [GroupLedger] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: String?

    private let ledgerRepo: any LedgerRepository
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "my.ledger")

    public init(
        userId: UUID,
        allGroups: [RuulCore.Group],
        ledgerRepo: any LedgerRepository,
        groupsRepo: any GroupsRepository
    ) {
        self.userId = userId
        self.allGroups = allGroups
        self.ledgerRepo = ledgerRepo
        self.groupsRepo = groupsRepo
    }

    // MARK: - Loading

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        var collected: [GroupLedger] = []
        for group in allGroups {
            do {
                let members = try await groupsRepo.membersWithProfiles(of: group.id)
                guard let myMember = members.first(where: { $0.member.userId == userId }) else {
                    continue
                }
                let entries = try await ledgerRepo.listForMember(myMember.member.id, limit: 500)
                let (paid, received) = Self.totals(for: entries, myMemberId: myMember.member.id)
                collected.append(GroupLedger(
                    group: group,
                    myMemberId: myMember.member.id,
                    entries: entries,
                    paidCents: paid,
                    receivedCents: received
                ))
            } catch {
                log.warning("ledger refresh failed for \(group.id): \(error.localizedDescription)")
            }
        }
        // Most active group first.
        ledgers = collected.sorted { ($0.paidCents + $0.receivedCents) > ($1.paidCents + $1.receivedCents) }
    }

    /// Sums money that left vs reached the given member, expressed in
    /// cents. Classification follows the canonical kinds:
    ///
    ///   - **Paid** (money out): every entry where `fromMemberId == me`.
    ///     Covers `expense`, `contribution`, `settlement` (I → other),
    ///     `fine_paid`, `reimbursement` (I → other).
    ///   - **Received** (money in): every entry where `toMemberId == me`.
    ///     Covers `settlement` (other → me), `payout`, `reimbursement`
    ///     (other → me).
    ///
    /// `fine_issued` doesn't move money so it's excluded explicitly.
    private static func totals(
        for entries: [LedgerEntry],
        myMemberId: UUID
    ) -> (paid: Int64, received: Int64) {
        var paid: Int64 = 0
        var received: Int64 = 0
        for entry in entries {
            if entry.type == LedgerEntry.Kind.fineIssued { continue }
            if entry.fromMemberId == myMemberId { paid += entry.amountCents }
            if entry.toMemberId == myMemberId { received += entry.amountCents }
        }
        return (paid, received)
    }

    // MARK: - Aggregates

    public var totalPaidCents: Int64 {
        ledgers.reduce(into: Int64(0)) { $0 += $1.paidCents }
    }

    public var totalReceivedCents: Int64 {
        ledgers.reduce(into: Int64(0)) { $0 += $1.receivedCents }
    }

    public var netCents: Int64 { totalReceivedCents - totalPaidCents }

    public var hasAnyActivity: Bool {
        totalPaidCents > 0 || totalReceivedCents > 0
    }

    /// Flat, newest-first stream across all groups for the "recent" list.
    public var allEntriesNewestFirst: [LedgerEntry] {
        ledgers.flatMap(\.entries).sorted { $0.occurredAt > $1.occurredAt }
    }

    public func group(for entry: LedgerEntry) -> RuulCore.Group? {
        ledgers.first(where: { $0.group.id == entry.groupId })?.group
    }

    /// Stable classification an entry's polarity for the current user.
    /// Returned as `(amountCents, sign)` so the row view can color the
    /// number without re-running the from/to checks.
    public func direction(of entry: LedgerEntry) -> Direction {
        guard let myId = ledgers.first(where: { $0.group.id == entry.groupId })?.myMemberId else {
            return .neutral
        }
        if entry.fromMemberId == myId && entry.toMemberId == myId { return .neutral }
        if entry.fromMemberId == myId { return .out }
        if entry.toMemberId == myId { return .in_ }
        return .neutral
    }

    public enum Direction { case `in_`, out, neutral }
}
