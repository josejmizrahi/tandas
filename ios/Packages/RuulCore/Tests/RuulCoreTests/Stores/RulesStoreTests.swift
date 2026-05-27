import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("RulesStore")
struct RulesStoreTests {

    private let groupId = UUID()

    private func rule(_ title: String, severity: Int = 1, type: GroupRuleType = .norm) -> GroupRule {
        GroupRule(
            id: UUID(), currentVersionId: UUID(), groupId: groupId,
            title: title, body: "body", ruleType: type, severity: severity,
            executionMode: .text, status: "active"
        )
    }

    private func makeStore(seed: [GroupRule]) async -> (RulesStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupRulesActiveStub(.success(seed))
        let repo = CanonicalRulesRepository(rpc: mock)
        return (RulesStore(repository: repo), mock)
    }

    @Test("refresh loads rules and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [rule("A")])
        await store.refresh(groupId: groupId)
        #expect(store.rules.count == 1)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupRulesActive(groupId: groupId)))
    }

    @Test("createDraft rejects empty title")
    func rejectsEmptyTitle() async {
        let (store, _) = await makeStore(seed: [])
        store.beginCreating()
        store.draftTitle = "  "
        store.draftBody = "Some body"
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.isCreatePresented)
    }

    @Test("createDraft rejects empty body")
    func rejectsEmptyBody() async {
        let (store, _) = await makeStore(seed: [])
        store.beginCreating()
        store.draftTitle = "Title"
        store.draftBody = "   "
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
    }

    @Test("createDraft rejects invalid severity")
    func rejectsInvalidSeverity() async {
        let (store, _) = await makeStore(seed: [])
        store.beginCreating()
        store.draftTitle = "Title"
        store.draftBody = "Body"
        store.draftSeverity = 9
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok == false)
    }

    @Test("createDraft success refreshes and dismisses sheet")
    func createSuccess() async {
        let (store, mock) = await makeStore(seed: [])
        await mock.setCreateTextRuleStub(.success(.init(ruleId: UUID(), versionId: UUID())))
        await mock.setGroupRulesActiveStub(.success([rule("Created")]))

        store.beginCreating()
        store.draftTitle = "Created"
        store.draftBody = "Body"
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isCreatePresented == false)
        #expect(store.rules.count == 1)
    }

    @Test("archive removes rule locally on success")
    func archiveRemoves() async {
        let toArchive = rule("Archive me")
        let (store, mock) = await makeStore(seed: [toArchive])
        await mock.setArchiveRuleStub(.success(()))
        await store.refresh(groupId: groupId)

        let ok = await store.archive(ruleId: toArchive.id, reason: nil, groupId: groupId)
        #expect(ok)
        #expect(store.rules.isEmpty)
        let recorded = await mock.recorded
        #expect(recorded.contains(.archiveRule(input: ArchiveRuleInput(pRuleId: toArchive.id, pReason: nil))))
    }

    @Test("topRules returns first 3 sorted by backend order")
    func topRulesLimit() async {
        let seed = [rule("A", severity: 3), rule("B", severity: 2),
                    rule("C", severity: 2), rule("D", severity: 1)]
        let (store, _) = await makeStore(seed: seed)
        await store.refresh(groupId: groupId)
        #expect(store.topRules.count == 3)
    }
}
