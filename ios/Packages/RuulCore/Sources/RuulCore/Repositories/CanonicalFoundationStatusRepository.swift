import Foundation

/// Foundation-scope repository for the readiness check. Single-method
/// wrapper around `group_foundation_status(p_group_id)`. iOS uses
/// this to decide whether a group has the five Foundation primitives
/// (Members/Boundary/Purpose/Rules/Resources) configured enough to
/// move into engine flows.
public struct CanonicalFoundationStatusRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func fetchGroupFoundationStatus(groupId: UUID) async throws -> GroupFoundationStatus {
        try await rpc.groupFoundationStatus(groupId: groupId)
    }
}
