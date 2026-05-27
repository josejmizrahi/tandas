import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("PurposeStore")
struct PurposeStoreTests {

    private let groupId = UUID()

    private func purpose(_ kind: GroupPurposeKind, body: String, gid: UUID? = nil) -> GroupPurpose {
        GroupPurpose(id: UUID(), groupId: gid ?? groupId, kind: kind, body: body)
    }

    private func makeStore(seed: [GroupPurpose]) async -> (PurposeStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupPurposesActiveStub(.success(seed))
        let repo = CanonicalPurposeRepository(rpc: mock)
        return (PurposeStore(repository: repo), mock)
    }

    // MARK: - Refresh

    @Test("refresh loads purposes and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [purpose(.declared, body: "X")])
        await store.refresh(groupId: groupId)
        #expect(store.purposes.count == 1)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupPurposesActive(groupId: groupId)))
    }

    @Test("refreshIfNeeded is a no-op after a successful load for the same group")
    func refreshIfNeededIdempotent() async {
        let (store, mock) = await makeStore(seed: [purpose(.declared, body: "X")])
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: groupId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupPurposesActive = $0 { return true } else { return false } }
        #expect(calls.count == 1)
    }

    // MARK: - Editing

    @Test("beginEditing prefills body+visibility from existing purpose")
    func beginEditingPrefills() async {
        let p = GroupPurpose(
            id: UUID(), groupId: groupId, kind: .operative,
            body: "Rotamos host cada semana", visibility: .private
        )
        let (store, _) = await makeStore(seed: [p])
        await store.refresh(groupId: groupId)

        store.beginEditing(kind: .operative)
        #expect(store.editingKind == .operative)
        #expect(store.draftBody == "Rotamos host cada semana")
        #expect(store.draftVisibility == .private)
        #expect(store.isEditPresented)
    }

    @Test("beginEditing for missing kind starts with empty draft + members visibility")
    func beginEditingEmpty() async {
        let (store, _) = await makeStore(seed: [])
        await store.refresh(groupId: groupId)

        store.beginEditing(kind: .emotional)
        #expect(store.draftBody.isEmpty)
        #expect(store.draftVisibility == .members)
    }

    @Test("saveDraft rejects empty body locally and sets errorMessage")
    func saveRejectsEmpty() async {
        let (store, _) = await makeStore(seed: [])
        store.beginEditing(kind: .declared)
        store.draftBody = "   "
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.isEditPresented) // still open
    }

    @Test("saveDraft success merges updated purpose into the list by kind")
    func saveMerges() async {
        let existing = GroupPurpose(id: UUID(), groupId: groupId, kind: .declared, body: "Old")
        let (store, mock) = await makeStore(seed: [existing])
        let updated = GroupPurpose(id: existing.id, groupId: groupId, kind: .declared, body: "New")
        await mock.setSetGroupPurposeStub(.success(updated))

        await store.refresh(groupId: groupId)
        store.beginEditing(kind: .declared)
        store.draftBody = "New"
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok)
        #expect(store.declaredPurpose?.body == "New")
        #expect(store.purposes.count == 1) // not duplicated
        #expect(store.isEditPresented == false) // dismissed
    }

    @Test("saveDraft for a new kind appends, sorted in canonical order")
    func saveAppendsInOrder() async {
        let declared = GroupPurpose(id: UUID(), groupId: groupId, kind: .declared, body: "D")
        let (store, mock) = await makeStore(seed: [declared])
        let operativeNew = GroupPurpose(id: UUID(), groupId: groupId, kind: .operative, body: "O")
        await mock.setSetGroupPurposeStub(.success(operativeNew))

        await store.refresh(groupId: groupId)
        store.beginEditing(kind: .operative)
        store.draftBody = "O"
        _ = await store.saveDraft(groupId: groupId)

        #expect(store.purposes.map(\.kind) == [.declared, .operative])
    }

    @Test("saveDraft failure surfaces backend error and keeps the sheet open")
    func saveFailure() async {
        let (store, mock) = await makeStore(seed: [])
        await mock.setSetGroupPurposeStub(.failure(.backend(.purposeBodyRequired)))

        store.beginEditing(kind: .declared)
        store.draftBody = "Anything"
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.isEditPresented)
    }
}
