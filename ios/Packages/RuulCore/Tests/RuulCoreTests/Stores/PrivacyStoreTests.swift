import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("PrivacyStore")
struct PrivacyStoreTests {

    private let groupId = UUID()

    private func makeStore(seed: String = "private") async -> (PrivacyStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupVisibilityStub(.success(seed))
        let repo = CanonicalPrivacyRepository(rpc: mock)
        return (PrivacyStore(repository: repo), mock)
    }

    @Test("refresh maps wire string to GroupVisibility enum")
    func refreshMapsEnum() async {
        let (store, _) = await makeStore(seed: "unlisted")
        await store.refresh(groupId: groupId)
        #expect(store.visibility == .unlisted)
        #expect(store.phase == .loaded)
    }

    @Test("setVisibility optimistic + persisted backend value wins")
    func setVisibilitySubmits() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupVisibilityStub(.success("private"))
        await mock.setSetGroupVisibilityStub(.success("public"))
        let store = PrivacyStore(repository: CanonicalPrivacyRepository(rpc: mock))
        await store.refresh(groupId: groupId)

        let ok = await store.setVisibility(.public, groupId: groupId)
        #expect(ok)
        #expect(store.visibility == .public)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .setGroupVisibility(let input) = call {
                return input.pGroupId == groupId && input.pVisibility == "public"
            }
            return false
        })
    }

    @Test("setVisibility reverts on backend failure")
    func setVisibilityReverts() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupVisibilityStub(.success("private"))
        await mock.setSetGroupVisibilityStub(.failure(.backend(.lacksPermission(permission: "group.update", groupId: groupId))))
        let store = PrivacyStore(repository: CanonicalPrivacyRepository(rpc: mock))
        await store.refresh(groupId: groupId)

        let ok = await store.setVisibility(.public, groupId: groupId)
        #expect(ok == false)
        #expect(store.visibility == .private)
        #expect(store.errorMessage != nil)
    }
}
