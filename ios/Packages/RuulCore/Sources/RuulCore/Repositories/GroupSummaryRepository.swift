import Foundation
import OSLog

public protocol GroupSummaryRepository: Actor {
    /// Computes a stat snapshot for the group, scoped to the caller's perspective
    /// (e.g., myBalance is the caller's net balance within this group).
    func summary(groupId: UUID, userId: UUID) async throws -> GroupSummary
}

public actor MockGroupSummaryRepository: GroupSummaryRepository {
    public var seed: GroupSummary
    public init(seed: GroupSummary = .empty) { self.seed = seed }
    public func summary(groupId: UUID, userId: UUID) async throws -> GroupSummary { seed }
}

public actor LiveGroupSummaryRepository: GroupSummaryRepository {
    private let groupsRepo: any GroupsRepository
    private let resourceRepo: any ResourceRepository
    private let balanceRepo: any BalanceRepository
    private let fineRepo: any FineRepository
    private let voteRepo: any VoteRepository
    private let userActionRepo: any UserActionRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.summary")

    public init(
        groupsRepo: any GroupsRepository,
        resourceRepo: any ResourceRepository,
        balanceRepo: any BalanceRepository,
        fineRepo: any FineRepository,
        voteRepo: any VoteRepository,
        userActionRepo: any UserActionRepository
    ) {
        self.groupsRepo = groupsRepo
        self.resourceRepo = resourceRepo
        self.balanceRepo = balanceRepo
        self.fineRepo = fineRepo
        self.voteRepo = voteRepo
        self.userActionRepo = userActionRepo
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
}
