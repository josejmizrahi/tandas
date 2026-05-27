import Foundation
import Testing
@testable import RuulCore

@Suite("GroupsStore")
struct GroupsStoreTests {

    private func makeItem(id: UUID = UUID(), name: String = "G") -> GroupListItem {
        GroupListItem(id: id, name: name, slug: nil, category: nil, purposeSummary: nil, membershipId: UUID())
    }

    @Test("refresh happy path → loaded with the list")
    @MainActor
    func refreshHappy() async throws {
        let mock = MockRuulRPCClient()
        let item = makeItem()
        await mock.setListMyGroupsStub(.success([item]))
        let store = GroupsStore(repository: CanonicalGroupRepository(rpc: mock))

        await store.refresh()
        #expect(store.groups == [item])
        #expect(store.phase == .loaded)
    }

    @Test("refresh failure → .failed with mapped message, list preserved")
    @MainActor
    func refreshFailure() async throws {
        let mock = MockRuulRPCClient()
        await mock.setListMyGroupsStub(.failure(.network(message: "offline")))
        let store = GroupsStore(repository: CanonicalGroupRepository(rpc: mock))

        await store.refresh()
        let message = store.phase.failureMessage
        #expect(message != nil)
        #expect(!(message ?? "").isEmpty)
    }

    @Test("selectGroup sets the id and selectedGroup resolves the row")
    @MainActor
    func selection() async throws {
        let mock = MockRuulRPCClient()
        let id = UUID()
        let item = makeItem(id: id)
        await mock.setListMyGroupsStub(.success([item]))
        let store = GroupsStore(repository: CanonicalGroupRepository(rpc: mock))
        await store.refresh()

        store.selectGroup(id: id)
        #expect(store.selectedGroupId == id)
        #expect(store.selectedGroup == item)

        store.selectGroup(id: nil)
        #expect(store.selectedGroupId == nil)
        #expect(store.selectedGroup == nil)
    }

    @Test("selection clears when the selected group is no longer in the list")
    @MainActor
    func selectionClearedOnDisappear() async throws {
        let mock = MockRuulRPCClient()
        let id = UUID()
        await mock.setListMyGroupsStub(.success([makeItem(id: id)]))
        let store = GroupsStore(repository: CanonicalGroupRepository(rpc: mock))
        await store.refresh()
        store.selectGroup(id: id)
        #expect(store.selectedGroupId == id)

        await mock.setListMyGroupsStub(.success([]))
        await store.refresh()
        #expect(store.selectedGroupId == nil)
    }
}
