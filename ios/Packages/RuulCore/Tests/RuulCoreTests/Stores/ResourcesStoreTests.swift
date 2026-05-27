import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("ResourcesStore")
struct ResourcesStoreTests {

    private let groupId = UUID()

    private func resource(_ name: String, type: GroupResourceType = .other) -> GroupResource {
        GroupResource(id: UUID(), groupId: groupId, resourceType: type, name: name)
    }

    private func makeStore(seed: [GroupResource]) async -> (ResourcesStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupResourcesActiveStub(.success(seed))
        let repo = CanonicalResourcesRepository(rpc: mock)
        return (ResourcesStore(repository: repo), mock)
    }

    @Test("refresh loads resources and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [resource("Fund", type: .fund)])
        await store.refresh(groupId: groupId)
        #expect(store.resources.count == 1)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupResourcesActive(groupId: groupId)))
    }

    @Test("createDraft rejects empty name")
    func rejectsEmptyName() async {
        let (store, _) = await makeStore(seed: [])
        store.beginCreating()
        store.draftName = "  "
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.isCreatePresented)
    }

    @Test("createDraft success refetches and dismisses sheet")
    func createSuccess() async {
        let created = GroupResource(id: UUID(), groupId: groupId, resourceType: .fund, name: "Created")
        let (store, mock) = await makeStore(seed: [])
        await mock.setCreateGroupResourceStub(.success(created))
        // After create, store refreshes — return the created row.
        await mock.setGroupResourcesActiveStub(.success([created]))

        store.beginCreating(type: .fund)
        store.draftName = "Created"
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isCreatePresented == false)
        #expect(store.resources.count == 1)
        #expect(store.resources.first?.name == "Created")
    }

    @Test("createDraft failure surfaces backend error and keeps sheet open")
    func createFailure() async {
        let (store, mock) = await makeStore(seed: [])
        await mock.setCreateGroupResourceStub(.failure(.backend(.resourceNameRequired)))

        store.beginCreating()
        store.draftName = "Anything"
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.isCreatePresented)
    }

    @Test("archive removes resource locally on success")
    func archiveRemoves() async {
        let toRemove = resource("Archive me", type: .asset)
        let (store, mock) = await makeStore(seed: [toRemove, resource("Keep", type: .space)])
        await mock.setArchiveGroupResourceStub(.success(()))
        await store.refresh(groupId: groupId)

        let ok = await store.archive(resourceId: toRemove.id, reason: nil, groupId: groupId)
        #expect(ok)
        #expect(store.resources.contains(where: { $0.id == toRemove.id }) == false)
        #expect(store.resources.count == 1)
    }

    @Test("resourcesByType buckets correctly")
    func bucketsByType() async {
        let seed = [
            resource("F1", type: .fund), resource("F2", type: .fund),
            resource("S1", type: .space), resource("D1", type: .document)
        ]
        let (store, _) = await makeStore(seed: seed)
        await store.refresh(groupId: groupId)
        #expect(store.resourcesByType[.fund]?.count == 2)
        #expect(store.resourcesByType[.space]?.count == 1)
        #expect(store.resourcesByType[.document]?.count == 1)
        #expect(store.resourcesByType[.asset]?.count == nil)
    }
}
