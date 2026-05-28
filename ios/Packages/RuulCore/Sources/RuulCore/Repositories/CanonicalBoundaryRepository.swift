import Foundation

/// Foundation-scope repository for Primitiva 2 (Boundary) policy.
/// Reads via `group_boundary_policy(...)`; writes via
/// `set_group_boundary_policy(...)`. Schema lives under
/// `groups.settings.boundary_policy`.
public struct CanonicalBoundaryRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func policy(groupId: UUID) async throws -> GroupBoundaryPolicy {
        try await rpc.groupBoundaryPolicy(groupId: groupId)
    }

    public func setPolicy(
        groupId: UUID,
        entryMode: BoundaryEntryMode,
        whoCanInvite: BoundaryInviterScope,
        requiresApproval: Bool,
        exitMode: BoundaryExitMode,
        notes: String?
    ) async throws -> GroupBoundaryPolicy {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = SetGroupBoundaryPolicyInput(
            groupId: groupId,
            entryMode: entryMode.rawValue,
            whoCanInvite: whoCanInvite.rawValue,
            requiresApproval: requiresApproval,
            exitMode: exitMode.rawValue,
            notes: (trimmed?.isEmpty ?? true) ? nil : trimmed
        )
        return try await rpc.setGroupBoundaryPolicy(input)
    }
}
