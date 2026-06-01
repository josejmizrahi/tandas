import Foundation

/// V3 D.24 P12A — payload of `group_home_summary(p_group_id)` RPC. Single
/// round-trip hidratante para GroupHomeFeedView: el grupo + my_membership
/// + permisos cacheados + 3 counts agregados + el último activity feed.
///
/// iOS adopt iniciado en P12B-1 (solo GroupHome). ResourceDetail/EventDetail
/// y DecisionDetail mantienen sus paths legacy hasta P12B-2/3/4.
public struct GroupHomeSummary: Codable, Sendable, Equatable, Hashable {
    public let group: GroupListItem.Lite
    public let myMembership: MembershipLite?
    public let permissions: [String]
    public let openDecisionsCount: Int
    public let openObligationsCount: Int
    public let upcomingEventsCount: Int
    public let recentActivity: [RecentActivityItem]
    public let callerMembershipId: UUID?
    public let callerUserId: UUID?

    enum CodingKeys: String, CodingKey {
        case group
        case myMembership          = "my_membership"
        case permissions
        case openDecisionsCount    = "open_decisions_count"
        case openObligationsCount  = "open_obligations_count"
        case upcomingEventsCount   = "upcoming_events_count"
        case recentActivity        = "recent_activity"
        case callerMembershipId    = "caller_membership_id"
        case callerUserId          = "caller_user_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.group               = try c.decode(GroupListItem.Lite.self, forKey: .group)
        self.myMembership        = try c.decodeIfPresent(MembershipLite.self, forKey: .myMembership)
        self.permissions         = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        self.openDecisionsCount  = try c.decodeIfPresent(Int.self, forKey: .openDecisionsCount) ?? 0
        self.openObligationsCount = try c.decodeIfPresent(Int.self, forKey: .openObligationsCount) ?? 0
        self.upcomingEventsCount = try c.decodeIfPresent(Int.self, forKey: .upcomingEventsCount) ?? 0
        self.recentActivity      = try c.decodeIfPresent([RecentActivityItem].self, forKey: .recentActivity) ?? []
        self.callerMembershipId  = try c.decodeIfPresent(UUID.self, forKey: .callerMembershipId)
        self.callerUserId        = try c.decodeIfPresent(UUID.self, forKey: .callerUserId)
    }
}

public extension GroupListItem {
    /// Subset of `groups` columns returned by `group_home_summary`. Avoids
    /// pulling the full `GroupListItem` shape (membership_id depends on
    /// caller membership, not on the row itself).
    struct Lite: Codable, Sendable, Equatable, Hashable {
        public let id: UUID
        public let name: String
        public let slug: String?
        public let category: String?
        public let visibility: String?
        public let engineActive: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case slug
            case category
            case visibility
            case engineActive = "engine_active"
        }
    }
}

public struct MembershipLite: Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let userId: UUID?
    public let status: String
    public let membershipType: String?
    public let joinedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId         = "user_id"
        case status
        case membershipType = "membership_type"
        case joinedAt       = "joined_at"
    }
}

public struct RecentActivityItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID { eventUuid }
    public let eventUuid: UUID
    public let eventType: String
    public let entityKind: String?
    public let entityId: UUID?
    public let summary: String?
    public let occurredAt: Date
    public let actorUserId: UUID?

    enum CodingKeys: String, CodingKey {
        case eventUuid    = "event_uuid"
        case eventType    = "event_type"
        case entityKind   = "entity_kind"
        case entityId     = "entity_id"
        case summary
        case occurredAt   = "occurred_at"
        case actorUserId  = "actor_user_id"
    }

    /// P12B-1.x — bridge para clusters que esperan `GroupEvent` (e.g.
    /// `RecentEventRow` en `GroupHomeFeedView`). Mantiene un único shape
    /// de render en la vista hasta que P12B-2/3/4 estandaricen.
    public func toGroupEvent(groupId: UUID) -> GroupEvent {
        GroupEvent(
            id: eventUuid,
            groupId: groupId,
            actorUserId: actorUserId,
            actorDisplayName: nil,
            eventType: eventType,
            entityKind: entityKind,
            entityId: entityId,
            summary: summary,
            occurredAt: occurredAt
        )
    }
}
