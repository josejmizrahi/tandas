import Foundation
import Testing
@testable import RuulCore

@Suite("CurrentGroupStore")
struct CurrentGroupStoreTests {

    private func makeItem(id: UUID = UUID()) -> GroupListItem {
        GroupListItem(id: id, name: "G", slug: nil, category: nil, purposeSummary: nil, membershipId: UUID())
    }

    @Test("setGroup triggers a summary fetch and exposes myMembershipId")
    @MainActor
    func setGroupHappyPath() async throws {
        let mock = MockRuulRPCClient()
        let groupId = UUID()
        let summary = CanonicalGroupSummary(
            groupId: groupId,
            memberCount: 4,
            openDecisions: 1,
            openDisputes: 0,
            openObligations: 2,
            recentEvents: []
        )
        await mock.setGroupSummaryStub(.success(summary))
        let store = CurrentGroupStore(repository: CanonicalGroupRepository(rpc: mock))

        let item = makeItem(id: groupId)
        await store.setGroup(item)

        #expect(store.group == item)
        #expect(store.summary == summary)
        #expect(store.phase == .loaded)
        #expect(store.myMembershipId == item.membershipId)
    }

    @Test("setGroup(nil) clears state without fetching")
    @MainActor
    func setGroupNilClears() async throws {
        let mock = MockRuulRPCClient()
        let store = CurrentGroupStore(repository: CanonicalGroupRepository(rpc: mock))

        await store.setGroup(nil)
        #expect(store.group == nil)
        #expect(store.summary == nil)
        #expect(store.phase == .idle)
        #expect(store.myMembershipId == nil)

        let calls = await mock.recorded
        #expect(calls.isEmpty)
    }

    @Test("refresh after setGroup re-fetches the summary")
    @MainActor
    func refreshReusesSelection() async throws {
        let mock = MockRuulRPCClient()
        let groupId = UUID()
        let first = CanonicalGroupSummary(groupId: groupId, memberCount: 1, openDecisions: 0, openDisputes: 0, openObligations: 0, recentEvents: [])
        let second = CanonicalGroupSummary(groupId: groupId, memberCount: 2, openDecisions: 0, openDisputes: 0, openObligations: 0, recentEvents: [])
        await mock.setGroupSummaryStub(.success(first))
        let store = CurrentGroupStore(repository: CanonicalGroupRepository(rpc: mock))
        await store.setGroup(makeItem(id: groupId))
        #expect(store.summary?.memberCount == 1)

        await mock.setGroupSummaryStub(.success(second))
        await store.refresh()
        #expect(store.summary?.memberCount == 2)
    }

    @Test("summary fetch failure flips phase to .failed and clears stale summary")
    @MainActor
    func failurePath() async throws {
        let mock = MockRuulRPCClient()
        await mock.setGroupSummaryStub(.failure(.backend(.callerNotActiveMember(groupId: nil))))
        let store = CurrentGroupStore(repository: CanonicalGroupRepository(rpc: mock))

        await store.setGroup(makeItem())
        #expect(store.summary == nil)
        #expect(store.phase.failureMessage != nil)
    }
}
