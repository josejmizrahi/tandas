import Foundation

/// One row in the user's group list — derived from `group_memberships` join `groups`
/// for `status = 'active'`. Foundation needs only the bare minimum to render a row.
public struct GroupListItem: Sendable, Hashable, Identifiable {
    public let id: UUID                 // group_id
    public let name: String
    public let slug: String?
    public let category: String?
    public let purposeSummary: String?
    public let membershipId: UUID

    public init(
        id: UUID,
        name: String,
        slug: String?,
        category: String?,
        purposeSummary: String?,
        membershipId: UUID
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.category = category
        self.purposeSummary = purposeSummary
        self.membershipId = membershipId
    }
}

/// Result of `accept_invite(p_code)`. Returns the group joined and the
/// new membership row created for the caller.
public struct AcceptInviteResult: Sendable, Equatable {
    public let groupId: UUID
    public let membershipId: UUID

    public init(groupId: UUID, membershipId: UUID) {
        self.groupId = groupId
        self.membershipId = membershipId
    }
}

/// Result of `record_settlement`. Returns both the settlement row id and
/// the ledger transaction id materialised by the close.
public struct SettlementResult: Sendable, Equatable {
    public let settlementId: UUID
    public let transactionId: UUID

    public init(settlementId: UUID, transactionId: UUID) {
        self.settlementId = settlementId
        self.transactionId = transactionId
    }
}

/// Aggregated counts + recent events for a group, as returned by
/// `group_summary(p_group_id) returns jsonb`. Named `CanonicalGroupSummary`
/// to avoid a clash with the legacy `GroupSummary` in `PlatformModels/`;
/// drop the prefix once legacy is gone.
public struct CanonicalGroupSummary: Sendable, Hashable {
    public let groupId: UUID
    public let memberCount: Int
    public let openDecisions: Int
    public let openDisputes: Int
    public let openObligations: Int
    public let recentEvents: [Event]

    public struct Event: Sendable, Hashable, Identifiable {
        public let id: Int64
        public let eventType: String
        public let summary: String?
        public let occurredAt: Date?

        public init(id: Int64, eventType: String, summary: String?, occurredAt: Date?) {
            self.id = id
            self.eventType = eventType
            self.summary = summary
            self.occurredAt = occurredAt
        }
    }

    public init(
        groupId: UUID,
        memberCount: Int,
        openDecisions: Int,
        openDisputes: Int,
        openObligations: Int,
        recentEvents: [Event]
    ) {
        self.groupId = groupId
        self.memberCount = memberCount
        self.openDecisions = openDecisions
        self.openDisputes = openDisputes
        self.openObligations = openObligations
        self.recentEvents = recentEvents
    }
}
