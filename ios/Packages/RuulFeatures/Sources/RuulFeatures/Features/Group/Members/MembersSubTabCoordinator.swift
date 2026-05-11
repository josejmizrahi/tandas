import Foundation
import Observation
import OSLog
import RuulCore

/// Group-scoped roster surface. Combines `group_members.members_with_profiles`
/// rows with the group's ledger entries to surface a per-member balance —
/// the most useful "what's their story" stat the user has access to today.
///
/// V2 will fold in attendance % (from RSVPs), hosting count (from `events.host_id`)
/// and assignments completed. V1 ships the basics: name, role, joined-at,
/// balance.
@Observable @MainActor
public final class MembersSubTabCoordinator {
    public struct MemberRow: Identifiable, Hashable {
        public let member: Member
        public let displayName: String
        public let avatarURL: URL?
        public let netBalanceCents: Int64

        public var id: UUID { member.id }

        public var isFounder: Bool { member.isFounder }

        public var roleLabel: String {
            if member.roles.contains(.founder)   { return "Fundador" }
            if member.roles.contains(.treasurer) { return "Tesorero" }
            if member.roles.contains(.arbiter)   { return "Árbitro" }
            if member.roles.contains(.observer)  { return "Observador" }
            return "Miembro"
        }
    }

    public let group: RuulCore.Group
    public private(set) var rows: [MemberRow] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: String?

    private let ledgerRepo: any LedgerRepository
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.members")

    public init(
        group: RuulCore.Group,
        ledgerRepo: any LedgerRepository,
        groupsRepo: any GroupsRepository
    ) {
        self.group = group
        self.ledgerRepo = ledgerRepo
        self.groupsRepo = groupsRepo
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let membersTask = groupsRepo.membersWithProfiles(of: group.id)
            async let entriesTask = ledgerRepo.list(groupId: group.id, limit: 500)
            let (mwps, entries) = try await (membersTask, entriesTask)
            let balances = Self.balances(from: entries)
            rows = mwps
                .map { mwp in
                    MemberRow(
                        member: mwp.member,
                        displayName: mwp.displayName,
                        avatarURL: mwp.avatarURL,
                        netBalanceCents: balances[mwp.member.id] ?? 0
                    )
                }
                .sorted(by: Self.order)
        } catch {
            log.warning("members refresh failed: \(error.localizedDescription)")
            self.error = "No pudimos cargar la lista de miembros."
        }
    }

    public var activeCount: Int { rows.filter { $0.member.active }.count }

    public var founderCount: Int { rows.filter(\.isFounder).count }

    private static func order(_ lhs: MemberRow, _ rhs: MemberRow) -> Bool {
        if lhs.isFounder != rhs.isFounder { return lhs.isFounder }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    /// Same direction math `GroupMoneyCoordinator` uses — duplicated here
    /// rather than threaded through to keep the Members tab self-contained
    /// (different coordinator lifecycle). Both implementations match the
    /// canonical Taxonomy §2.E semantics.
    private static func balances(from entries: [LedgerEntry]) -> [UUID: Int64] {
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
        return net
    }
}
