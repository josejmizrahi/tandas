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
