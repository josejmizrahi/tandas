import Foundation

/// Splitwise-style expense split modes (mig 00370). Determines how the
/// total amount is divided among `participants`. The canonical
/// breakdown lives in `metadata.split_breakdown` regardless of mode —
/// the mode is informational so callers can pre-fill the editor.
public enum SplitMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Total divided evenly among participants.
    case equal
    /// Each participant gets an exact dollar amount; sum must equal total.
    case exact
    /// Each participant gets a percentage; percentages must sum to 100.
    case percent
    /// Each participant has a "share" count (1, 2, 3…); total split
    /// proportionally to share / sum(shares).
    case shares

    public var displayLabel: String {
        switch self {
        case .equal:   return "Igualmente"
        case .exact:   return "Por monto"
        case .percent: return "Por %"
        case .shares:  return "Por partes"
        }
    }
}

/// One row of `metadata.split_breakdown`. `shareCents` is the canonical
/// owed amount for that member, regardless of the mode that produced
/// it. Sums to `LedgerEntry.amountCents` for the entry.
public struct SplitBreakdown: Sendable, Hashable, Codable {
    public let memberId: UUID
    public let shareCents: Int64

    public init(memberId: UUID, shareCents: Int64) {
        self.memberId = memberId
        self.shareCents = shareCents
    }

    public enum CodingKeys: String, CodingKey {
        case memberId   = "member_id"
        case shareCents = "share_cents"
    }
}
