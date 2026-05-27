import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("DecisionRulesStore")
struct DecisionRulesStoreTests {

    private let groupId = UUID()

    private func makeStore(initial: GroupDecisionRules? = nil) async -> (DecisionRulesStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        if let initial {
            await mock.setGroupDecisionRulesStub(.success(initial))
        } else {
            await mock.setGroupDecisionRulesStub(.success(
                GroupDecisionRules(groupId: groupId, defaultStyle: .majority, isDefault: true)
            ))
        }
        let repo = CanonicalDecisionRulesRepository(rpc: mock)
        return (DecisionRulesStore(repository: repo), mock)
    }

    // MARK: - Refresh

    @Test("refresh loads rules and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(initial: GroupDecisionRules(
            groupId: groupId, defaultStyle: .unanimity, quorumMin: 4, notes: nil, isDefault: false
        ))
        await store.refresh(groupId: groupId)
        #expect(store.rules?.defaultStyle == .unanimity)
        #expect(store.rules?.quorumMin == 4)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupDecisionRules(groupId: groupId)))
    }

    @Test("refreshIfNeeded is a no-op for the same group once loaded")
    func refreshIfNeededIdempotent() async {
        let (store, mock) = await makeStore()
        await store.refreshIfNeeded(groupId: groupId)
        await store.refreshIfNeeded(groupId: groupId)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .groupDecisionRules = $0 { return true } else { return false } }
        #expect(calls.count == 1)
    }

    // MARK: - Derived

    @Test("hasExplicitRules is false on default rules and true otherwise")
    func hasExplicitRulesFlag() async {
        let (defaultStore, _) = await makeStore(initial: GroupDecisionRules(
            groupId: groupId, defaultStyle: .majority, isDefault: true
        ))
        await defaultStore.refresh(groupId: groupId)
        #expect(defaultStore.hasExplicitRules == false)

        let (explicitStore, _) = await makeStore(initial: GroupDecisionRules(
            groupId: groupId, defaultStyle: .consensus, isDefault: false
        ))
        await explicitStore.refresh(groupId: groupId)
        #expect(explicitStore.hasExplicitRules)
    }

    @Test("resolvedStyle falls back to .majority when nothing is loaded yet")
    func resolvedStyleFallback() async {
        let mock = MockRuulRPCClient()
        let store = DecisionRulesStore(
            repository: CanonicalDecisionRulesRepository(rpc: mock)
        )
        #expect(store.resolvedStyle == .majority)
    }

    // MARK: - Editing

    @Test("beginEditing prefills draft from current rules")
    func beginEditingPrefills() async {
        let (store, _) = await makeStore(initial: GroupDecisionRules(
            groupId: groupId, defaultStyle: .consensus, quorumMin: 2,
            notes: "Lo platicamos sin votar", isDefault: false
        ))
        await store.refresh(groupId: groupId)

        store.beginEditing()
        #expect(store.draftStyle == .consensus)
        #expect(store.draftQuorum == 2)
        #expect(store.draftNotes == "Lo platicamos sin votar")
        #expect(store.isEditPresented)
    }

    @Test("beginEditing without prior rules starts at .majority + no quorum")
    func beginEditingFromScratch() async {
        let mock = MockRuulRPCClient()
        let store = DecisionRulesStore(
            repository: CanonicalDecisionRulesRepository(rpc: mock)
        )
        store.beginEditing()
        #expect(store.draftStyle == .majority)
        #expect(store.draftQuorum == nil)
        #expect(store.draftNotes.isEmpty)
    }

    @Test("canSaveDraft rejects quorum < 1")
    func canSaveDraftRejectsBadQuorum() async {
        let (store, _) = await makeStore()
        store.draftQuorum = 0
        #expect(store.canSaveDraft == false)
        store.draftQuorum = nil
        #expect(store.canSaveDraft)
        store.draftQuorum = 5
        #expect(store.canSaveDraft)
    }

    @Test("saveDraft success replaces rules and dismisses the sheet")
    func saveSuccess() async {
        let (store, mock) = await makeStore()
        let returned = GroupDecisionRules(
            groupId: groupId, defaultStyle: .unanimity, quorumMin: 5,
            notes: "Todo a favor", isDefault: false
        )
        await mock.setSetDecisionRulesStub(.success(returned))

        store.beginEditing()
        store.draftStyle = .unanimity
        store.draftQuorum = 5
        store.draftNotes = "Todo a favor"
        let ok = await store.saveDraft(groupId: groupId)

        #expect(ok)
        #expect(store.rules?.defaultStyle == .unanimity)
        #expect(store.rules?.quorumMin == 5)
        #expect(store.isEditPresented == false)
    }

    @Test("saveDraft failure surfaces error and keeps the sheet open")
    func saveFailure() async {
        let (store, mock) = await makeStore()
        await mock.setSetDecisionRulesStub(.failure(.backend(.lacksPermission(permission: "group.update", groupId: groupId))))

        store.beginEditing()
        store.draftStyle = .supermajority
        let ok = await store.saveDraft(groupId: groupId)

        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.isEditPresented)
    }

    @Test("saveDraft trims notes via the repository (no leading/trailing whitespace on the wire)")
    func saveDraftTrimsNotes() async {
        let (store, mock) = await makeStore()
        await mock.setSetDecisionRulesStub(.success(
            GroupDecisionRules(groupId: groupId, defaultStyle: .majority,
                               notes: "Limpio", isDefault: false)
        ))

        store.beginEditing()
        store.draftStyle = .majority
        store.draftNotes = "   Limpio  "
        _ = await store.saveDraft(groupId: groupId)

        let recorded = await mock.recorded
        let saw = recorded.contains { call in
            if case .setDecisionRules(let input) = call {
                return input.pNotes == "Limpio"
            }
            return false
        }
        #expect(saw)
    }
}
