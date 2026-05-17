import Foundation
import OSLog
import Supabase

public protocol GroupSummaryRepository: Actor {
    /// Computes a stat snapshot for the group, scoped to the caller's perspective
    /// (e.g., myBalance is the caller's net balance within this group).
    func summary(groupId: UUID, userId: UUID) async throws -> GroupSummary

    /// Per-(group, member) stats vía `get_member_summary` RPC (mig 00254).
    /// Caller debe ser miembro del grupo. Si el subject no es ni fue
    /// miembro devuelve MemberSummary.empty con is_member=false.
    func memberSummary(groupId: UUID, userId: UUID) async throws -> MemberSummary
}

public actor MockGroupSummaryRepository: GroupSummaryRepository {
    public var seed: GroupSummary
    public var memberSeed: MemberSummary?
    public init(seed: GroupSummary = .empty, memberSeed: MemberSummary? = nil) {
        self.seed = seed
        self.memberSeed = memberSeed
    }
    public func summary(groupId: UUID, userId: UUID) async throws -> GroupSummary { seed }
    public func memberSummary(groupId: UUID, userId: UUID) async throws -> MemberSummary {
        memberSeed ?? .empty(groupId: groupId, userId: userId)
    }
}

public actor LiveGroupSummaryRepository: GroupSummaryRepository {
    private let groupsRepo: any GroupsRepository
    private let resourceRepo: any ResourceRepository
    private let balanceRepo: any BalanceRepository
    private let fineRepo: any FineRepository
    private let voteRepo: any VoteRepository
    private let userActionRepo: any UserActionRepository
    /// Solo lo necesita memberSummary (RPC directo). El summary() del
    /// grupo se compone desde otros repos sin tocar el client.
    private let client: SupabaseClient?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.summary")

    public init(
        groupsRepo: any GroupsRepository,
        resourceRepo: any ResourceRepository,
        balanceRepo: any BalanceRepository,
        fineRepo: any FineRepository,
        voteRepo: any VoteRepository,
        userActionRepo: any UserActionRepository,
        client: SupabaseClient? = nil
    ) {
        self.groupsRepo = groupsRepo
        self.resourceRepo = resourceRepo
        self.balanceRepo = balanceRepo
        self.fineRepo = fineRepo
        self.voteRepo = voteRepo
        self.userActionRepo = userActionRepo
        self.client = client
    }

    public func summary(groupId: UUID, userId: UUID) async throws -> GroupSummary {
        // Fan-out: 6 independent queries in parallel.
        async let membersTask: [Member] = (try? await groupsRepo.members(of: groupId)) ?? []
        async let eventsTask: [ResourceRow] = (try? await resourceRepo.list(
            in: groupId,
            types: [.event],
            statuses: nil,
            limit: 100
        )) ?? []
        async let balancesTask: [MemberBalance] = (try? await balanceRepo.balancesForGroup(groupId)) ?? []
        async let finesTask: [Fine] = (try? await fineRepo.myFines(userId: userId)) ?? []
        async let votesTask: [Vote] = (try? await voteRepo.openVotes(for: groupId)) ?? []
        async let actionsTask: [UserAction] = (try? await userActionRepo.pending(userId: userId, groupId: groupId)) ?? []

        let members = await membersTask
        let events = await eventsTask
        let balances = await balancesTask
        let myFinesAll = await finesTask
        let votes = await votesTask
        let actions = await actionsTask

        // Resolve user_id → member_id for this group to filter balances.
        let myMemberId = members.first(where: { $0.userId == userId })?.id
        let myBalance = balances.first(where: { $0.memberId == myMemberId })

        // Filter fines to this group only (myFines is cross-group).
        let myGroupFines = myFinesAll.filter { $0.groupId == groupId }
        let pendingFines = myGroupFines.filter { fine in
            fine.status == .officialized && !fine.paid && !fine.waived
        }
        // Fine.amount is Decimal representing MXN units — multiply by 100 for cents.
        let outstanding = pendingFines.reduce(Int64(0)) { sum, fine in
            let units = NSDecimalNumber(decimal: fine.amount).int64Value
            return sum + units * 100
        }

        // Upcoming events = resources with status "open".
        let upcoming = events.filter { $0.status == "open" }.count

        return GroupSummary(
            memberCount: members.count,
            upcomingEventsCount: upcoming,
            myBalanceCents: myBalance?.netCents ?? 0,
            myBalanceCurrency: myBalance?.currency ?? "MXN",
            pendingFinesCount: pendingFines.count,
            pendingFinesOutstandingCents: outstanding,
            openVotesCount: votes.count,
            pendingActionsCount: actions.count
        )
    }

    public func memberSummary(groupId: UUID, userId: UUID) async throws -> MemberSummary {
        guard let client else {
            // Wiring incomplete (tests with the legacy init). Devuelve
            // empty para que la UI no crashee — sigue siendo informativa.
            log.warning("memberSummary called without SupabaseClient injection")
            return .empty(groupId: groupId, userId: userId)
        }
        struct Params: Encodable {
            let p_group_id: String
            let p_user_id: String
        }
        let summary: MemberSummary = try await client
            .rpc("get_member_summary", params: Params(
                p_group_id: groupId.uuidString.lowercased(),
                p_user_id: userId.uuidString.lowercased()
            ))
            .execute()
            .value
        return summary
    }
}
