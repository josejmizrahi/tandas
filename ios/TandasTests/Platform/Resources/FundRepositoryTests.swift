import Testing
import Foundation
import RuulCore

@Suite("MockFundRepository")
struct FundRepositoryTests {
    private func sampleFund(
        fundId: UUID = UUID(),
        groupId: UUID = UUID(),
        currency: String = "MXN",
        target: Int64? = 500_000
    ) -> Fund {
        Fund(
            fundId: fundId,
            groupId: groupId,
            name: "Viaje 2027",
            targetAmountCents: target,
            currency: currency,
            inCents: 0,
            outCents: 0,
            balanceCents: 0,
            contributionCount: 0,
            expenseCount: 0,
            lastActivityAt: nil,
            lockedAt: nil,
            lockedReason: nil,
            archivedAt: nil,
            createdAt: .now
        )
    }

    @Test("listForGroup filters by group")
    func listFilters() async throws {
        let g1 = UUID()
        let g2 = UUID()
        let repo = MockFundRepository(seed: [
            sampleFund(groupId: g1),
            sampleFund(groupId: g2)
        ])
        let g1Funds = try await repo.listForGroup(g1)
        #expect(g1Funds.count == 1)
        #expect(g1Funds.first?.groupId == g1)
    }

    @Test("contribute increments balance + contribution_count")
    func contributeUpdatesProjection() async throws {
        let fundId = UUID()
        let groupId = UUID()
        let repo = MockFundRepository(seed: [sampleFund(fundId: fundId, groupId: groupId)])

        _ = try await repo.contribute(
            fundId: fundId,
            amountCents: 25_000,
            currency: nil,
            note: "Aporte mensual"
        )
        _ = try await repo.contribute(
            fundId: fundId,
            amountCents: 75_000,
            currency: nil,
            note: nil
        )

        let snapshot = try await repo.get(fundId).first
        #expect(snapshot?.balanceCents == 100_000)
        #expect(snapshot?.contributionCount == 2)
        #expect(snapshot?.expenseCount == 0)
    }

    @Test("recordExpense decrements balance + bumps expense_count")
    func expenseUpdatesProjection() async throws {
        let fundId = UUID()
        let groupId = UUID()
        let recipient = UUID()
        let repo = MockFundRepository(seed: [sampleFund(fundId: fundId, groupId: groupId)])

        _ = try await repo.contribute(fundId: fundId, amountCents: 100_000, currency: nil, note: nil)
        _ = try await repo.recordExpense(
            fundId: fundId,
            amountCents: 30_000,
            toMemberId: recipient,
            currency: nil,
            note: "Bocadillos"
        )

        let snapshot = try await repo.get(fundId).first
        #expect(snapshot?.balanceCents == 70_000)
        #expect(snapshot?.contributionCount == 1)
        #expect(snapshot?.expenseCount == 1)
    }

    @Test("lock + unlock toggle lock state")
    func lockUnlock() async throws {
        let fundId = UUID()
        let repo = MockFundRepository(seed: [sampleFund(fundId: fundId)])

        try await repo.lock(fundId: fundId, reason: "Pausa por viaje")
        let locked = try await repo.get(fundId).first
        #expect(locked?.isLocked == true)
        #expect(locked?.lockedReason == "Pausa por viaje")

        try await repo.unlock(fundId: fundId)
        let unlocked = try await repo.get(fundId).first
        #expect(unlocked?.isLocked == false)
        #expect(unlocked?.lockedReason == nil)
    }

    /// Per Plans/Active/CleanupAudit_2026-05-18/08_tests.md §9.4 fund-lock
    /// idempotency guard. Re-locking an already-locked fund must preserve
    /// the original lockedAt + lockedReason — the server-side `fund_lock`
    /// RPC (mig 00198) short-circuits on already-locked state so no second
    /// `fundLocked` atom is emitted; the mock mirrors that contract.
    @Test("lock twice preserves original lockedAt + reason (idempotent)")
    func lockIsIdempotent() async throws {
        let fundId = UUID()
        let repo = MockFundRepository(seed: [sampleFund(fundId: fundId)])

        try await repo.lock(fundId: fundId, reason: "primera razón")
        let firstLock = try await repo.get(fundId).first
        let firstLockedAt = firstLock?.lockedAt
        #expect(firstLockedAt != nil)
        #expect(firstLock?.lockedReason == "primera razón")

        // Wait so any non-idempotent re-stamp would produce a measurably
        // newer lockedAt; without idempotency this assertion would catch
        // the regression because firstLockedAt < secondLockedAt.
        try await Task.sleep(nanoseconds: 50_000_000)

        try await repo.lock(fundId: fundId, reason: "razón distinta — debe ignorarse")
        let secondLock = try await repo.get(fundId).first
        #expect(secondLock?.lockedAt == firstLockedAt)
        #expect(secondLock?.lockedReason == "primera razón")
    }

    /// Symmetric guard: re-unlocking an already-unlocked fund must be a
    /// no-op (no atom emission, no state churn).
    @Test("unlock on an already-unlocked fund is a no-op")
    func unlockIsIdempotent() async throws {
        let fundId = UUID()
        let repo = MockFundRepository(seed: [sampleFund(fundId: fundId)])

        let baseline = try await repo.get(fundId).first
        #expect(baseline?.isLocked == false)

        // unlock on a never-locked fund must not throw and must leave
        // state identical to the seed.
        try await repo.unlock(fundId: fundId)
        let after = try await repo.get(fundId).first
        #expect(after?.isLocked == false)
        #expect(after?.lockedAt == baseline?.lockedAt)
        #expect(after?.lockedReason == baseline?.lockedReason)
    }

    // MARK: - SharedMoney Phase 3: summaryForGroup

    @Test("summaryForGroup aggregates the group's shared pool snapshot")
    func summaryAggregates() async throws {
        let fundId = UUID()
        let groupId = UUID()
        let recipient = UUID()
        let repo = MockFundRepository(seed: [sampleFund(fundId: fundId, groupId: groupId)])

        _ = try await repo.contribute(fundId: fundId, amountCents: 100_000, currency: nil, note: nil)
        _ = try await repo.recordExpense(
            fundId: fundId, amountCents: 30_000, toMemberId: recipient, currency: nil, note: nil
        )

        let summary = try await repo.summaryForGroup(groupId, preferredCurrency: nil)
        #expect(summary?.sharedPoolId == fundId)
        #expect(summary?.groupId == groupId)
        #expect(summary?.inCents == 100_000)
        #expect(summary?.outCents == 30_000)
        #expect(summary?.balanceCents == 70_000)
        #expect(summary?.entryCount == 2)
        #expect(summary?.hasActivity == true)
        #expect(summary?.isOverSpent == false)
        #expect(summary?.lastActivityAt != nil)
    }

    @Test("summaryForGroup flags an over-spent pool as negative")
    func summaryOverSpent() async throws {
        let fundId = UUID()
        let groupId = UUID()
        let recipient = UUID()
        let repo = MockFundRepository(seed: [sampleFund(fundId: fundId, groupId: groupId)])

        _ = try await repo.contribute(fundId: fundId, amountCents: 10_000, currency: nil, note: nil)
        _ = try await repo.recordExpense(
            fundId: fundId, amountCents: 25_000, toMemberId: recipient, currency: nil, note: nil
        )

        let summary = try await repo.summaryForGroup(groupId, preferredCurrency: nil)
        #expect(summary?.balanceCents == -15_000)
        #expect(summary?.isOverSpent == true)
    }

    @Test("summaryForGroup returns nil for a group with no funds")
    func summaryNilWhenEmpty() async throws {
        let repo = MockFundRepository(seed: [sampleFund(groupId: UUID())])
        let summary = try await repo.summaryForGroup(UUID(), preferredCurrency: nil)
        #expect(summary == nil)
    }

    @Test("summaryForGroup honors preferredCurrency selection")
    func summaryPrefersCurrency() async throws {
        let groupId = UUID()
        let repo = MockFundRepository(seed: [
            sampleFund(groupId: groupId, currency: "MXN"),
            sampleFund(groupId: groupId, currency: "USD")
        ])
        let summary = try await repo.summaryForGroup(groupId, preferredCurrency: "USD")
        #expect(summary?.currency == "USD")
    }

    @Test("progressTowardsTarget computes ratio")
    func targetProgress() {
        let half = Fund(
            fundId: UUID(),
            groupId: UUID(),
            name: "x",
            targetAmountCents: 1_000_00,
            currency: "MXN",
            inCents: 500_00,
            outCents: 0,
            balanceCents: 500_00,
            contributionCount: 0,
            expenseCount: 0,
            lastActivityAt: nil,
            lockedAt: nil,
            lockedReason: nil,
            archivedAt: nil,
            createdAt: .now
        )
        #expect(half.progressTowardsTarget == 0.5)

        let untargeted = Fund(
            fundId: UUID(),
            groupId: UUID(),
            name: "x",
            targetAmountCents: nil,
            currency: "MXN",
            inCents: 1_000,
            outCents: 0,
            balanceCents: 1_000,
            contributionCount: 0,
            expenseCount: 0,
            lastActivityAt: nil,
            lockedAt: nil,
            lockedReason: nil,
            archivedAt: nil,
            createdAt: .now
        )
        #expect(untargeted.progressTowardsTarget == nil)
    }

    // MARK: - SharedMoney Phase 2+4: recordSharedExpense

    @Test("recordSharedExpense stamps split_mode + split_breakdown in metadata")
    func sharedExpenseStampsSplit() async throws {
        let groupId = UUID()
        let payer = UUID()
        let memberA = UUID()
        let memberB = UUID()
        let recipient = UUID()
        let repo = MockFundRepository(seed: [sampleFund(groupId: groupId)])
        _ = try await repo.contribute(fundId: try #require(await repo.listForGroup(groupId).first?.fundId),
                                      amountCents: 100_000, currency: nil, note: nil)

        let entry = try await repo.recordSharedExpense(
            groupId: groupId,
            amountCents: 50_000,
            toMemberId: recipient,
            currency: nil,
            note: "Cena",
            paidByMemberId: payer,
            participants: [memberA, memberB],
            splitMode: .equal,
            splitBreakdown: [
                SplitBreakdown(memberId: memberA, shareCents: 25_000),
                SplitBreakdown(memberId: memberB, shareCents: 25_000),
            ]
        )
        #expect(entry.type == LedgerEntry.Kind.expense)
        #expect(entry.amountCents == 50_000)
        #expect(entry.toMemberId == recipient)
        #expect(entry.splitMode == .equal)
        #expect(entry.splitBreakdown.count == 2)
        #expect(entry.participants == [memberA, memberB])
        #expect(entry.paidByMemberId == payer)
        #expect(entry.note == "Cena")
        #expect(entry.participantCount == 2)
        #expect(entry.isShared == true)
    }

    @Test("recordSharedExpense is idempotent on clientId")
    func sharedExpenseIdempotent() async throws {
        let groupId = UUID()
        let recipient = UUID()
        let cid = UUID()
        let repo = MockFundRepository(seed: [sampleFund(groupId: groupId)])

        let first = try await repo.recordSharedExpense(
            groupId: groupId, amountCents: 30_000, toMemberId: recipient,
            currency: nil, note: nil, clientId: cid
        )
        let second = try await repo.recordSharedExpense(
            groupId: groupId, amountCents: 30_000, toMemberId: recipient,
            currency: nil, note: nil, clientId: cid
        )
        #expect(first.id == second.id)
    }

    @Test("recordSharedExpense throws when group has no shared pool")
    func sharedExpenseNoPool() async throws {
        let repo = MockFundRepository(seed: [])
        await #expect(throws: FundError.notFound) {
            _ = try await repo.recordSharedExpense(
                groupId: UUID(), amountCents: 1_000, toMemberId: UUID(),
                currency: nil, note: nil
            )
        }
    }

    @Test("recordSharedExpense without split stamps only the basic metadata")
    func sharedExpenseNoSplit() async throws {
        let groupId = UUID()
        let recipient = UUID()
        let repo = MockFundRepository(seed: [sampleFund(groupId: groupId)])

        let entry = try await repo.recordSharedExpense(
            groupId: groupId, amountCents: 20_000, toMemberId: recipient,
            currency: nil, note: nil
        )
        #expect(entry.splitMode == nil)
        #expect(entry.splitBreakdown.isEmpty)
        #expect(entry.participants.isEmpty)
        #expect(entry.isShared == false)
        #expect(entry.participantCount == nil)
    }

    // MARK: - SharedMoney Phase 4.5: contributeToSharedMoney (in-kind)

    @Test("contributeToSharedMoney stamps in_kind=true when flagged")
    func contributeInKind() async throws {
        let groupId = UUID()
        let resourceId = UUID()
        let repo = MockFundRepository(seed: [sampleFund(groupId: groupId)])

        let entry = try await repo.contributeToSharedMoney(
            groupId: groupId, amountCents: 5_000_00,
            currency: nil, note: "Terreno aportado",
            sourceResourceId: resourceId,
            inKind: true
        )
        #expect(entry.type == LedgerEntry.Kind.contribution)
        #expect(entry.isInKind == true)
        #expect(entry.sourceResourceId == resourceId)
        #expect(entry.note == "Terreno aportado")
    }

    @Test("contributeToSharedMoney omits in_kind when false")
    func contributeNotInKind() async throws {
        let groupId = UUID()
        let repo = MockFundRepository(seed: [sampleFund(groupId: groupId)])

        let entry = try await repo.contributeToSharedMoney(
            groupId: groupId, amountCents: 10_000,
            currency: nil, note: nil,
            inKind: false
        )
        #expect(entry.isInKind == false)
    }

    // MARK: - SharedMoney Phase 4.5: breakdownForResource

    @Test("breakdownForResource aggregates contributions by from_member")
    func breakdownAggregatesByMember() async throws {
        let groupId = UUID()
        let fundId = UUID()
        let resourceId = UUID()
        let memberA = UUID()
        let memberB = UUID()
        let seedEntries: [LedgerEntry] = [
            LedgerEntry(
                groupId: groupId, resourceId: fundId,
                type: LedgerEntry.Kind.contribution,
                amountCents: 60_000, currency: "MXN",
                fromMemberId: memberA,
                metadata: .object(["source_resource_id": .string(resourceId.uuidString.lowercased())])
            ),
            LedgerEntry(
                groupId: groupId, resourceId: fundId,
                type: LedgerEntry.Kind.contribution,
                amountCents: 40_000, currency: "MXN",
                fromMemberId: memberA,
                metadata: .object(["source_resource_id": .string(resourceId.uuidString.lowercased())])
            ),
            LedgerEntry(
                groupId: groupId, resourceId: fundId,
                type: LedgerEntry.Kind.contribution,
                amountCents: 30_000, currency: "MXN",
                fromMemberId: memberB,
                metadata: .object(["source_resource_id": .string(resourceId.uuidString.lowercased())])
            ),
        ]
        let repo = MockFundRepository(
            seed: [sampleFund(fundId: fundId, groupId: groupId)],
            entries: seedEntries
        )

        let breakdown = try await repo.breakdownForResource(resourceId, preferredCurrency: "MXN")
        #expect(breakdown.count == 2)
        let aRow = try #require(breakdown.first(where: { $0.memberId == memberA }))
        let bRow = try #require(breakdown.first(where: { $0.memberId == memberB }))
        #expect(aRow.contributedCents == 100_000)
        #expect(aRow.entryCount == 2)
        #expect(bRow.contributedCents == 30_000)
        #expect(bRow.entryCount == 1)
    }

    @Test("breakdownForResource excludes expenses (contribution-only)")
    func breakdownExcludesExpenses() async throws {
        let groupId = UUID()
        let fundId = UUID()
        let resourceId = UUID()
        let memberA = UUID()
        let seedEntries: [LedgerEntry] = [
            LedgerEntry(
                groupId: groupId, resourceId: fundId,
                type: LedgerEntry.Kind.expense,
                amountCents: 50_000, currency: "MXN",
                fromMemberId: memberA,  // doesn't matter: expense type filtered out
                metadata: .object(["source_resource_id": .string(resourceId.uuidString.lowercased())])
            ),
        ]
        let repo = MockFundRepository(
            seed: [sampleFund(fundId: fundId, groupId: groupId)],
            entries: seedEntries
        )

        let breakdown = try await repo.breakdownForResource(resourceId, preferredCurrency: "MXN")
        #expect(breakdown.isEmpty)
    }

    @Test("breakdownForResource returns empty when resource has no contributions")
    func breakdownEmpty() async throws {
        let repo = MockFundRepository(seed: [sampleFund(groupId: UUID())])
        let breakdown = try await repo.breakdownForResource(UUID())
        #expect(breakdown.isEmpty)
    }

    // MARK: - SharedMoney Phase 4: summaryForResource

    @Test("summaryForResource folds spent + contributed for a resource")
    func summaryForResourceMath() async throws {
        let groupId = UUID()
        let fundId = UUID()
        let resourceId = UUID()
        let memberA = UUID()
        let seedEntries: [LedgerEntry] = [
            LedgerEntry(
                groupId: groupId, resourceId: fundId,
                type: LedgerEntry.Kind.contribution,
                amountCents: 70_000, currency: "MXN",
                fromMemberId: memberA,
                metadata: .object(["source_resource_id": .string(resourceId.uuidString.lowercased())])
            ),
            LedgerEntry(
                groupId: groupId, resourceId: fundId,
                type: LedgerEntry.Kind.expense,
                amountCents: 20_000, currency: "MXN",
                toMemberId: memberA,
                metadata: .object(["source_resource_id": .string(resourceId.uuidString.lowercased())])
            ),
        ]
        let repo = MockFundRepository(
            seed: [sampleFund(fundId: fundId, groupId: groupId)],
            entries: seedEntries
        )

        let summary = try #require(try await repo.summaryForResource(resourceId, preferredCurrency: "MXN"))
        #expect(summary.contributedCents == 70_000)
        #expect(summary.spentCents == 20_000)
        #expect(summary.netCents == 50_000)
        #expect(summary.entryCount == 2)
    }

    @Test("summaryForResource is nil when the resource has no money entries")
    func summaryForResourceNil() async throws {
        let repo = MockFundRepository(seed: [sampleFund(groupId: UUID())])
        let summary = try await repo.summaryForResource(UUID())
        #expect(summary == nil)
    }
}
