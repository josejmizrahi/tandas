import Foundation
import Observation

/// `@MainActor` store for Primitiva 17 (Roles + Permissions). Caches
/// the group's roles + the global permissions catalog, and drives the
/// editor sheet through draft state.
@MainActor
@Observable
public final class RolesStore {
    public private(set) var roles: [GroupRole] = []
    public private(set) var catalog: [PermissionCatalogEntry] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?
    /// D.22 — constitutional role.create / role.update_permissions
    /// always opens a vote.
    public private(set) var lastGovernanceOutcome: ActionOutcome?

    // MARK: - Create / edit draft

    /// `nil` while the editor is creating a new role; populated when
    /// editing an existing role.
    public var isEditorPresented: Bool = false
    public var editorRoleId: UUID?
    public var draftKey: String = ""
    public var draftName: String = ""
    public var draftDescription: String = ""
    public var draftPermissions: Set<String> = []
    public private(set) var draftErrorMessage: String?

    private let repository: CanonicalRolesRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalRolesRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasRoles: Bool { !roles.isEmpty }
    public var systemRoles: [GroupRole] { roles.filter(\.isSystem) }
    public var customRoles: [GroupRole] { roles.filter { !$0.isSystem } }

    /// Catalog grouped by `PermissionCategory`. Categories with zero
    /// permissions are omitted.
    public var catalogByCategory: [(PermissionCategory, [PermissionCatalogEntry])] {
        let grouped = Dictionary(grouping: catalog, by: \.category)
        return PermissionCategory.displayOrder.compactMap { category in
            guard let entries = grouped[category], !entries.isEmpty else { return nil }
            return (category, entries.sorted { $0.key < $1.key })
        }
    }

    public var isEditingExisting: Bool { editorRoleId != nil }

    public var canSaveDraft: Bool {
        let cleanName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if editorRoleId == nil {
            // Create flow needs both key + name.
            let cleanKey = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return !cleanKey.isEmpty && !cleanName.isEmpty
        }
        return !cleanName.isEmpty
    }

    // MARK: - List intents

    public func refresh(groupId: UUID) async {
        if roles.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            async let rolesTask   = repository.listRoles(groupId: groupId)
            async let catalogTask = repository.listCatalog()
            let (loadedRoles, loadedCatalog) = try await (rolesTask, catalogTask)
            roles = loadedRoles
            catalog = loadedCatalog
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !roles.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    // MARK: - Create draft

    public func beginCreating() {
        editorRoleId = nil
        draftKey = ""
        draftName = ""
        draftDescription = ""
        draftPermissions = []
        draftErrorMessage = nil
        isEditorPresented = true
    }

    // MARK: - Edit draft

    public func beginEditing(_ role: GroupRole) {
        editorRoleId = role.id
        draftKey = role.key
        draftName = role.name
        draftDescription = role.description ?? ""
        draftPermissions = Set(role.permissionKeys)
        draftErrorMessage = nil
        isEditorPresented = true
    }

    public func togglePermission(_ key: String) {
        if draftPermissions.contains(key) {
            draftPermissions.remove(key)
        } else {
            draftPermissions.insert(key)
        }
    }

    public func toggleCategory(_ category: PermissionCategory, selectAll: Bool) {
        let keys = catalog.filter { $0.category == category }.map(\.key)
        if selectAll {
            draftPermissions.formUnion(keys)
        } else {
            draftPermissions.subtract(keys)
        }
    }

    public func categorySelectionState(_ category: PermissionCategory) -> CategorySelection {
        let keys = catalog.filter { $0.category == category }.map(\.key)
        guard !keys.isEmpty else { return .empty }
        let selected = keys.filter { draftPermissions.contains($0) }.count
        if selected == 0 { return .none }
        if selected == keys.count { return .all }
        return .partial(selected: selected, total: keys.count)
    }

    public enum CategorySelection: Equatable, Sendable {
        case empty
        case none
        case partial(selected: Int, total: Int)
        case all
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        let cleanName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            draftErrorMessage = String(localized: L10n.Roles.nameRequired)
            return false
        }
        do {
            let outcome: ActionOutcome
            if let roleId = editorRoleId {
                outcome = try await repository.updateRolePermissionsViaGovernance(
                    groupId: groupId,
                    roleId: roleId,
                    permissionKeys: Array(draftPermissions)
                )
            } else {
                let cleanKey = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanKey.isEmpty else {
                    draftErrorMessage = String(localized: L10n.Roles.keyRequired)
                    return false
                }
                outcome = try await repository.createCustomRoleViaGovernance(
                    groupId: groupId,
                    key: cleanKey,
                    name: cleanName,
                    description: draftDescription,
                    permissionKeys: Array(draftPermissions)
                )
            }
            lastGovernanceOutcome = outcome
            switch outcome {
            case .directAllowed:
                await refresh(groupId: groupId)
                isEditorPresented = false
                draftErrorMessage = nil
                return true
            case .decisionOpened:
                isEditorPresented = false
                draftErrorMessage = nil
                return true
            case .denied(let reason, let missingPermission):
                draftErrorMessage = missingPermission.map { "Falta permiso: \($0)" } ?? reason
                return false
            case .unsupported(let reason, _):
                draftErrorMessage = "Acción no soportada (\(reason))"
                return false
            case .failed(let reason, let message):
                draftErrorMessage = message ?? reason
                return false
            }
        } catch {
            draftErrorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearGovernanceOutcome() {
        lastGovernanceOutcome = nil
    }

    public func clearError() {
        errorMessage = nil
        draftErrorMessage = nil
    }

    // MARK: - Membership assignment (Primitiva 17, B3)

    /// D24P10B — `founder`/`admin` keys son constitutional → governance;
    /// roles custom keep direct path. Per `D24P10B_Governance_Routing_Matrix`.
    private func isConstitutionalRole(_ roleId: UUID) -> Bool {
        guard let role = roles.first(where: { $0.id == roleId }) else { return false }
        return role.key == "founder" || role.key == "admin"
    }

    /// D24P10B — assign rutea por governance cuando role-key es
    /// `founder`/`admin`. Caller debe pasar `groupId` para que el resolver
    /// pueda inspeccionar caller perm + role tier.
    @discardableResult
    public func assignRole(membershipId: UUID, roleId: UUID, groupId: UUID) async throws -> ActionOutcome {
        if isConstitutionalRole(roleId) {
            let outcome = try await repository.assignRoleViaGovernance(
                groupId: groupId, membershipId: membershipId, roleId: roleId)
            lastGovernanceOutcome = outcome
            return outcome
        }
        try await repository.assignRole(membershipId: membershipId, roleId: roleId)
        return .directAllowed(plan: .init(
            actionKey: "role.assign", executableRPC: "assign_role_to_member",
            targetKind: "membership", targetId: membershipId,
            reason: "non_constitutional_role", isFounder: false, isAdmin: false, riskLevel: nil))
    }

    /// D24P10B — revoke con misma lógica.
    @discardableResult
    public func revokeRole(membershipId: UUID, roleId: UUID, groupId: UUID) async throws -> ActionOutcome {
        if isConstitutionalRole(roleId) {
            let outcome = try await repository.revokeRoleViaGovernance(
                groupId: groupId, membershipId: membershipId, roleId: roleId)
            lastGovernanceOutcome = outcome
            return outcome
        }
        try await repository.revokeRole(membershipId: membershipId, roleId: roleId)
        return .directAllowed(plan: .init(
            actionKey: "role.revoke", executableRPC: "revoke_role_from_member",
            targetKind: "membership", targetId: membershipId,
            reason: "non_constitutional_role", isFounder: false, isAdmin: false, riskLevel: nil))
    }
}
