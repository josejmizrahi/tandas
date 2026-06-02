import Foundation
import Testing
@testable import RuulCore

@Suite("R.1A — CurrentContextStore")
struct CurrentContextStoreTests {

    // MARK: - Helpers

    private func makeDefaults(_ suiteName: String = "ruul.tests.\(UUID().uuidString)") -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSummary(
        actorId: UUID,
        actorDisplayName: String = "José",
        groups: [(id: UUID, name: String, kind: String?)] = [],
        controlled: [(actorId: UUID, displayName: String?, actorKind: String?, relType: String)] = []
    ) throws -> MyWorldSummary {
        let groupsJSON = groups.map {
            """
            {"group_id":"\($0.id.uuidString)","name":"\($0.name)","membership_type":\($0.kind.map { "\"\($0)\"" } ?? "null"),"joined_via":null}
            """
        }.joined(separator: ",")
        let controlledJSON = controlled.map {
            let nameJSON = $0.displayName.map { "\"\($0)\"" } ?? "null"
            let kindJSON = $0.actorKind.map { "\"\($0)\"" } ?? "null"
            return """
            {"actor_id":"\($0.actorId.uuidString)","display_name":\(nameJSON),"actor_kind":\(kindJSON),"relationship_type":"\($0.relType)","metadata":null}
            """
        }.joined(separator: ",")
        let json = """
        {
          "actor": {"id":"\(actorId.uuidString)","actor_kind":"person","display_name":"\(actorDisplayName)","metadata":null},
          "groups": [\(groupsJSON)],
          "controlled_entities": [\(controlledJSON)]
        }
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(MyWorldSummary.self, from: Data(json.utf8))
    }

    // MARK: - buildContexts (pure mapping)

    @Test("buildContexts emits a single person context from summary.actor")
    func buildPersonOnly() throws {
        let actorId = UUID()
        let summary = try makeSummary(actorId: actorId, actorDisplayName: "José Mizrahi")

        let contexts = CurrentContextStore.buildContexts(from: summary)
        #expect(contexts.count == 1)
        #expect(contexts[0].kind == .person)
        #expect(contexts[0].id == actorId)
        #expect(contexts[0].displayName == "José Mizrahi")
    }

    @Test("buildContexts preserves group order from summary.groups")
    func buildPersonPlusGroups() throws {
        let actorId = UUID()
        let g1 = UUID()
        let g2 = UUID()
        let summary = try makeSummary(
            actorId: actorId,
            groups: [
                (g1, "Cenas Sábado", "admin"),
                (g2, "Casa del lago", nil),
            ]
        )

        let contexts = CurrentContextStore.buildContexts(from: summary)
        #expect(contexts.count == 3)
        #expect(contexts[0].kind == .person)
        #expect(contexts[1].kind == .group)
        #expect(contexts[1].id == g1)
        #expect(contexts[1].subtitle == "Admin")
        #expect(contexts[2].kind == .group)
        #expect(contexts[2].id == g2)
        #expect(contexts[2].subtitle == nil)
    }

    @Test("buildContexts silently omits controlled_entities of kind person/group")
    func buildSkipsPersonAndGroupControlled() throws {
        let actorId = UUID()
        let summary = try makeSummary(
            actorId: actorId,
            controlled: [
                (UUID(), "Otra persona", "person",       "trustee_of"),
                (UUID(), "Otro grupo",   "group",        "admin_of"),
                (UUID(), "Quimibond",    "legal_entity", "shareholder_of"),
            ]
        )

        let contexts = CurrentContextStore.buildContexts(from: summary)
        #expect(contexts.count == 2)
        let legal = contexts.last!
        #expect(legal.kind == .legalEntity)
        #expect(legal.displayName == "Quimibond")
        #expect(legal.subtitle == "Shareholder_of")
    }

    @Test("buildContexts silently omits controlled_entities without a display name")
    func buildSkipsEmptyDisplayName() throws {
        let actorId = UUID()
        let summary = try makeSummary(
            actorId: actorId,
            controlled: [
                (UUID(), nil,    "legal_entity", "shareholder_of"),
                (UUID(), "   ",  "legal_entity", "shareholder_of"),
                (UUID(), "Trust", "legal_entity", "trustee_of"),
            ]
        )

        let contexts = CurrentContextStore.buildContexts(from: summary)
        #expect(contexts.count == 2)
        #expect(contexts.last!.displayName == "Trust")
    }

    // MARK: - switchTo + persistence

    @Test("switchTo only accepts contexts in availableContexts and persists id+kind")
    @MainActor
    func switchToPersists() {
        let defaults = makeDefaults()
        let person = AppContext(id: UUID(), kind: .person, displayName: "José")
        let group = AppContext(id: UUID(), kind: .group, displayName: "Cenas")
        let store = CurrentContextStore(previewContexts: [person, group], current: person, defaults: defaults)

        store.switchTo(group)
        #expect(store.currentContext == group)
        #expect(defaults.string(forKey: CurrentContextStore.persistedIdKey) == group.id.uuidString)
        #expect(defaults.string(forKey: CurrentContextStore.persistedKindKey) == "group")
    }

    @Test("switchTo ignores contexts not in availableContexts")
    @MainActor
    func switchToRejectsUnknown() {
        let defaults = makeDefaults()
        let person = AppContext(id: UUID(), kind: .person, displayName: "José")
        let stranger = AppContext(id: UUID(), kind: .group, displayName: "Stranger")
        let store = CurrentContextStore(previewContexts: [person], current: person, defaults: defaults)

        store.switchTo(stranger)
        #expect(store.currentContext == person)
        #expect(defaults.string(forKey: CurrentContextStore.persistedIdKey) == nil)
    }

    // MARK: - restorePersistedContext + fallback

    @Test("restorePersistedContext resolves the persisted id+kind to the matching available context")
    @MainActor
    func restoreFindsPersisted() {
        let defaults = makeDefaults()
        let person = AppContext(id: UUID(), kind: .person, displayName: "José")
        let group = AppContext(id: UUID(), kind: .group, displayName: "Cenas")
        defaults.set(group.id.uuidString, forKey: CurrentContextStore.persistedIdKey)
        defaults.set("group",             forKey: CurrentContextStore.persistedKindKey)
        let store = CurrentContextStore(previewContexts: [person, group], current: nil, defaults: defaults)

        store.restorePersistedContext()
        #expect(store.currentContext == group)
    }

    @Test("restorePersistedContext falls back to person when persisted entry no longer exists")
    @MainActor
    func restoreFallsBackWhenMissing() {
        let defaults = makeDefaults()
        let person = AppContext(id: UUID(), kind: .person, displayName: "José")
        defaults.set(UUID().uuidString, forKey: CurrentContextStore.persistedIdKey)
        defaults.set("group",           forKey: CurrentContextStore.persistedKindKey)
        let store = CurrentContextStore(previewContexts: [person], current: nil, defaults: defaults)

        store.restorePersistedContext()
        #expect(store.currentContext == person)
    }

    @Test("fallbackToPersonContext picks the first person from availableContexts")
    @MainActor
    func fallback() {
        let defaults = makeDefaults()
        let person = AppContext(id: UUID(), kind: .person, displayName: "José")
        let group = AppContext(id: UUID(), kind: .group, displayName: "Cenas")
        let store = CurrentContextStore(previewContexts: [group, person], current: nil, defaults: defaults)

        store.fallbackToPersonContext()
        #expect(store.currentContext == person)
    }

    // MARK: - load() end-to-end

    @Test("load hydrates availableContexts from my_world_summary and falls back to person when no persistence")
    @MainActor
    func loadHydratesAndFalls() async throws {
        let actorId = UUID()
        let summary = try makeSummary(
            actorId: actorId,
            groups: [(UUID(), "Cenas", "member")]
        )
        let mock = MockRuulRPCClient()
        await mock.setMyWorldSummaryStub(.success(summary))
        let store = CurrentContextStore(
            repository: CanonicalMyWorldRepository(rpc: mock),
            defaults: makeDefaults()
        )

        await store.load()
        #expect(store.phase == .loaded)
        #expect(store.availableContexts.count == 2)
        #expect(store.currentContext?.kind == .person)
        #expect(store.currentContext?.id == actorId)
    }

    @Test("load restores persisted context when it survives the refresh")
    @MainActor
    func loadRestoresPersisted() async throws {
        let actorId = UUID()
        let groupId = UUID()
        let summary = try makeSummary(
            actorId: actorId,
            groups: [(groupId, "Cenas", "admin")]
        )
        let defaults = makeDefaults()
        defaults.set(groupId.uuidString, forKey: CurrentContextStore.persistedIdKey)
        defaults.set("group",            forKey: CurrentContextStore.persistedKindKey)
        let mock = MockRuulRPCClient()
        await mock.setMyWorldSummaryStub(.success(summary))
        let store = CurrentContextStore(
            repository: CanonicalMyWorldRepository(rpc: mock),
            defaults: defaults
        )

        await store.load()
        #expect(store.currentContext?.kind == .group)
        #expect(store.currentContext?.id == groupId)
    }

    @Test("load failure surfaces errorMessage and flips phase to .failed")
    @MainActor
    func loadFailure() async throws {
        let mock = MockRuulRPCClient()
        await mock.setMyWorldSummaryStub(.failure(.network(message: "off")))
        let store = CurrentContextStore(
            repository: CanonicalMyWorldRepository(rpc: mock),
            defaults: makeDefaults()
        )

        await store.load()
        #expect(store.phase.failureMessage != nil)
        #expect(store.availableContexts.isEmpty)
    }

    @Test("reset clears state and wipes the persisted selection")
    @MainActor
    func resetClears() {
        let defaults = makeDefaults()
        let person = AppContext(id: UUID(), kind: .person, displayName: "José")
        let store = CurrentContextStore(previewContexts: [person], current: person, defaults: defaults)
        store.persistCurrentContext()
        #expect(defaults.string(forKey: CurrentContextStore.persistedIdKey) != nil)

        store.reset()
        #expect(store.currentContext == nil)
        #expect(store.availableContexts.isEmpty)
        #expect(store.phase == .idle)
        #expect(defaults.string(forKey: CurrentContextStore.persistedIdKey) == nil)
    }
}
