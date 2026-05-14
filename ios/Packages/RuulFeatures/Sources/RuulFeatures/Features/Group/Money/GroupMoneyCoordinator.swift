import Foundation
import Observation
import OSLog
import RuulCore

/// Group-scoped money surface. Loads every `ledger_entries` row in the
/// group plus the member directory, then projects:
///
///   • Per-member balance (positive = group owes them, negative = they owe).
///   • Pairwise IOUs (X owes Y) computed greedily so the UI can render the
///     minimum set of "X → Y $N" rows that would settle the group.
///   • Recent expenses (last 20 expense/contribution rows).
///   • Recent settlements (last 10 settlement rows).
///   • Fund resources (filtered from `public.resources` where type=fund).
///
/// All math runs client-side over the in-memory `entries` array; the only
/// network calls are the three initial loads in `refresh()`. Append-only
/// `record_ledger_entry` writes still flow through the per-event sheet,
/// but the group hero pushes the same wizard for the "+ Gasto" flow.
@Observable @MainActor
public final class GroupMoneyCoordinator {
    public struct MemberBalance: Identifiable, Hashable {
        public let memberId: UUID
        public let displayName: String
        public let avatarURL: URL?
        public let netCents: Int64
        public var id: UUID { memberId }
    }

    /// Greedy "X owes Y" pair. The minimum set that, if all paid, would
    /// settle the group. Derived by iterating creditors (largest first)
    /// and matching against debtors (largest first) until both sides
    /// zero out.
    public struct IOU: Identifiable, Hashable {
        public let id: UUID
        public let fromMemberId: UUID
        public let fromDisplayName: String
        public let fromAvatarURL: URL?
        public let toMemberId: UUID
        public let toDisplayName: String
        public let toAvatarURL: URL?
        public let amountCents: Int64

        public init(
            id: UUID = UUID(),
            fromMemberId: UUID,
            fromDisplayName: String,
            fromAvatarURL: URL?,
            toMemberId: UUID,
            toDisplayName: String,
            toAvatarURL: URL?,
            amountCents: Int64
        ) {
            self.id = id
            self.fromMemberId = fromMemberId
            self.fromDisplayName = fromDisplayName
            self.fromAvatarURL = fromAvatarURL
            self.toMemberId = toMemberId
            self.toDisplayName = toDisplayName
            self.toAvatarURL = toAvatarURL
            self.amountCents = amountCents
        }
    }

    public let group: RuulCore.Group
    public let currentUserId: UUID

    public private(set) var entries: [LedgerEntry] = []
    public private(set) var members: [MemberWithProfile] = []
    public private(set) var funds: [ResourceRow] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: String?

    private let ledgerRepo: any LedgerRepository
    private let groupsRepo: any GroupsRepository
    private let resourceRepo: any ResourceRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.money")

    public init(
        group: RuulCore.Group,
        currentUserId: UUID,
        ledgerRepo: any LedgerRepository,
        groupsRepo: any GroupsRepository,
        resourceRepo: any ResourceRepository
    ) {
        self.group = group
        self.currentUserId = currentUserId
        self.ledgerRepo = ledgerRepo
        self.groupsRepo = groupsRepo
        self.resourceRepo = resourceRepo
    }

    // MARK: - Loading

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let entriesTask = ledgerRepo.list(groupId: group.id, limit: 500)
            async let membersTask = groupsRepo.membersWithProfiles(of: group.id)
            async let fundsTask = resourceRepo.list(
                in: group.id,
                types: [.fund],
                statuses: nil,
                limit: 50
            )
            entries = try await entriesTask
            members = try await membersTask
            funds = (try? await fundsTask) ?? []
        } catch {
            log.warning("refresh failed: \(error.localizedDescription)")
            self.error = "No pudimos cargar la actividad financiera."
        }
    }

    // MARK: - Derived state

    /// Per-member running balance. Positive = the group owes them; negative
    /// = they owe the group. `fine_issued` is skipped — no money has moved
    /// at issuance. Settlements flip direction (from goes up, to goes down)
    /// so they cancel out previous debt.
    public var memberBalances: [MemberBalance] {
        var net: [UUID: Int64] = [:]
        for entry in entries {
            switch entry.type {
            case LedgerEntry.Kind.expense, LedgerEntry.Kind.contribution:
                if let f = entry.fromMemberId { net[f, default: 0] += entry.amountCents }
            case LedgerEntry.Kind.settlement, LedgerEntry.Kind.reimbursement:
                if let f = entry.fromMemberId { net[f, default: 0] += entry.amountCents }
                if let t = entry.toMemberId   { net[t, default: 0] -= entry.amountCents }
            case LedgerEntry.Kind.payout:
                if let t = entry.toMemberId   { net[t, default: 0] -= entry.amountCents }
            default:
                break
            }
        }
        return net.compactMap { (memberId, cents) -> MemberBalance? in
            guard let mwp = members.first(where: { $0.member.id == memberId }) else { return nil }
            return MemberBalance(
                memberId: memberId,
                displayName: mwp.displayName,
                avatarURL: mwp.avatarURL,
                netCents: cents
            )
        }.sorted { abs($0.netCents) > abs($1.netCents) }
    }

    /// Minimum-set IOUs computed greedily from `memberBalances`. Pair the
    /// largest debtor with the largest creditor, deduct the smaller of the
    /// two, repeat. Result count ≤ N-1 where N = members with non-zero
    /// balance. Two members → 1 IOU; three → up to 2; etc.
    public var pairwiseIOUs: [IOU] {
        var debtors:  [(MemberBalance, Int64)] = []  // who owes
        var creditors: [(MemberBalance, Int64)] = [] // who is owed
        for b in memberBalances {
            if b.netCents > 0 { creditors.append((b, b.netCents)) }
            else if b.netCents < 0 { debtors.append((b, -b.netCents)) }
        }
        debtors.sort  { $0.1 > $1.1 }
        creditors.sort { $0.1 > $1.1 }

        var result: [IOU] = []
        var d = 0, c = 0
        while d < debtors.count && c < creditors.count {
            let amount = min(debtors[d].1, creditors[c].1)
            result.append(IOU(
                fromMemberId: debtors[d].0.memberId,
                fromDisplayName: debtors[d].0.displayName,
                fromAvatarURL: debtors[d].0.avatarURL,
                toMemberId: creditors[c].0.memberId,
                toDisplayName: creditors[c].0.displayName,
                toAvatarURL: creditors[c].0.avatarURL,
                amountCents: amount
            ))
            debtors[d].1   -= amount
            creditors[c].1 -= amount
            if debtors[d].1   == 0 { d += 1 }
            if creditors[c].1 == 0 { c += 1 }
        }
        return result
    }

    public var recentExpenses: [LedgerEntry] {
        entries
            .filter { $0.type == LedgerEntry.Kind.expense || $0.type == LedgerEntry.Kind.contribution }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(20)
            .map { $0 }
    }

    public var recentSettlements: [LedgerEntry] {
        entries
            .filter { $0.type == LedgerEntry.Kind.settlement }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(10)
            .map { $0 }
    }

    public var totalSpentCents: Int64 {
        entries.reduce(into: Int64(0)) { acc, entry in
            if entry.type == LedgerEntry.Kind.expense
                || entry.type == LedgerEntry.Kind.contribution {
                acc += entry.amountCents
            }
        }
    }

    public var hasAnyActivity: Bool { !entries.isEmpty }

    // MARK: - Display helpers

    public func displayName(for memberId: UUID?) -> String? {
        guard let id = memberId else { return nil }
        return members.first(where: { $0.member.id == id })?.displayName
    }

    public func avatarURL(for memberId: UUID?) -> URL? {
        guard let id = memberId else { return nil }
        return members.first(where: { $0.member.id == id })?.avatarURL
    }

    /// Resolves the current user's `group_members.id` for this group.
    /// Same pattern as ResourceLedgerCoordinator — used by the quick-action
    /// flows that need a `from_member` (settlement / contribution forms).
    public var currentMemberId: UUID? {
        members.first(where: { $0.member.userId == currentUserId })?.member.id
    }
}
