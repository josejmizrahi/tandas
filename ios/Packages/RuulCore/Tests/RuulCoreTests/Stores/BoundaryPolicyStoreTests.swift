import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("BoundaryPolicyStore")
struct BoundaryPolicyStoreTests {

    private let groupId = UUID()

    private func makeStore(seed: GroupBoundaryPolicy? = nil) async -> (BoundaryPolicyStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        if let seed {
            await mock.setGroupBoundaryPolicyStub(.success(seed))
        }
        let repo = CanonicalBoundaryRepository(rpc: mock)
        return (BoundaryPolicyStore(repository: repo), mock)
    }

    @Test("refresh loads policy and lands on .loaded")
    func refreshHappyPath() async {
        let policy = GroupBoundaryPolicy(
            groupId: groupId,
            entryMode: .open,
            whoCanInvite: .adminsOnly,
            requiresApproval: true,
            exitMode: .requiresNotice,
            isDefault: false
        )
        let (store, _) = await makeStore(seed: policy)
        await store.refresh(groupId: groupId)
        #expect(store.policy?.entryMode == .open)
        #expect(store.policy?.isDefault == false)
        #expect(store.phase == .loaded)
    }

    @Test("beginEditing prefills draft from the loaded policy")
    func beginEditingPrefills() async {
        let policy = GroupBoundaryPolicy(
            groupId: groupId,
            entryMode: .closed,
            whoCanInvite: .adminsOnly,
            requiresApproval: true,
            exitMode: .requiresNotice,
            notes: "Cerrado por ahora",
            isDefault: false
        )
        let (store, _) = await makeStore(seed: policy)
        await store.refresh(groupId: groupId)
        store.beginEditing()
        #expect(store.draftEntryMode == .closed)
        #expect(store.draftWhoCanInvite == .adminsOnly)
        #expect(store.draftRequiresApproval)
        #expect(store.draftExitMode == .requiresNotice)
        #expect(store.draftNotes == "Cerrado por ahora")
        #expect(store.isEditPresented)
    }

    @Test("saveDraft sends set_group_boundary_policy with current draft")
    func saveDraftSubmits() async {
        let mock = MockRuulRPCClient()
        let initial = GroupBoundaryPolicy(groupId: groupId)
        await mock.setGroupBoundaryPolicyStub(.success(initial))
        await mock.setSetGroupBoundaryPolicyStub(.success(
            GroupBoundaryPolicy(
                groupId: groupId,
                entryMode: .open,
                whoCanInvite: .anyMember,
                requiresApproval: false,
                exitMode: .free,
                isDefault: false
            )
        ))
        let store = BoundaryPolicyStore(repository: CanonicalBoundaryRepository(rpc: mock))
        await store.refresh(groupId: groupId)
        store.beginEditing()
        store.draftEntryMode = .open
        store.draftRequiresApproval = false
        store.draftNotes = "  Sin acuerdos especiales  "

        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isEditPresented == false)
        #expect(store.policy?.isDefault == false)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .setGroupBoundaryPolicy(let input) = call {
                return input.pGroupId == groupId
                    && input.pEntryMode == "open"
                    && input.pWhoCanInvite == "any_member"
                    && input.pRequiresApproval == false
                    && input.pExitMode == "free"
                    && input.pNotes == "Sin acuerdos especiales"
            }
            return false
        })
    }

    @Test("saveDraft failure surfaces error and keeps the sheet open")
    func saveDraftFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupBoundaryPolicyStub(.success(GroupBoundaryPolicy(groupId: groupId)))
        await mock.setSetGroupBoundaryPolicyStub(.failure(.backend(.lacksPermission(permission: "group.update", groupId: groupId))))
        let store = BoundaryPolicyStore(repository: CanonicalBoundaryRepository(rpc: mock))
        await store.refresh(groupId: groupId)
        store.beginEditing()
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.draftErrorMessage != nil)
        #expect(store.isEditPresented)
    }
}
