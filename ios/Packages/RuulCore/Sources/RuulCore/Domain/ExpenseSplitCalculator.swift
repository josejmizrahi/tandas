import Foundation

/// Pure helpers that turn a UX-level split intention into a wire-ready
/// breakdown of `ExpenseSplit.Share`. All amounts are 2-decimal
/// currency values; leftover cents are distributed deterministically so
/// the same inputs always produce the same output and the sum always
/// matches the total to the cent.
public enum ExpenseSplitCalculator {

    /// UX modes the sheet offers. Calculator turns each one into a
    /// concrete breakdown via the matching factory below.
    public enum Method: String, Sendable, CaseIterable, Identifiable {
        case even
        case exact
        case percentage
        case shares

        public var id: String { rawValue }
    }

    // MARK: - Equal split

    /// Divides `amount` evenly across `participants`. Each share is
    /// rounded down to 2 decimals; leftover cents (the rounding tail)
    /// are distributed one-cent-at-a-time to the first N participants
    /// in the canonical order (sorted by membership id), so the result
    /// is stable across calls.
    ///
    /// Returns shares in the original `participants` order so the UI
    /// preview matches the selection order the user made.
    public static func even(
        amount: Decimal,
        participants: [UUID]
    ) -> [ExpenseSplit.Share] {
        guard !participants.isEmpty else { return [] }
        let cents = decimalToCents(amount)
        let n = participants.count
        let base = cents / n
        let leftover = cents - base * n
        // Deterministic tail: cents assigned to the lexicographically
        // lowest membership ids first.
        let tailRecipients = Set(
            participants
                .sorted { $0.uuidString < $1.uuidString }
                .prefix(leftover)
        )
        return participants.map { id in
            let assigned = base + (tailRecipients.contains(id) ? 1 : 0)
            return ExpenseSplit.Share(membershipId: id, amount: centsToDecimal(assigned))
        }
    }

    // MARK: - Exact (caller types the per-person amount)

    public enum ExactValidationError: Error, Equatable, Sendable {
        case sumMismatch(expected: Decimal, actual: Decimal)
        case emptyParticipants
    }

    /// Wraps an already-typed-per-person amounts dictionary. Validates
    /// the sum matches `amount` to the cent before returning.
    public static func exact(
        amount: Decimal,
        amounts: [(membershipId: UUID, amount: Decimal)]
    ) -> Result<[ExpenseSplit.Share], ExactValidationError> {
        guard !amounts.isEmpty else { return .failure(.emptyParticipants) }
        let totalCents = amounts.reduce(0) { $0 + decimalToCents($1.amount) }
        let expected = decimalToCents(amount)
        guard totalCents == expected else {
            return .failure(.sumMismatch(
                expected: amount,
                actual: centsToDecimal(totalCents)
            ))
        }
        let shares = amounts.map {
            ExpenseSplit.Share(membershipId: $0.membershipId, amount: $0.amount)
        }
        return .success(shares)
    }

    // MARK: - Percentages (must sum to 100)

    public enum PercentageValidationError: Error, Equatable, Sendable {
        case percentagesDoNotSumTo100(actual: Decimal)
        case emptyParticipants
    }

    /// Percentages are integers or decimals representing percent points;
    /// they must sum to 100 (within a $0.005 epsilon to absorb decimal
    /// typing). Each resulting cent amount is the percentage × cents
    /// rounded down; leftover cents go to the highest-percentage
    /// participants in order (tie-break by uuid sort).
    public static func percentages(
        amount: Decimal,
        percentages: [(membershipId: UUID, percent: Decimal)]
    ) -> Result<[ExpenseSplit.Share], PercentageValidationError> {
        guard !percentages.isEmpty else { return .failure(.emptyParticipants) }
        let total = percentages.reduce(Decimal(0)) { $0 + $1.percent }
        if abs(total - 100) > Decimal(0.0001) {
            return .failure(.percentagesDoNotSumTo100(actual: total))
        }
        let totalCents = decimalToCents(amount)
        // Floor each share, accumulate leftover.
        var floorAssignments: [(id: UUID, percent: Decimal, cents: Int)] =
            percentages.map { row in
                let rawCents = NSDecimalNumber(decimal: row.percent * Decimal(totalCents) / 100)
                let floored = Int(truncating: rawCents.rounding(accordingToBehavior: floorBehavior))
                return (row.membershipId, row.percent, floored)
            }
        let assignedSum = floorAssignments.reduce(0) { $0 + $1.cents }
        var leftover = totalCents - assignedSum
        // Distribute leftover cents one by one to the highest percentages,
        // tie-break by uuid sort (stable & deterministic).
        if leftover > 0 {
            let order = floorAssignments
                .enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.percent != rhs.element.percent {
                        return lhs.element.percent > rhs.element.percent
                    }
                    return lhs.element.id.uuidString < rhs.element.id.uuidString
                }
                .map(\.offset)
            for index in order {
                guard leftover > 0 else { break }
                floorAssignments[index].cents += 1
                leftover -= 1
            }
        }
        let shares = floorAssignments.map {
            ExpenseSplit.Share(membershipId: $0.id, amount: centsToDecimal($0.cents))
        }
        return .success(shares)
    }

    // MARK: - Shares (caller types a small integer per person)

    public enum SharesValidationError: Error, Equatable, Sendable {
        case allZeroOrNegative
        case emptyParticipants
    }

    /// "Pedro pays 2 shares, María 1, Ana 1" — the calculator turns
    /// integer share counts into percentages and reuses the percentage
    /// branch so leftover cents land deterministically on the highest
    /// share count.
    public static func shares(
        amount: Decimal,
        shares: [(membershipId: UUID, shareCount: Int)]
    ) -> Result<[ExpenseSplit.Share], SharesValidationError> {
        guard !shares.isEmpty else { return .failure(.emptyParticipants) }
        let total = shares.reduce(0) { $0 + max(0, $1.shareCount) }
        guard total > 0 else { return .failure(.allZeroOrNegative) }
        let totalCents = decimalToCents(amount)
        var assignments: [(id: UUID, raw: Int, cents: Int)] = shares.map { row in
            let raw = max(0, row.shareCount)
            // Floor cents for this share via integer math.
            let cents = (raw * totalCents) / total
            return (row.membershipId, raw, cents)
        }
        let assignedSum = assignments.reduce(0) { $0 + $1.cents }
        var leftover = totalCents - assignedSum
        if leftover > 0 {
            let order = assignments
                .enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.raw != rhs.element.raw {
                        return lhs.element.raw > rhs.element.raw
                    }
                    return lhs.element.id.uuidString < rhs.element.id.uuidString
                }
                .map(\.offset)
            for index in order {
                guard leftover > 0 else { break }
                assignments[index].cents += 1
                leftover -= 1
            }
        }
        let result = assignments.map {
            ExpenseSplit.Share(membershipId: $0.id, amount: centsToDecimal($0.cents))
        }
        return .success(result)
    }

    // MARK: - Cents helpers (private)

    private static let centScale = 2

    /// Rounds half-up to 2 decimals before flattening to cents — handles
    /// typed amounts like "10.005" reasonably (= 1001 cents). Splitwise
    /// also rounds typed input to 2 decimals on submit.
    private static func decimalToCents(_ value: Decimal) -> Int {
        var raw = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 0, .plain)
        return Int(truncating: rounded as NSNumber)
    }

    private static func centsToDecimal(_ cents: Int) -> Decimal {
        Decimal(cents) / 100
    }

    private static let floorBehavior: NSDecimalNumberHandler = {
        NSDecimalNumberHandler(
            roundingMode: .down,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
    }()
}
