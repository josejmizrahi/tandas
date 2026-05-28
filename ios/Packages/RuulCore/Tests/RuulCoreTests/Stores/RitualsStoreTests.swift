import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("RitualsStore")
struct RitualsStoreTests {

    private let groupId = UUID()

    private func ritual(_ kind: RitualMarkerKind = .weeklyMeeting) -> GroupResourceSeries {
        GroupResourceSeries(
            id: UUID(), groupId: groupId,
            cadence: .weekly,
            ritualMeaning: "Cena de los jueves",
            ritualMarkerKind: kind
        )
    }

    private func makeStore(seed: [GroupResourceSeries] = []) async -> (RitualsStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setListGroupResourceSeriesStub(.success(seed))
        let repo = CanonicalRitualsRepository(rpc: mock)
        return (RitualsStore(repository: repo), mock)
    }

    @Test("refresh loads rituals and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [ritual(), ritual(.celebration)])
        await store.refresh(groupId: groupId)
        #expect(store.rituals.count == 2)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .listGroupResourceSeries(let gid, let only, let past) = call {
                return gid == groupId && only && past == false
            }
            return false
        })
    }

    @Test("saveCreateDraft sends create_resource_series with trimmed meaning")
    func saveCreateDraftSubmits() async {
        let (store, mock) = await makeStore()
        store.beginCreating()
        store.createDraftMarker = .celebration
        store.createDraftCadence = .yearly
        store.createDraftMeaning = "  Cumpleaños del grupo  "
        let ok = await store.saveCreateDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isCreatePresented == false)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .createResourceSeries(let input) = call {
                return input.pGroupId == groupId
                    && input.pCadence == "yearly"
                    && input.pRitualMarkerKind == "celebration"
                    && input.pRitualMeaning == "Cumpleaños del grupo"
            }
            return false
        })
    }

    @Test("saveCreateDraft rejects empty meaning")
    func saveCreateDraftEmpty() async {
        let (store, _) = await makeStore()
        store.beginCreating()
        store.createDraftMeaning = "   "
        let ok = await store.saveCreateDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.createDraftErrorMessage != nil)
    }

    @Test("saveCreateDraft rejects ends_on at or before starts_on")
    func saveCreateDraftBadDateRange() async {
        let (store, _) = await makeStore()
        store.beginCreating()
        store.createDraftMeaning = "X"
        let start = Date()
        store.createDraftStartsOn = start
        store.createDraftHasEndDate = true
        store.createDraftEndsOn = start  // equal — not strictly after
        let ok = await store.saveCreateDraft(groupId: groupId)
        #expect(ok == false)
    }

    @Test("saveEditDraft updates the ritual annotation")
    func saveEditDraftUpdates() async {
        let existing = ritual(.weeklyMeeting)
        let (store, mock) = await makeStore(seed: [existing])
        await store.refresh(groupId: groupId)
        store.beginEditing(existing)
        store.editDraftMarker = .retrospective
        store.editDraftMeaning = "Nueva intención"
        let ok = await store.saveEditDraft(groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .updateResourceSeries(let input) = call {
                return input.pSeriesId == existing.id
                    && input.pRitualMarkerKind == "retrospective"
                    && input.pRitualMeaning == "Nueva intención"
            }
            return false
        })
    }

    @Test("endRitual sends update with non-nil ends_on")
    func endRitualSubmits() async {
        let existing = ritual()
        let (store, mock) = await makeStore(seed: [existing])
        let ok = await store.endRitual(existing.id, groupId: groupId)
        #expect(ok)
        let recorded = await mock.recorded
        #expect(recorded.contains { call in
            if case .updateResourceSeries(let input) = call {
                return input.pSeriesId == existing.id && input.pEndsOn != nil
            }
            return false
        })
    }
}
