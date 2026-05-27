import Foundation

/// Foundation-scope repository for Primitiva 12 (Trust/Reputation).
/// Reads via `member_reputation_events(...)`. Write path exists at the
/// RPC layer (`record_reputation_event`) but is intentionally NOT
/// exposed here — doctrine forbids user-facing "marcar trust" UX. Backend
/// triggers + edge functions are the only writers.
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
}
