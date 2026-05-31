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

    public func resourceDetail(resourceId: UUID) async throws -> GroupResourceDetail {
        try await rpc.groupResourceDetail(resourceId: resourceId)
    }

    // MARK: - Asset Fase B.1

    @discardableResult
    public func assignAssetCustodian(
        resourceId: UUID,
        membershipId: UUID,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.assignAssetCustodian(
            AssignAssetCustodianParams(
                resourceId: resourceId,
                membershipId: membershipId,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    @discardableResult
    public func releaseAssetCustodian(
        resourceId: UUID,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.releaseAssetCustodian(
            ReleaseAssetCustodianParams(
                resourceId: resourceId,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    @discardableResult
    public func markAssetCondition(
        resourceId: UUID,
        condition: AssetCondition,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.markAssetCondition(
            MarkAssetConditionParams(
                resourceId: resourceId,
                condition: condition.rawValue,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    public func recordAssetValuation(
        resourceId: UUID,
        value: Decimal,
        unit: String,
        basis: String? = nil
    ) async throws {
        try await rpc.recordAssetValuation(
            RecordAssetValuationParams(
                resourceId: resourceId,
                value: value,
                unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
                basis: basis?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            )
        )
    }

    // MARK: - Fund Fase B.2

    @discardableResult
    public func lockFund(
        resourceId: UUID,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.lockFund(
            LockFundParams(
                resourceId: resourceId,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    @discardableResult
    public func unlockFund(
        resourceId: UUID,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.unlockFund(
            UnlockFundParams(
                resourceId: resourceId,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    @discardableResult
    public func setFundThreshold(
        resourceId: UUID,
        thresholdTarget: Decimal,
        unit: String?,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.setFundThreshold(
            SetFundThresholdParams(
                resourceId: resourceId,
                thresholdTarget: thresholdTarget,
                unit: unit?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
