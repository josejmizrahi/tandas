import Foundation

/// R.14.C — Fila de reputación de miembro retornada por
/// `list_context_members_with_reputation(p_context_id)`.
///
/// El backend pre-agrega 9 métricas en SQL para evitar que iOS haga N+1 RPC
/// calls (antes: listEvents + listObligations + contextSummary + N×listEventParticipants).
/// El cómputo del score se queda en cliente porque es UI policy.
public struct MemberReputationRow: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let actorId: UUID
    public let displayName: String
    public let membershipType: String?
    public let attendedEvents: Int
    public let missedEvents: Int
    public let lateEvents: Int
    public let cancelledEvents: Int
    public let hostedEvents: Int
    public let openFines: Int
    public let openMoney: Int
    public let settledMoney: Int
    public let recentActivityCount: Int

    public var id: UUID { actorId }

    enum CodingKeys: String, CodingKey {
        case actorId = "actor_id"
        case displayName = "display_name"
        case membershipType = "membership_type"
        case attendedEvents = "attended_events"
        case missedEvents = "missed_events"
        case lateEvents = "late_events"
        case cancelledEvents = "cancelled_events"
        case hostedEvents = "hosted_events"
        case openFines = "open_fines"
        case openMoney = "open_money"
        case settledMoney = "settled_money"
        case recentActivityCount = "recent_activity_count"
    }

    public init(
        actorId: UUID,
        displayName: String,
        membershipType: String? = nil,
        attendedEvents: Int = 0,
        missedEvents: Int = 0,
        lateEvents: Int = 0,
        cancelledEvents: Int = 0,
        hostedEvents: Int = 0,
        openFines: Int = 0,
        openMoney: Int = 0,
        settledMoney: Int = 0,
        recentActivityCount: Int = 0
    ) {
        self.actorId = actorId
        self.displayName = displayName
        self.membershipType = membershipType
        self.attendedEvents = attendedEvents
        self.missedEvents = missedEvents
        self.lateEvents = lateEvents
        self.cancelledEvents = cancelledEvents
        self.hostedEvents = hostedEvents
        self.openFines = openFines
        self.openMoney = openMoney
        self.settledMoney = settledMoney
        self.recentActivityCount = recentActivityCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actorId = try c.decode(UUID.self, forKey: .actorId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.membershipType = try c.decodeIfPresent(String.self, forKey: .membershipType)
        self.attendedEvents = try c.decodeIfPresent(Int.self, forKey: .attendedEvents) ?? 0
        self.missedEvents = try c.decodeIfPresent(Int.self, forKey: .missedEvents) ?? 0
        self.lateEvents = try c.decodeIfPresent(Int.self, forKey: .lateEvents) ?? 0
        self.cancelledEvents = try c.decodeIfPresent(Int.self, forKey: .cancelledEvents) ?? 0
        self.hostedEvents = try c.decodeIfPresent(Int.self, forKey: .hostedEvents) ?? 0
        self.openFines = try c.decodeIfPresent(Int.self, forKey: .openFines) ?? 0
        self.openMoney = try c.decodeIfPresent(Int.self, forKey: .openMoney) ?? 0
        self.settledMoney = try c.decodeIfPresent(Int.self, forKey: .settledMoney) ?? 0
        self.recentActivityCount = try c.decodeIfPresent(Int.self, forKey: .recentActivityCount) ?? 0
    }
}
