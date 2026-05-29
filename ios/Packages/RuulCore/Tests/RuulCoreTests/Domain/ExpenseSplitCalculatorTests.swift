import Foundation
import Testing
@testable import RuulCore

@Suite("ExpenseSplitCalculator")
struct ExpenseSplitCalculatorTests {

    // MARK: - even

    @Test("even split returns equal shares when amount divides cleanly")
    func evenCleanDivision() {
        let a = UUID()
        let b = UUID()
        let result = ExpenseSplitCalculator.even(amount: 100, participants: [a, b])
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.amount == 50 })
    }

    @Test("even split distributes leftover cents deterministically")
    func evenLeftoverDistribution() {
        // $100 / 3 = $33.33 / $33.33 / $33.34 — 1 cent of leftover goes
        // to the lexicographically lowest membership id.
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let result = ExpenseSplitCalculator.even(amount: 100, participants: [c, b, a])
        // Sum must equal exactly the total to the cent.
        let total = result.reduce(Decimal(0)) { $0 + $1.amount }
        #expect(total == 100)
        // The lexicographically lowest id (a) gets the extra cent.
        let aShare = result.first { $0.membershipId == a }
        #expect(aShare?.amount == Decimal(string: "33.34"))
    }

    @Test("even split preserves caller order in the output")
    func evenPreservesOrder() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let result = ExpenseSplitCalculator.even(amount: 60, participants: [b, a, c])
        #expect(result.map(\.membershipId) == [b, a, c])
    }

    @Test("even split with empty participants returns empty array")
    func evenEmpty() {
        let result = ExpenseSplitCalculator.even(amount: 100, participants: [])
        #expect(result.isEmpty)
    }

    // MARK: - exact

    @Test("exact split accepts sums that match to the cent")
    func exactSumMatches() {
        let a = UUID()
        let b = UUID()
        let result = ExpenseSplitCalculator.exact(
            amount: 100,
            amounts: [(a, 60), (b, 40)]
        )
        guard case .success(let shares) = result else {
            Issue.record("expected success")
            return
        }
        #expect(shares.count == 2)
        let total = shares.reduce(Decimal(0)) { $0 + $1.amount }
        #expect(total == 100)
    }

    @Test("exact split rejects sum mismatch")
    func exactSumMismatch() {
        let a = UUID()
        let b = UUID()
        let result = ExpenseSplitCalculator.exact(
            amount: 100,
            amounts: [(a, 60), (b, 39)]
        )
        if case .failure(.sumMismatch(let expected, let actual)) = result {
            #expect(expected == 100)
            #expect(actual == 99)
        } else {
            Issue.record("expected sumMismatch")
        }
    }

    // MARK: - percentages

    @Test("percentages split distributes leftover cents to highest percent")
    func percentagesLeftover() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        // 33.33 / 33.33 / 33.34 percentages, $100 total → all get $33.33,
        // 1c leftover. Goes to highest percentage = c.
        let result = ExpenseSplitCalculator.percentages(
            amount: 100,
            percentages: [
                (a, Decimal(string: "33.33")!),
                (b, Decimal(string: "33.33")!),
                (c, Decimal(string: "33.34")!)
            ]
        )
        guard case .success(let shares) = result else {
            Issue.record("expected success")
            return
        }
        let total = shares.reduce(Decimal(0)) { $0 + $1.amount }
        #expect(total == 100)
        let cShare = shares.first { $0.membershipId == c }
        // c has the highest percentage so it absorbs the leftover.
        #expect(cShare?.amount == Decimal(string: "33.34"))
    }

    @Test("percentages split rejects when sum != 100")
    func percentagesNot100() {
        let a = UUID()
        let b = UUID()
        let result = ExpenseSplitCalculator.percentages(
            amount: 100,
            percentages: [(a, 50), (b, 30)]
        )
        if case .failure(.percentagesDoNotSumTo100(let actual)) = result {
            #expect(actual == 80)
        } else {
            Issue.record("expected percentagesDoNotSumTo100")
        }
    }

    // MARK: - shares

    @Test("shares split splits proportionally and distributes leftover to top share holder")
    func sharesProportional() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // a:2 b:1 total 3 shares → a:$66.67 b:$33.33 (with leftover going to a, which has the higher share count)
        let result = ExpenseSplitCalculator.shares(
            amount: 100,
            shares: [(a, 2), (b, 1)]
        )
        guard case .success(let s) = result else {
            Issue.record("expected success")
            return
        }
        let total = s.reduce(Decimal(0)) { $0 + $1.amount }
        #expect(total == 100)
        let aShare = s.first { $0.membershipId == a }
        let bShare = s.first { $0.membershipId == b }
        #expect(aShare?.amount == Decimal(string: "66.67"))
        #expect(bShare?.amount == Decimal(string: "33.33"))
    }

    @Test("shares split rejects when all counts are zero")
    func sharesAllZero() {
        let a = UUID()
        let b = UUID()
        let result = ExpenseSplitCalculator.shares(
            amount: 100,
            shares: [(a, 0), (b, 0)]
        )
        if case .failure(.allZeroOrNegative) = result {
            // ok
        } else {
            Issue.record("expected allZeroOrNegative")
        }
    }
}
