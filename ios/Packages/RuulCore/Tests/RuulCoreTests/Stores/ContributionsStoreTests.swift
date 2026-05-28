import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("ContributionsStore")
struct ContributionsStoreTests {

    private let groupId = UUID()

    private func contribution(
        _ type: ContributionType = .care,
        title: String? = "Algo",
        amount: Decimal? = nil,
        unit: String? = nil
    ) -> GroupContribution {
        GroupContribution(
            id: UUID(),
            groupId: groupId,
            membershipId: UUID(),
            type: type,
            amount: amount,
            unit: unit,
            title: title
        )
    }

    private func makeStore(seed: [GroupContribution] = []) async -> (ContributionsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupContributionsActiveStub(.success(seed))
        let repo = CanonicalContributionsRepository(rpc: mock)
        return (ContributionsStore(repository: repo), mock)
    }

    @Test("refresh loads contributions and lands on .loaded")
    func refreshHappyPath() async {
        let (store, _) = await makeStore(seed: [contribution(.care), contribution(.hosting)])
        await store.refresh(groupId: groupId)
        #expect(store.contributions.count == 2)
        #expect(store.phase == .loaded)
    }

    @Test("saveDraft sends trimmed title via log RPC")
    func saveDraftSubmits() async {
        let (store, mock) = await makeStore(seed: [])
        store.beginLogging(type: .hosting)
        store.draftTitle = "  Cena viernes  "
        store.draftDescription = ""
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isLogPresented == false)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .logContribution(let input) = call {
                return input.pGroupId == groupId
                    && input.pContributionType == "hosting"
                    && input.pTitle == "Cena viernes"
                    && input.pDescription == nil
                    && input.pAmount == nil
                    && input.pUnit == nil
            }
            return false
        })
    }

    @Test("saveDraft with title+description+amount+unit encodes all fields")
    func saveDraftFullForm() async {
        let (store, mock) = await makeStore(seed: [])
        store.beginLogging(type: .time)
        store.draftTitle = "Junta"
        store.draftDescription = "Tomé minutas"
        store.draftAmountText = "1.5"
        store.draftUnit = "horas"
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .logContribution(let input) = call {
                return input.pTitle == "Junta"
                    && input.pDescription == "Tomé minutas"
                    && input.pAmount == Decimal(string: "1.5")
                    && input.pUnit == "horas"
            }
            return false
        })
    }

    @Test("saveDraft with empty title and description surfaces error and does not call backend")
    func saveDraftEmptyHeadline() async {
        let (store, mock) = await makeStore(seed: [])
        store.beginLogging()
        store.draftTitle = "  "
        store.draftDescription = "   "
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        let recorded = await mock.recorded
        let calls = recorded.filter { if case .logContribution = $0 { return true } else { return false } }
        #expect(calls.isEmpty)
    }

    @Test("saveDraft rejects amount without unit")
    func saveDraftAmountOnly() async {
        let (store, _) = await makeStore(seed: [])
        store.beginLogging()
        store.draftTitle = "X"
        store.draftAmountText = "5"
        store.draftUnit = ""
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
    }

    @Test("saveDraft rejects negative amount")
    func saveDraftNegativeAmount() async {
        let (store, _) = await makeStore(seed: [])
        store.beginLogging()
        store.draftTitle = "X"
        store.draftAmountText = "-5"
        store.draftUnit = "h"
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
    }

    @Test("refresh failure surfaces message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupContributionsActiveStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        let store = ContributionsStore(repository: CanonicalContributionsRepository(rpc: mock))
        await store.refresh(groupId: groupId)
        #expect(store.errorMessage != nil)
        if case .failed = store.phase {} else { Issue.record("expected .failed phase") }
    }
}
