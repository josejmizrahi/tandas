import Foundation

/// Foundation-scope repository for Primitiva 17 (Roles + Permissions).
/// Wraps `list_group_roles(...)`, `list_permissions_catalog()`,
/// `create_custom_role(...)`, `update_role_permissions(...)`,
/// `assign_role_to_member(...)` and `revoke_role_from_member(...)`.
public struct CanonicalRolesRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    // MARK: - Reads

    public func listRoles(groupId: UUID) async throws -> [GroupRole] {
        try await rpc.listGroupRoles(groupId: groupId)
    }

    public func listCatalog() async throws -> [PermissionCatalogEntry] {
        try await rpc.listPermissionsCatalog()
    }

    // MARK: - Writes

    /// Creates a custom role. `key` is the stable identifier (mirrors
    /// system role keys like `admin`); `name` is the human label.
    public func createCustomRole(
        groupId: UUID,
        key: String,
        name: String,
        description: String?,
        permissionKeys: [String]
    ) async throws -> UUID {
        let cleanedKey = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        let input = CreateCustomRoleInput(
            groupId: groupId,
            key: cleanedKey,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description?.trimmedOrNil,
            permissionKeys: permissionKeys.sorted()
        )
        return try await rpc.createCustomRole(input)
    }

    public func updateRolePermissions(
        roleId: UUID,
        permissionKeys: [String]
    ) async throws {
        try await rpc.updateRolePermissions(
            UpdateRolePermissionsInput(roleId: roleId, permissionKeys: permissionKeys.sorted())
        )
    }

    public func assignRole(membershipId: UUID, roleId: UUID) async throws {
        try await rpc.assignRoleToMember(
            AssignRoleToMemberInput(membershipId: membershipId, roleId: roleId)
        )
    }

    public func revokeRole(membershipId: UUID, roleId: UUID) async throws {
        try await rpc.revokeRoleFromMember(
            RevokeRoleFromMemberInput(membershipId: membershipId, roleId: roleId)
        )
    }

    /// D.22 — governance-aware role.create. CONSTITUTIONAL → always opens
    /// a decision. Sends key + name + description + permission_keys in
    /// the payload so execute_decision can call create_custom_role when
    /// the vote passes.
    public func createCustomRoleViaGovernance(
        groupId: UUID,
        key: String,
        name: String,
        description: String?,
        permissionKeys: [String]
    ) async throws -> ActionOutcome {
        let cleanedKey = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDesc = description?.trimmedOrNil
        let sortedPerms = permissionKeys.sorted()

        var payload: [String: RPCJSONValue] = [
            "key":             .string(cleanedKey),
            "name":            .string(cleanedName),
            "permission_keys": .array(sortedPerms.map { .string($0) })
        ]
        if let cleanedDesc { payload["description"] = .string(cleanedDesc) }

        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "role.create",
                targetKind: "group",
                targetId:   groupId,
                payload:    payload
            )
        )
        if case .directAllowed = outcome {
            _ = try await rpc.createCustomRole(
                CreateCustomRoleInput(
                    groupId: groupId,
                    key: cleanedKey,
                    name: cleanedName,
                    description: cleanedDesc,
                    permissionKeys: sortedPerms
                )
            )
        }
        return outcome
    }

    /// D24P10B — governance-aware role.assign. Founder/admin (constitutional)
    /// roles deben pasar por governance; roles custom pueden ir direct.
    /// Devuelve `.directAllowed` cuando el resolver decide direct path
    /// (admin con perm `roles.manage`), `.decisionOpened` cuando member solicita.
    public func assignRoleViaGovernance(
        groupId: UUID,
        membershipId: UUID,
        roleId: UUID
    ) async throws -> ActionOutcome {
        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "role.assign",
                targetKind: "membership",
                targetId:   membershipId,
                payload:    [
                    "role_id":       .string(roleId.uuidString),
                    "membership_id": .string(membershipId.uuidString)
                ]
            )
        )
        if case .directAllowed = outcome {
            try await assignRole(membershipId: membershipId, roleId: roleId)
        }
        return outcome
    }

    /// D24P10B — governance-aware role.revoke. Mismo patrón que assign.
    public func revokeRoleViaGovernance(
        groupId: UUID,
        membershipId: UUID,
        roleId: UUID
    ) async throws -> ActionOutcome {
        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "role.revoke",
                targetKind: "membership",
                targetId:   membershipId,
                payload:    [
                    "role_id":       .string(roleId.uuidString),
                    "membership_id": .string(membershipId.uuidString)
                ]
            )
        )
        if case .directAllowed = outcome {
            try await revokeRole(membershipId: membershipId, roleId: roleId)
        }
        return outcome
    }

    /// D.22 — governance-aware role.update_permissions. CONSTITUTIONAL.
    public func updateRolePermissionsViaGovernance(
        groupId: UUID,
        roleId: UUID,
        permissionKeys: [String]
    ) async throws -> ActionOutcome {
        let sortedPerms = permissionKeys.sorted()
        let outcome = try await rpc.requestOrExecuteAction(
            RequestOrExecuteActionParams(
                groupId:    groupId,
                actionKey:  "role.update_permissions",
                targetKind: "role",
                targetId:   roleId,
                payload:    ["permission_keys": .array(sortedPerms.map { .string($0) })]
            )
        )
        if case .directAllowed = outcome {
            try await rpc.updateRolePermissions(
                UpdateRolePermissionsInput(roleId: roleId, permissionKeys: sortedPerms)
            )
        }
        return outcome
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
