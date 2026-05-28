import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("DissolutionStore")
struct DissolutionStoreTests {

    private let groupId = UUID()

    private func makeStore(seed: GroupDissolution? = nil) async -> (DissolutionStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupDissolutionActiveStub(.success(seed))
        let repo = CanonicalDissolutionRepository(rpc: mock)
        return (DissolutionStore(repository: repo), mock)
    }

    @Test("refresh with no active dissolution lands on .loaded with nil")
    func refreshEmpty() async {
        let (store, _) = await makeStore(seed: nil)
        await store.refresh(groupId: groupId)
        #expect(store.active == nil)
        #expect(store.phase == .loaded)
    }

    @Test("refresh populates active row")
    func refreshActive() async {
        let active = GroupDissolution(
            id: UUID(), groupId: groupId,
            initiatedByDisplayName: "Jose",
            status: .proposed,
            reason: "Cerramos el ciclo",
            openObligationsCount: 0
        )
        let (store, _) = await makeStore(seed: active)
        await store.refresh(groupId: groupId)
        #expect(store.active?.id == active.id)
        #expect(store.hasActive)
    }

    @Test("saveDraft rejects empty reason locally")
    func saveDraftEmptyReason() async {
        let (store, mock) = await makeStore()
        store.beginProposing()
        store.draftReason = "   "
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.draftErrorMessage != nil)
        let recorded = await mock.recorded
        let proposes = recorded.filter { if case .proposeDissolution = $0 { return true } else { return false } }
        #expect(proposes.isEmpty)
    }

    @Test("saveDraft sends propose_dissolution with trimmed reason")
    func saveDraftSubmits() async {
        let mock = MockRuulRPCClient()
        let active = GroupDissolution(
            id: UUID(), groupId: groupId,
            status: .proposed, reason: "Cerramos."
        )
        await mock.setGroupDissolutionActiveStub(.success(active))
        let store = DissolutionStore(repository: CanonicalDissolutionRepository(rpc: mock))

        store.beginProposing()
        store.draftReason = "  Cerramos.  "
        let ok = await store.saveDraft(groupId: groupId)

        #expect(ok)
        #expect(store.isProposePresented == false)
        #expect(store.active?.id == active.id)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .proposeDissolution(let input) = call {
                return input.pGroupId == groupId && input.pReason == "Cerramos."
            }
            return false
        })
    }

    @Test("finalize calls finalize_dissolution then refreshes")
    func finalizeFlow() async {
        let mock = MockRuulRPCClient()
        let id = UUID()
        let active = GroupDissolution(
            id: id, groupId: groupId,
            status: .approved, openObligationsCount: 0
        )
        await mock.setGroupDissolutionActiveStub(.success(active))
        let store = DissolutionStore(repository: CanonicalDissolutionRepository(rpc: mock))
        await store.refresh(groupId: groupId)

        store.isFinalizeConfirmPresented = true
        let ok = await store.finalize(groupId: groupId)
        #expect(ok)
        #expect(store.isFinalizeConfirmPresented == false)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .finalizeDissolution(let input) = call {
                return input.pDissolutionId == id
            }
            return false
        })
    }

    @Test("canFinalize gates the finalize button (approved + 0 obligations)")
    func canFinalizeBoundary() async {
        let mock = MockRuulRPCClient()
        let id = UUID()
        await mock.setGroupDissolutionActiveStub(.success(
            GroupDissolution(id: id, groupId: groupId, status: .approved, openObligationsCount: 1)
        ))
        let store = DissolutionStore(repository: CanonicalDissolutionRepository(rpc: mock))
        await store.refresh(groupId: groupId)
        #expect(store.canFinalize == false)
    }
}
