import Foundation

/// Foundation-scope repository for Primitiva 5 (Resources). Reads
/// via `group_resources_active(...)`, writes via the new envelope-
/// only `create_group_resource(...)` and the pre-existing
/// `archive_resource(...)` RPC.
public struct CanonicalResourcesRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func activeResources(groupId: UUID) async throws -> [GroupResource] {
        try await rpc.groupResourcesActive(groupId: groupId)
    }

    public func createResource(
        groupId: UUID,
        type: GroupResourceType,
        name: String,
        description: String? = nil,
        visibility: ResourceVisibility = .members,
        ownershipKind: ResourceOwnershipKind = .group,
        ownerMembershipId: UUID? = nil
    ) async throws -> GroupResource {
        // `create_group_resource` keeps `p_custodian_membership_id` on
        // the wire for Fase B (AssetSubtypeData); the Foundation surface
        // does not expose a custodian picker, so we pass NULL.
        let input = CreateGroupResourceInput(
            pGroupId: groupId,
            pResourceType: type.rawValue,
            pName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            pDescription: description?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank,
            pVisibility: visibility.rawValue,
            pOwnershipKind: ownershipKind.rawValue,
            pOwnerMembershipId: ownerMembershipId,
            pCustodianMembershipId: nil
        )
        return try await rpc.createGroupResource(input)
    }

    public func archiveResource(resourceId: UUID, reason: String? = nil) async throws {
        let trimmed = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        try await rpc.archiveGroupResource(
            ArchiveGroupResourceInput(pResourceId: resourceId, pReason: trimmed)
        )
    }

    public func transferOwnership(
        resourceId: UUID,
        ownershipKind: ResourceOwnershipKind,
        ownerMembershipId: UUID? = nil,
        note: String? = nil
    ) async throws {
        var metadata: [String: String] = [:]
        if let trimmed = note?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank {
            metadata["note"] = trimmed
        }
        try await rpc.setResourceOwnership(
            SetResourceOwnershipParams(
                resourceId: resourceId,
                ownershipKind: ownershipKind.rawValue,
                ownerMembershipId: ownershipKind == .member ? ownerMembershipId : nil,
                metadata: metadata
            )
        )
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
