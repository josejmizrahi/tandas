import Foundation

/// Foundation-scope repository for Primitiva 12 (Trust/Reputation).
/// Three read/write paths:
/// - per-member: `member_reputation_events` — drives MemberHistoryView.
/// - group-wide feed: `group_reputation_events` — drives the new
///   ReputationFeedView (C4). Excludes private + non-active rows.
/// - admin record: `record_reputation_event` — requires the
///   `reputation.record` perm; surface lives in the C4 sheet.
///   Doctrine: hechos neutrales, NO score / NO ranking / NO badges —
///   esto sólo agrega *facts*; el UI no debe convertirlos en métrica.
public struct CanonicalReputationRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func eventsForMember(
        groupId: UUID,
        subjectMembershipId: UUID,
        limit: Int = 50
    ) async throws -> [GroupReputationEvent] {
        try await rpc.memberReputationEvents(
            groupId: groupId,
            subjectMembershipId: subjectMembershipId,
            limit: limit
        )
    }

    /// Group-wide reputation feed, newest-first. Pre-joined with
    /// subject + actor display names.
    public func groupFeed(groupId: UUID, limit: Int = 100) async throws -> [GroupReputationEvent] {
        try await rpc.groupReputationEvents(groupId: groupId, limit: limit)
    }

    /// Admin-records a reputation event. `reputation.record` perm
    /// gate lives in the backend. Returns the inserted row.
    public func record(
        groupId: UUID,
        subjectMembershipId: UUID,
        kind: ReputationKind,
        reason: String?,
        visibility: ReputationVisibility = .members
    ) async throws -> GroupReputationEvent {
        let trimmed = reason.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let input = RecordReputationEventParams(
            groupId: groupId,
            subjectMembershipId: subjectMembershipId,
            reputationType: kind.rawValue,
            reason: trimmed,
            visibility: visibility.rawValue
        )
        return try await rpc.recordReputationEvent(input)
    }
}
