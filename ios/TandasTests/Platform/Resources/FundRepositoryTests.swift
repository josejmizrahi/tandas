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
}
