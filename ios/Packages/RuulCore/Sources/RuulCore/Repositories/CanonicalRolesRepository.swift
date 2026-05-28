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
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
