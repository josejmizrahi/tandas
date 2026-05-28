import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("RolesStore")
struct RolesStoreTests {

    private let groupId = UUID()

    private func systemRole(key: String, name: String, isDefault: Bool = false) -> GroupRole {
        GroupRole(
            id: UUID(), groupId: groupId,
            key: key, name: name,
            isSystem: true, isDefault: isDefault,
            permissionKeys: ["group.update"], memberCount: 1
        )
    }

    private func customRole() -> GroupRole {
        GroupRole(
            id: UUID(), groupId: groupId,
            key: "treasurer", name: "Tesorero",
            description: "Lleva el dinero",
            isSystem: false, isDefault: false,
            permissionKeys: ["money.record_expense"], memberCount: 0
        )
    }

    private func catalog() -> [PermissionCatalogEntry] {
        [
            .init(key: "decisions.create", description: "Abrir decisiones", category: .decisions),
            .init(key: "decisions.vote",   description: "Votar",            category: .decisions),
            .init(key: "rules.create",     description: "Crear reglas",     category: .rules),
            .init(key: "money.record_expense", description: "Registrar gasto", category: .money)
        ]
    }

    private func makeStore(
        roles: [GroupRole] = [],
        catalog: [PermissionCatalogEntry] = []
    ) async -> (RolesStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setListGroupRolesStub(.success(roles))
        await mock.setListPermissionsCatalogStub(.success(catalog))
        let repo = CanonicalRolesRepository(rpc: mock)
        return (RolesStore(repository: repo), mock)
    }

    @Test("refresh loads roles + catalog and partitions system/custom")
    func refreshHappyPath() async {
        let (store, _) = await makeStore(
            roles: [
                systemRole(key: "founder", name: "Fundador"),
                systemRole(key: "member", name: "Miembro", isDefault: true),
                customRole()
            ],
            catalog: catalog()
        )
        await store.refresh(groupId: groupId)
        #expect(store.systemRoles.count == 2)
        #expect(store.customRoles.count == 1)
        #expect(store.catalogByCategory.count >= 2)
        #expect(store.phase == .loaded)
    }

    @Test("togglePermission flips set; toggleCategory does bulk on/off")
    func togglePermissions() async {
        let (store, _) = await makeStore(catalog: catalog())
        await store.refresh(groupId: groupId)
        store.beginCreating()
        #expect(store.draftPermissions.isEmpty)

        store.togglePermission("decisions.create")
        #expect(store.draftPermissions == ["decisions.create"])
        store.togglePermission("decisions.create")
        #expect(store.draftPermissions.isEmpty)

        store.toggleCategory(.decisions, selectAll: true)
        #expect(store.draftPermissions == ["decisions.create", "decisions.vote"])
        store.toggleCategory(.decisions, selectAll: false)
        #expect(store.draftPermissions.isEmpty)
    }

    @Test("categorySelectionState classifies none/partial/all/empty")
    func categorySelectionStates() async {
        let (store, _) = await makeStore(catalog: catalog())
        await store.refresh(groupId: groupId)
        store.beginCreating()
        #expect(store.categorySelectionState(.decisions) == .none)
        store.togglePermission("decisions.create")
        if case .partial(let selected, let total) = store.categorySelectionState(.decisions) {
            #expect(selected == 1)
            #expect(total == 2)
        } else {
            Issue.record("expected .partial")
        }
        store.toggleCategory(.decisions, selectAll: true)
        #expect(store.categorySelectionState(.decisions) == .all)
        // No permissions in audit category in our seed
        #expect(store.categorySelectionState(.audit) == .empty)
    }

    @Test("saveDraft in create mode sends create_custom_role with sorted keys + lowercased key")
    func saveCreateDraft() async {
        let (store, mock) = await makeStore(catalog: catalog())
        await store.refresh(groupId: groupId)
        store.beginCreating()
        store.draftKey = "  Tesorero del Mes  "
        store.draftName = "Tesorero del Mes"
        store.draftPermissions = ["rules.create", "decisions.create"]
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isEditorPresented == false)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .createCustomRole(let input) = call {
                return input.pGroupId == groupId
                    && input.pKey == "tesorero_del_mes"
                    && input.pName == "Tesorero del Mes"
                    && input.pPermissionKeys == ["decisions.create", "rules.create"]
            }
            return false
        })
    }

    @Test("saveDraft in edit mode sends update_role_permissions only")
    func saveEditDraft() async {
        let role = customRole()
        let (store, mock) = await makeStore(roles: [role], catalog: catalog())
        await store.refresh(groupId: groupId)
        store.beginEditing(role)
        store.draftPermissions = ["money.record_expense", "rules.create"]
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .updateRolePermissions(let input) = call {
                return input.pRoleId == role.id
                    && input.pPermissionKeys == ["money.record_expense", "rules.create"]
            }
            return false
        })
        // edit mode must NOT also create
        let creates = recorded.filter { if case .createCustomRole = $0 { return true } else { return false } }
        #expect(creates.isEmpty)
    }

    @Test("saveDraft rejects empty name locally")
    func saveDraftEmptyName() async {
        let (store, _) = await makeStore()
        store.beginCreating()
        store.draftKey = "x"
        store.draftName = "   "
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.draftErrorMessage != nil)
    }
}
