import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("MandatesStore")
struct MandatesStoreTests {

    private let groupId = UUID()

    private func mandate(_ type: MandateType = .represent) -> GroupMandate {
        GroupMandate(
            id: UUID(),
            groupId: groupId,
            principalType: .group,
            representativeMembershipId: UUID(),
            representativeDisplayName: "Ana López",
            type: type
        )
    }

    private func makeStore(seed: [GroupMandate] = []) async -> (MandatesStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupMandatesActiveStub(.success(seed))
        let repo = CanonicalMandatesRepository(rpc: mock)
        return (MandatesStore(repository: repo), mock)
    }

    @Test("refresh loads mandates and lands on .loaded")
    func refreshHappyPath() async {
        let (store, _) = await makeStore(seed: [mandate(.represent), mandate(.speak)])
        await store.refresh(groupId: groupId)
        #expect(store.mandates.count == 2)
        #expect(store.phase == .loaded)
    }

    @Test("saveDraft sends representative + type via grant RPC")
    func saveDraftSubmits() async {
        let (store, mock) = await makeStore(seed: [])
        let repId = UUID()
        store.beginGranting(defaultRepresentative: repId)
        store.draftType = .sign
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isGrantPresented == false)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .grantMandate(let input) = call {
                return input.pGroupId == groupId
                    && input.pRepresentativeMembershipId == repId
                    && input.pMandateType == "sign"
                    && input.pPrincipalType == "group"
                    && input.pPrincipalId == nil
                    && input.pEndsAt == nil
            }
            return false
        })
    }

    @Test("saveDraft with no representative surfaces error and does not call backend")
    func saveDraftNoRepresentative() async {
        let (store, mock) = await makeStore(seed: [])
        store.beginGranting()
        store.draftRepresentativeMembershipId = nil
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        let recorded = await mock.recorded
        let grantCalls = recorded.filter { if case .grantMandate = $0 { return true } else { return false } }
        #expect(grantCalls.isEmpty)
    }

    @Test("saveDraft with past ends_at surfaces error")
    func saveDraftPastEndsAt() async {
        let (store, _) = await makeStore(seed: [])
        store.beginGranting(defaultRepresentative: UUID())
        store.draftHasEndDate = true
        store.draftEndsAt = Date().addingTimeInterval(-3600)
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
    }

    @Test("revoke removes mandate locally on success")
    func revokeRemovesLocally() async {
        let seed = mandate()
        let (store, _) = await makeStore(seed: [seed])
        await store.refresh(groupId: groupId)
        let ok = await store.revoke(mandateId: seed.id, reason: nil, groupId: groupId)
        #expect(ok)
        #expect(store.mandates.isEmpty)
    }

    @Test("refresh failure surfaces message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupMandatesActiveStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        let store = MandatesStore(repository: CanonicalMandatesRepository(rpc: mock))
        await store.refresh(groupId: groupId)
        #expect(store.errorMessage != nil)
        if case .failed = store.phase {} else { Issue.record("expected .failed phase") }
    }
}
