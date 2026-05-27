import Foundation

/// Foundation-scope repository for Primitiva 3 (Purpose). Reads via
/// `group_purposes_active(...)` and writes via `set_group_purpose(...)`.
/// iOS never touches the `group_purposes` table directly.
public struct CanonicalPurposeRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activePurposes(groupId: UUID) async throws -> [GroupPurpose] {
        try await rpc.groupPurposesActive(groupId: groupId)
    }

    /// Trims body before sending so the wire payload is canonical;
    /// backend re-trims defensively and raises `purpose body required`
    /// if the result is empty.
    public func setPurpose(
        groupId: UUID,
        kind: GroupPurposeKind,
        body: String,
        visibility: PurposeVisibility = .members
    ) async throws -> GroupPurpose {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = SetGroupPurposeInput(
            pGroupId: groupId,
            pKind: kind.rawValue,
            pBody: trimmed,
            pVisibility: visibility.rawValue
        )
        return try await rpc.setGroupPurpose(input)
    }
}
