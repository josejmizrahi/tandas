import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("CulturalNormsStore")
struct CulturalNormsStoreTests {

    private let groupId = UUID()

    private func norm(
        _ type: CulturalNormType = .value,
        status: CulturalNormStatus = .proposed,
        endorsedCount: Int = 0
    ) -> GroupCulturalNorm {
        GroupCulturalNorm(
            id: UUID(),
            groupId: groupId,
            type: type,
            title: "Norma",
            body: nil,
            visibility: .members,
            status: status,
            endorsedCount: endorsedCount
        )
    }

    private func makeStore(seed: [GroupCulturalNorm] = []) async -> (CulturalNormsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupCulturalNormsActiveStub(.success(seed))
        let repo = CanonicalCulturalNormsRepository(rpc: mock)
        return (CulturalNormsStore(repository: repo), mock)
    }

    @Test("refresh loads norms and lands on .loaded")
    func refreshHappyPath() async {
        let (store, _) = await makeStore(seed: [norm(.value), norm(.principle)])
        await store.refresh(groupId: groupId)
        #expect(store.norms.count == 2)
        #expect(store.phase == .loaded)
    }

    @Test("saveDraft sends trimmed title + body via propose RPC")
    func saveDraftSubmits() async {
        let (store, mock) = await makeStore(seed: [])
        store.beginCreating(type: .principle)
        store.draftTitle = "  Sin teléfonos  "
        store.draftBody  = "  en la mesa  "
        store.draftVisibility = .members
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isCreatePresented == false)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .proposeCulturalNorm(let input) = call {
                return input.pGroupId == groupId
                    && input.pNormType == "principle"
                    && input.pTitle == "Sin teléfonos"
                    && input.pBody == "en la mesa"
                    && input.pVisibility == "members"
            }
            return false
        })
    }

    @Test("saveDraft with empty title surfaces error and does not call backend")
    func saveDraftEmptyTitle() async {
        let (store, mock) = await makeStore(seed: [])
        store.beginCreating()
        store.draftTitle = "   "
        let ok = await store.saveDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        let recorded = await mock.recorded
        let proposeCalls = recorded.filter { if case .proposeCulturalNorm = $0 { return true } else { return false } }
        #expect(proposeCalls.isEmpty)
    }

    @Test("endorse patches local row count + status proposed → endorsed")
    func endorsePatchesLocal() async {
        let seedNorm = norm(.value, status: .proposed, endorsedCount: 0)
        let (store, mock) = await makeStore(seed: [seedNorm])
        await store.refresh(groupId: groupId)
        await mock.setEndorseCulturalNormStub(.success(1))

        let ok = await store.endorse(normId: seedNorm.id, groupId: groupId)
        #expect(ok)
        #expect(store.norms[0].endorsedCount == 1)
        #expect(store.norms[0].status == .endorsed)
    }

    @Test("retire removes the row locally on success")
    func retireRemovesLocally() async {
        let seedNorm = norm()
        let (store, _) = await makeStore(seed: [seedNorm])
        await store.refresh(groupId: groupId)
        let ok = await store.retire(normId: seedNorm.id, reason: nil, groupId: groupId)
        #expect(ok)
        #expect(store.norms.isEmpty)
    }

    @Test("promoteToRule removes the norm and returns the new rule id")
    func promoteToRuleHappy() async {
        let seedNorm = norm(.value, status: .endorsed, endorsedCount: 3)
        let (store, mock) = await makeStore(seed: [seedNorm])
        await store.refresh(groupId: groupId)

        let expectedRule = UUID()
        await mock.setPromoteNormToRuleStub(.success(
            PromoteNormToRuleResult(ruleId: expectedRule, versionId: UUID(), normId: seedNorm.id)
        ))

        let result = await store.promoteToRule(
            normId: seedNorm.id,
            ruleType: .principle,
            severity: 2,
            groupId: groupId
        )
        #expect(result?.ruleId == expectedRule)
        #expect(store.norms.isEmpty)

        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .promoteNormToRule(let input) = call {
                return input.pNormId == seedNorm.id
                    && input.pRuleType == "principle"
                    && input.pSeverity == 2
            }
            return false
        })
    }

    @Test("promoteToRule surfaces backend error and keeps the norm")
    func promoteToRuleError() async {
        let seedNorm = norm()
        let (store, mock) = await makeStore(seed: [seedNorm])
        await store.refresh(groupId: groupId)
        await mock.setPromoteNormToRuleStub(.failure(.backend(.lacksPermission(permission: "rules.create", groupId: groupId))))

        let result = await store.promoteToRule(
            normId: seedNorm.id,
            ruleType: .norm,
            severity: 1,
            groupId: groupId
        )
        #expect(result == nil)
        #expect(store.norms.count == 1)
        #expect(store.errorMessage != nil)
    }

    @Test("refresh failure surfaces user-facing message and flips to .failed")
    func refreshFailure() async {
        let mock = MockRuulRPCClient()
        await mock.setGroupCulturalNormsActiveStub(.failure(.backend(.callerNotActiveMember(groupId: groupId))))
        let store = CulturalNormsStore(repository: CanonicalCulturalNormsRepository(rpc: mock))
        await store.refresh(groupId: groupId)
        #expect(store.errorMessage != nil)
        if case .failed = store.phase {} else { Issue.record("expected .failed phase") }
    }
}
