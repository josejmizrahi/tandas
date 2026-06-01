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

    /// V3 D.24 P2B-1.x + P2B-1.y — smart create that routes to the most
    /// specific authorized RPC per type:
    /// - **6 subtype wrappers** (P2A): fund/space/asset/right/**slot** (P2B-1.y).
    /// - **`create_generic_resource`** (P2B-1.y) for the 12 envelope-only types.
    /// - **`create_event`** is the canonical event path; this router does
    ///   NOT handle `event` — callers must redirect to the Calendar
    ///   create flow. If invoked anyway, throws `RuulError.unexpected`.
    ///
    /// Fallback: if a specific wrapper throws (network glitch, transient
    /// validation), falls back to `create_group_resource` (envelope-only)
    /// so the user's create attempt still completes. The audit table then
    /// shows `intent_marker='create_group_resource'`, which is the
    /// signal that the wrapper path needs investigation.
    ///
    /// Always passes a fresh `client_id` for idempotency. Returns the
    /// resource_id; callers should refresh the list / load summary.
    @discardableResult
    public func createResourceSmart(
        groupId: UUID,
        type: GroupResourceType,
        name: String,
        description: String? = nil,
        visibility: ResourceVisibility = .members,
        ownershipKind: ResourceOwnershipKind = .group,
        ownerMembershipId: UUID? = nil,
        slotStartsAt: Date? = nil,
        slotEndsAt: Date? = nil,
        clientId: String = UUID().uuidString
    ) async throws -> UUID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank

        // event is canonical via `create_event` — caller must redirect.
        if type == .event {
            throw RuulError.unexpected(
                message: "createResourceSmart: type=event debe usar el flujo de Calendar (create_event)."
            )
        }

        // Try the most specific authorized path first.
        do {
            switch type {
            case .fund:
                return try await rpc.createFundResource(
                    CreateFundResourceParams(
                        groupId: groupId,
                        name: trimmedName,
                        fundKind: "pool",
                        description: trimmedDescription,
                        visibility: visibility.rawValue,
                        clientId: clientId
                    )
                )
            case .space:
                return try await rpc.createSpaceResource(
                    CreateSpaceResourceParams(
                        groupId: groupId,
                        name: trimmedName,
                        description: trimmedDescription,
                        visibility: visibility.rawValue,
                        clientId: clientId
                    )
                )
            case .asset:
                return try await rpc.createAssetResource(
                    CreateAssetResourceParams(
                        groupId: groupId,
                        name: trimmedName,
                        description: trimmedDescription,
                        ownerMembershipId: ownerMembershipId,
                        ownershipKind: ownershipKind.rawValue,
                        visibility: visibility.rawValue,
                        clientId: clientId
                    )
                )
            case .right:
                return try await rpc.createRightResource(
                    CreateRightResourceParams(
                        groupId: groupId,
                        name: trimmedName,
                        rightKind: "access",
                        description: trimmedDescription,
                        visibility: visibility.rawValue,
                        clientId: clientId
                    )
                )
            case .slot:
                guard let starts = slotStartsAt else {
                    throw RuulError.unexpected(
                        message: "createResourceSmart: type=slot requiere slotStartsAt."
                    )
                }
                return try await rpc.createSlotResource(
                    CreateSlotResourceParams(
                        groupId: groupId,
                        name: trimmedName,
                        slotStartsAt: starts,
                        slotEndsAt: slotEndsAt,
                        description: trimmedDescription,
                        visibility: visibility.rawValue,
                        clientId: clientId
                    )
                )
            case .event:
                // Unreachable — guarded above.
                break
            default:
                // The 12 envelope-only types route through the explicit
                // generic wrapper so the audit table can distinguish
                // them from unauthorized direct inserts.
                return try await rpc.createGenericResource(
                    CreateGenericResourceParams(
                        groupId: groupId,
                        resourceType: type.rawValue,
                        name: trimmedName,
                        description: trimmedDescription,
                        visibility: visibility.rawValue,
                        ownershipKind: ownershipKind.rawValue,
                        ownerMembershipId: ownerMembershipId,
                        clientId: clientId
                    )
                )
            }
        } catch {
            // Wrapper failed — degrade to legacy envelope. The audit
            // trigger will mark the resulting row as
            // `intent_marker='create_group_resource'`, which is still
            // authorized but signals that the wrapper path needs review.
        }

        // Legacy envelope-only path (safety net).
        let resource = try await createResource(
            groupId: groupId,
            type: type,
            name: trimmedName,
            description: trimmedDescription,
            visibility: visibility,
            ownershipKind: ownershipKind,
            ownerMembershipId: ownerMembershipId
        )
        return resource.id
    }

    public func archiveResource(resourceId: UUID, reason: String? = nil) async throws {
        let trimmed = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        try await rpc.archiveGroupResource(
            ArchiveGroupResourceInput(pResourceId: resourceId, pReason: trimmed)
        )
    }

    /// D.22 — governance-aware archive. Routes through
    /// `request_or_execute_action(actionKey='resource.archive', …)`. If the
    /// resolver permits direct execution (founder override or future
    /// group-level downgrade) we follow up with the underlying RPC and
    /// return `.directAllowed`. Otherwise we surface the decision_opened
    /// (or denied/failed) outcome unmodified for the UI.
    public func archiveResourceViaGovernance(
        groupId: UUID,
        resourceId: UUID,
        reason: String? = nil
    ) async throws -> ActionOutcome {
        let trimmedReason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        var payload: [String: RPCJSONValue] = [:]
        if let trimmedReason { payload["reason"] = .string(trimmedReason) }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "resource.archive",
                targetKind: "resource",
                targetId:   resourceId,
                payload:    payload
            )
        )

        switch outcome {
        case .directAllowed:
            try await archiveResource(resourceId: resourceId, reason: trimmedReason)
            return outcome
        case .decisionOpened, .denied, .unsupported, .failed:
            return outcome
        }
    }

    /// D.22 — governance-aware transfer. Routes through
    /// `request_or_execute_action(actionKey='resource.transfer', …)`.
    /// On `.directAllowed` performs the legacy `set_resource_ownership`
    /// call; otherwise returns the outcome unmodified.
    public func transferOwnershipViaGovernance(
        groupId: UUID,
        resourceId: UUID,
        ownershipKind: ResourceOwnershipKind,
        ownerMembershipId: UUID? = nil,
        note: String? = nil
    ) async throws -> ActionOutcome {
        var payload: [String: RPCJSONValue] = [
            "target_ownership_kind": .string(ownershipKind.rawValue)
        ]
        if let ownerMembershipId, ownershipKind == .member {
            payload["target_membership_id"] = .string(ownerMembershipId.uuidString)
        }
        if let trimmed = note?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank {
            payload["ownership_metadata"] = .object(["note": .string(trimmed)])
        }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "resource.transfer",
                targetKind: "resource",
                targetId:   resourceId,
                payload:    payload
            )
        )

        if case .directAllowed = outcome {
            try await transferOwnership(
                resourceId: resourceId,
                ownershipKind: ownershipKind,
                ownerMembershipId: ownerMembershipId,
                note: note
            )
        }
        return outcome
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

    /// V3 D.24 P12B-2 — single round-trip detail summary. Combines what
    /// `resourceDetail` + `recentActivity` + ownership/capability fetches
    /// used to do separately. Caller can fallback to those legacy paths
    /// if this throws.
    public func resourceDetailSummary(resourceId: UUID) async throws -> ResourceDetailSummary {
        try await rpc.resourceDetailSummary(resourceId: resourceId)
    }

    /// Server-side filtered activity for a resource via
    /// `group_events_for_entity` (entity_kind='resource', entity_id=...).
    public func recentActivity(
        groupId: UUID,
        resourceId: UUID,
        limit: Int = 50
    ) async throws -> [GroupEvent] {
        try await rpc.groupEventsForEntity(
            GroupEventsForEntityParams(
                groupId: groupId,
                entityKind: "resource",
                entityId: resourceId,
                limit: limit,
                before: nil
            )
        )
    }

    /// Movements linked to this resource, client-side filtered on
    /// `resource_id` or `source_resource_id`. record_expense/
    /// record_contribution accept p_resource_id; pool_charge does not
    /// (yet).
    public func recentMovements(
        groupId: UUID,
        resourceId: UUID,
        limit: Int = 100
    ) async throws -> [MoneyMovement] {
        let all = try await rpc.groupMoneyMovements(
            groupId: groupId,
            limit: limit,
            filter: nil,
            beforeSeq: nil
        )
        return all.filter { $0.resourceId == resourceId || $0.sourceResourceId == resourceId }
    }

    /// Envelope-only metadata edit. Backend merges `p_metadata` with
    /// the existing jsonb (set value to `.null` to remove a key, since
    /// `metadata || {"k": null}` keeps the key with a JSON null —
    /// good enough for the descriptor-driven UI).
    public func updateMetadata(
        resourceId: UUID,
        metadata: [String: RPCJSONValue]
    ) async throws {
        guard !metadata.isEmpty else { return }
        try await rpc.updateResource(
            UpdateResourceParams(resourceId: resourceId, metadata: metadata)
        )
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

    /// D24P10B — governance-aware lockFund. Lock irreversible → governance.
    public func lockFundViaGovernance(
        groupId: UUID,
        resourceId: UUID,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> ActionOutcome {
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        var payload: [String: RPCJSONValue] = [
            "resource_id": .string(resourceId.uuidString)
        ]
        if let trimmedReason { payload["reason"] = .string(trimmedReason) }
        if let clientId, !clientId.isEmpty { payload["client_id"] = .string(clientId) }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "resource.fund.lock",
                targetKind: "resource",
                targetId:   resourceId,
                payload:    payload
            )
        )
        if case .directAllowed = outcome {
            _ = try await lockFund(resourceId: resourceId, reason: trimmedReason, clientId: clientId)
        }
        return outcome
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

    // MARK: - Space / Bookings Fase B.3

    @discardableResult
    public func bookResource(
        resourceId: UUID,
        startsAt: Date,
        endsAt: Date? = nil,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.bookResource(
            BookResourceParams(
                resourceId: resourceId,
                startsAt: startsAt,
                endsAt: endsAt,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    @discardableResult
    public func cancelBooking(
        bookingId: UUID,
        reason: String? = nil
    ) async throws -> UUID {
        try await rpc.cancelBooking(
            CancelBookingParams(
                bookingId: bookingId,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            )
        )
    }

    public func listBookingsForResource(
        resourceId: UUID,
        startsAfter: Date? = nil,
        endsBefore: Date? = nil,
        limit: Int = 50
    ) async throws -> [GroupResourceBooking] {
        try await rpc.listBookingsForResource(
            ListBookingsForResourceParams(
                resourceId: resourceId,
                startsAfter: startsAfter,
                endsBefore: endsBefore,
                limit: limit
            )
        )
    }

    // MARK: - Right Fase B.4

    @discardableResult
    public func grantRight(
        resourceId: UUID,
        holderMembershipId: UUID,
        rightKind: ResourceRightKind?,
        expiresAt: Date? = nil,
        conditions: String? = nil,
        transferable: Bool = false,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.grantRight(
            GrantRightParams(
                resourceId: resourceId,
                holderMembershipId: holderMembershipId,
                rightKind: rightKind?.rawValue,
                expiresAt: expiresAt,
                conditions: conditions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                transferable: transferable,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    @discardableResult
    public func transferRight(
        resourceId: UUID,
        newHolderMembershipId: UUID,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.transferRight(
            TransferRightParams(
                resourceId: resourceId,
                newHolderMembershipId: newHolderMembershipId,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    /// D24P10B — governance-aware transferRight. Cuando holder ≠ caller,
    /// rutea por governance (delegación a tercero = constitutional).
    public func transferRightViaGovernance(
        groupId: UUID,
        resourceId: UUID,
        newHolderMembershipId: UUID,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> ActionOutcome {
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        var payload: [String: RPCJSONValue] = [
            "resource_id":              .string(resourceId.uuidString),
            "new_holder_membership_id": .string(newHolderMembershipId.uuidString)
        ]
        if let trimmedReason { payload["reason"] = .string(trimmedReason) }
        if let clientId, !clientId.isEmpty { payload["client_id"] = .string(clientId) }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "resource.right.transfer",
                targetKind: "resource",
                targetId:   resourceId,
                payload:    payload
            )
        )
        if case .directAllowed = outcome {
            _ = try await transferRight(
                resourceId: resourceId,
                newHolderMembershipId: newHolderMembershipId,
                reason: trimmedReason,
                clientId: clientId)
        }
        return outcome
    }

    @discardableResult
    public func revokeRight(
        resourceId: UUID,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.revokeRight(
            RevokeRightParams(
                resourceId: resourceId,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    @discardableResult
    public func expireRight(
        resourceId: UUID,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.expireRight(
            ExpireRightParams(
                resourceId: resourceId,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    // MARK: - Slot Fase B.5

    @discardableResult
    public func assignSlot(
        resourceId: UUID,
        membershipId: UUID,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.assignSlot(
            AssignSlotParams(
                resourceId: resourceId,
                membershipId: membershipId,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank,
                startsAt: startsAt,
                endsAt: endsAt
            )
        )
    }

    @discardableResult
    public func releaseSlot(
        resourceId: UUID,
        reason: String? = nil,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.releaseSlot(
            ReleaseSlotParams(
                resourceId: resourceId,
                reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                clientId: clientId?.nilIfBlank
            )
        )
    }

    @discardableResult
    public func expireSlot(
        resourceId: UUID,
        clientId: String? = nil
    ) async throws -> UUID {
        try await rpc.expireSlot(
            ExpireSlotParams(
                resourceId: resourceId,
                clientId: clientId?.nilIfBlank
            )
        )
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
