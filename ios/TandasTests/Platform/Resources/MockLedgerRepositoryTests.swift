import Testing
import Foundation
import RuulCore

@Suite("MockLedgerRepository")
struct MockLedgerRepositoryTests {

    // MARK: - Fixtures

    private func makeEntry(
        id: UUID = UUID(),
        groupId: UUID,
        type: String = LedgerEntry.Kind.expense,
        amountCents: Int64 = 50_000,
        fromMemberId: UUID? = nil,
        toMemberId: UUID? = UUID(),
        metadata: JSONConfig = .object([:])
    ) -> LedgerEntry {
        LedgerEntry(
            id: id,
            groupId: groupId,
            type: type,
            amountCents: amountCents,
            fromMemberId: fromMemberId,
            toMemberId: toMemberId,
            metadata: metadata
        )
    }

    // MARK: - listForResource / listForMember

    @Test("listForResource filters by resource_id and sorts desc")
    func listFiltersByResource() async throws {
        let groupId = UUID()
        let r1 = UUID()
        let r2 = UUID()
        let now = Date()
        let e1 = LedgerEntry(
            groupId: groupId, resourceId: r1,
            type: LedgerEntry.Kind.contribution,
            amountCents: 1_000, occurredAt: now.addingTimeInterval(-60)
        )
        let e2 = LedgerEntry(
            groupId: groupId, resourceId: r1,
            type: LedgerEntry.Kind.contribution,
            amountCents: 2_000, occurredAt: now
        )
        let other = LedgerEntry(
            groupId: groupId, resourceId: r2,
            type: LedgerEntry.Kind.contribution,
            amountCents: 9_999, occurredAt: now
        )
        let repo = MockLedgerRepository(seed: [e1, e2, other])

        let rows = try await repo.listForResource(r1, limit: 50)
        #expect(rows.count == 2)
        #expect(rows[0].id == e2.id)
        #expect(rows[1].id == e1.id)
    }

    @Test("listForMember matches either from or to member")
    func listMatchesBothSides() async throws {
        let groupId = UUID()
        let memberA = UUID()
        let other = UUID()
        let asPayer = makeEntry(groupId: groupId, fromMemberId: memberA, toMemberId: other)
        let asRecipient = makeEntry(groupId: groupId, fromMemberId: other, toMemberId: memberA)
        let unrelated = makeEntry(groupId: groupId, fromMemberId: other, toMemberId: other)
        let repo = MockLedgerRepository(seed: [asPayer, asRecipient, unrelated])

        let rows = try await repo.listForMember(memberA, limit: 10)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)) == Set([asPayer.id, asRecipient.id]))
    }

    // MARK: - reverseEntry (mig 00368)

    @Test("reverseEntry appends a flipped settlement-shaped entry")
    func reverseFlipsDirection() async throws {
        let groupId = UUID()
        let memberFrom = UUID()
        let memberTo = UUID()
        let original = makeEntry(
            groupId: groupId,
            type: LedgerEntry.Kind.expense,
            amountCents: 80_000,
            fromMemberId: memberFrom,
            toMemberId: memberTo
        )
        let repo = MockLedgerRepository(seed: [original])

        let reverse = try await repo.reverseEntry(
            entryId: original.id,
            reason: "Mistake",
            clientId: UUID()
        )
        #expect(reverse.type == LedgerEntry.Kind.settlement)
        #expect(reverse.amountCents == original.amountCents)
        #expect(reverse.fromMemberId == memberTo)   // flipped
        #expect(reverse.toMemberId == memberFrom)   // flipped
        #expect(reverse.metadata["reversed_ledger_entry_id"]?.stringValue
                == original.id.uuidString.lowercased())
        #expect(reverse.metadata["reversed_original_type"]?.stringValue
                == LedgerEntry.Kind.expense)
        #expect(reverse.metadata["reason"]?.stringValue == "Mistake")
    }

    @Test("reverseEntry preserves original currency + resource")
    func reversePreservesContext() async throws {
        let groupId = UUID()
        let resourceId = UUID()
        let original = LedgerEntry(
            groupId: groupId, resourceId: resourceId,
            type: LedgerEntry.Kind.expense,
            amountCents: 15_000, currency: "USD",
            fromMemberId: UUID(), toMemberId: UUID()
        )
        let repo = MockLedgerRepository(seed: [original])

        let reverse = try await repo.reverseEntry(
            entryId: original.id, reason: nil, clientId: UUID()
        )
        #expect(reverse.resourceId == resourceId)
        #expect(reverse.currency == "USD")
    }

    @Test("reverseEntry stamps client_id for idempotency")
    func reverseStampsClientId() async throws {
        let groupId = UUID()
        let original = makeEntry(groupId: groupId)
        let repo = MockLedgerRepository(seed: [original])
        let cid = UUID()

        let reverse = try await repo.reverseEntry(
            entryId: original.id, reason: nil, clientId: cid
        )
        #expect(reverse.clientId == cid.uuidString.lowercased())
    }

    @Test("reverseEntry zeroes the group balance for the original from/to pair")
    func reverseCancelsBalance() async throws {
        let groupId = UUID()
        let memberFrom = UUID()
        let memberTo = UUID()
        let original = makeEntry(
            groupId: groupId, amountCents: 50_000,
            fromMemberId: memberFrom, toMemberId: memberTo
        )
        let repo = MockLedgerRepository(seed: [original])

        _ = try await repo.reverseEntry(
            entryId: original.id, reason: nil, clientId: UUID()
        )

        let balances = try await repo.balancesForGroup(groupId)
        for b in balances {
            #expect(b.netCents == 0)
        }
    }

    @Test("reverseEntry throws when the original entry is missing")
    func reverseThrowsOnMissing() async throws {
        let repo = MockLedgerRepository(seed: [])
        await #expect(throws: LedgerError.self) {
            _ = try await repo.reverseEntry(
                entryId: UUID(), reason: nil, clientId: UUID()
            )
        }
    }

    // MARK: - balancesForGroup

    @Test("balancesForGroup nets received - sent per (member, currency)")
    func balancesNetPerMember() async throws {
        let groupId = UUID()
        let memberA = UUID()
        let memberB = UUID()
        let sent = makeEntry(
            groupId: groupId, amountCents: 30_000,
            fromMemberId: memberA, toMemberId: memberB
        )
        let received = makeEntry(
            groupId: groupId, amountCents: 10_000,
            fromMemberId: memberB, toMemberId: memberA
        )
        let repo = MockLedgerRepository(seed: [sent, received])

        let balances = try await repo.balancesForGroup(groupId)
        let a = try #require(balances.first(where: { $0.memberId == memberA }))
        let b = try #require(balances.first(where: { $0.memberId == memberB }))
        // A sent 30, received 10 → net -20
        #expect(a.sentCents == 30_000)
        #expect(a.receivedCents == 10_000)
        #expect(a.netCents == -20_000)
        // B sent 10, received 30 → net +20
        #expect(b.sentCents == 10_000)
        #expect(b.receivedCents == 30_000)
        #expect(b.netCents == 20_000)
    }

    @Test("balancesForGroup ignores entries from other groups")
    func balancesScopedToGroup() async throws {
        let g1 = UUID()
        let g2 = UUID()
        let member = UUID()
        let inG1 = makeEntry(groupId: g1, amountCents: 5_000, toMemberId: member)
        let inG2 = makeEntry(groupId: g2, amountCents: 99_000, toMemberId: member)
        let repo = MockLedgerRepository(seed: [inG1, inG2])

        let g1Balances = try await repo.balancesForGroup(g1)
        let m = try #require(g1Balances.first(where: { $0.memberId == member }))
        #expect(m.receivedCents == 5_000)
    }

    // MARK: - recordSettlement

    @Test("recordSettlement stores a settlement-typed entry")
    func recordSettlementShapes() async throws {
        let groupId = UUID()
        let from = UUID()
        let to = UUID()
        let repo = MockLedgerRepository(seed: [])

        let entry = try await repo.recordSettlement(
            groupId: groupId,
            fromMemberId: from,
            toMemberId: to,
            amountCents: 25_000,
            currency: "MXN",
            resourceId: nil,
            note: "Closing balance"
        )
        #expect(entry.type == LedgerEntry.Kind.settlement)
        #expect(entry.fromMemberId == from)
        #expect(entry.toMemberId == to)
        #expect(entry.note == "Closing balance")
    }
}
