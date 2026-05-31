import Foundation

// MARK: - V3-D.18 — Decision summary (founder dashboard)
//
// Mirrors `decision_summary(p_group_id)`. Counts per state + participation
// metrics + histograms by type and legitimacy source.

public struct DecisionSummary: Codable, Sendable, Hashable, Equatable {
    public let groupId: UUID
    public let activeMembers: Int
    public let open: Int
    public let passed: Int
    public let rejected: Int
    public let executed: Int
    public let cancelled: Int
    public let avgTurnout: Decimal
    public let participationRate: Decimal
    public let byType: [String: Int]
    public let byLegitimacySource: [String: Int]

    enum CodingKeys: String, CodingKey {
        case groupId             = "group_id"
        case activeMembers       = "active_members"
        case open, passed, rejected, executed, cancelled
        case avgTurnout          = "avg_turnout"
        case participationRate   = "participation_rate"
        case byType              = "by_type"
        case byLegitimacySource  = "by_legitimacy_source"
    }

    public init(
        groupId: UUID,
        activeMembers: Int,
        open: Int,
        passed: Int,
        rejected: Int,
        executed: Int,
        cancelled: Int,
        avgTurnout: Decimal,
        participationRate: Decimal,
        byType: [String: Int] = [:],
        byLegitimacySource: [String: Int] = [:]
    ) {
        self.groupId = groupId
        self.activeMembers = activeMembers
        self.open = open
        self.passed = passed
        self.rejected = rejected
        self.executed = executed
        self.cancelled = cancelled
        self.avgTurnout = avgTurnout
        self.participationRate = participationRate
        self.byType = byType
        self.byLegitimacySource = byLegitimacySource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.activeMembers = (try c.decodeIfPresent(Int.self, forKey: .activeMembers)) ?? 0
        self.open = (try c.decodeIfPresent(Int.self, forKey: .open)) ?? 0
        self.passed = (try c.decodeIfPresent(Int.self, forKey: .passed)) ?? 0
        self.rejected = (try c.decodeIfPresent(Int.self, forKey: .rejected)) ?? 0
        self.executed = (try c.decodeIfPresent(Int.self, forKey: .executed)) ?? 0
        self.cancelled = (try c.decodeIfPresent(Int.self, forKey: .cancelled)) ?? 0
        self.avgTurnout = (try c.decodeIfPresent(Decimal.self, forKey: .avgTurnout)) ?? 0
        self.participationRate = (try c.decodeIfPresent(Decimal.self, forKey: .participationRate)) ?? 0
        self.byType = (try c.decodeIfPresent([String: Int].self, forKey: .byType)) ?? [:]
        self.byLegitimacySource = (try c.decodeIfPresent([String: Int].self, forKey: .byLegitimacySource)) ?? [:]
    }
}
