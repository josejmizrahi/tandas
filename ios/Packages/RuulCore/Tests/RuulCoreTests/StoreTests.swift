import Testing
import Foundation
@testable import RuulCore

/// Tests de los stores @MainActor contra el mock client.
@Suite("Stores MVP2")
@MainActor
struct StoreTests {

    private func makeDemoClient() async -> MockRuulRPCClient {
        let jose = CurrentActor(
            actor: ActorRecord(
                id: MockRuulRPCClient.DemoIds.jose,
                actorKind: .person,
                actorSubtype: "person",
                displayName: "José"
            )
        )
        let mock = MockRuulRPCClient(me: jose)
        await mock.seedDemoWorld()
        return mock
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - CurrentActorStore

    @Test("CurrentActorStore carga el person actor")
    func currentActorLoads() async {
        let mock = await makeDemoClient()
        let store = CurrentActorStore(rpc: mock)
        await store.load()
        #expect(store.phase == .loaded)
        #expect(store.actorId == MockRuulRPCClient.DemoIds.jose)
    }

    @Test("CurrentActorStore expone el error")
    func currentActorFails() async {
        let mock = await makeDemoClient()
        await mock.setNextError(.network(message: "sin internet"))
        let store = CurrentActorStore(rpc: mock)
        await store.load()
        if case .failed = store.phase {
            // ok
        } else {
            Issue.record("Se esperaba .failed, fue \(store.phase)")
        }
    }

    // MARK: - ContextStore

    @Test("ContextStore carga contextos y selecciona el primer colectivo")
    func contextStoreLoads() async {
        let mock = await makeDemoClient()
        let store = ContextStore(rpc: mock, defaults: makeDefaults())
        await store.load()
        #expect(store.phase == .loaded)
        // persona + Cena Semanal + Familia
        #expect(store.availableContexts.count == 3)
        #expect(store.personalContext != nil)
        // El default es el primer colectivo (no el personal).
        #expect(store.currentContext?.isPersonal == false)
    }

    @Test("ContextStore persiste y restaura la selección")
    func contextStorePersistence() async {
        let mock = await makeDemoClient()
        let defaults = makeDefaults()

        let store = ContextStore(rpc: mock, defaults: defaults)
        await store.load()
        guard let familia = store.availableContexts.first(where: { $0.displayName == "Familia Mizrahi" }) else {
            Issue.record("No se encontró Familia Mizrahi")
            return
        }
        store.switchTo(familia)
        #expect(store.currentContext?.id == familia.id)

        // Un store nuevo (relanzamiento de app) restaura la misma selección.
        let secondStore = ContextStore(rpc: mock, defaults: defaults)
        await secondStore.load()
        #expect(secondStore.currentContext?.id == familia.id)
    }

    @Test("ContextStore.reset limpia selección y persistencia")
    func contextStoreReset() async {
        let mock = await makeDemoClient()
        let defaults = makeDefaults()
        let store = ContextStore(rpc: mock, defaults: defaults)
        await store.load()
        store.reset()
        #expect(store.currentContext == nil)
        #expect(store.availableContexts.isEmpty)
        #expect(defaults.string(forKey: ContextStore.persistedIdKey) == nil)
    }

    // MARK: - ContextHomeStore

    @Test("ContextHomeStore carga summary; para persona también my_world")
    func contextHomeLoads() async {
        let mock = await makeDemoClient()

        let cena = AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        )
        let collectiveStore = ContextHomeStore(rpc: mock)
        await collectiveStore.load(context: cena)
        #expect(collectiveStore.summary != nil)
        #expect(collectiveStore.world == nil)

        let personal = AppContext(
            id: MockRuulRPCClient.DemoIds.jose,
            kind: .person,
            subtype: "person",
            displayName: "José"
        )
        let personalStore = ContextHomeStore(rpc: mock)
        await personalStore.load(context: personal)
        #expect(personalStore.world != nil)
        // Casa Valle visible por USE en el mundo personal
        #expect(personalStore.world?.resources.contains { $0.displayName == "Casa Valle" } == true)
    }

    // MARK: - MembersStore

    @Test("MembersStore carga miembros y respeta permisos")
    func membersStore() async {
        let mock = await makeDemoClient()
        let cena = AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal",
            roles: ["admin"]
        )
        let store = MembersStore(rpc: mock)
        await store.load(context: cena)
        #expect(store.members.count == 5)
        #expect(store.canInvite(in: cena))
        #expect(store.canManageMembers(in: cena))

        // Remover a Daniel
        try? await store.removeMember(context: cena, memberActorId: MockRuulRPCClient.DemoIds.daniel, reason: nil)
        #expect(store.members.count == 4)
        #expect(!store.members.contains { $0.actorId == MockRuulRPCClient.DemoIds.daniel })
    }

    // MARK: - MoneyStore

    @Test("MoneyStore calcula balances desde obligations")
    func moneyBalances() async {
        let mock = await makeDemoClient()
        let cena = AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal",
            roles: ["admin"]
        )
        let store = MoneyStore(rpc: mock)
        await store.load(context: cena)

        // Demo: José/Isaac/Moisés deben $325 c/u a David
        #expect(store.openObligations.count == 3)
        #expect(store.balance(for: MockRuulRPCClient.DemoIds.david) == 975)
        #expect(store.balance(for: MockRuulRPCClient.DemoIds.jose) == -325)
        #expect(store.balance(for: MockRuulRPCClient.DemoIds.daniel) == 0)
    }

    // MARK: - SettlementStore

    @Test("SettlementStore genera batch y marca pagos")
    func settlementFlow() async {
        let mock = await makeDemoClient()
        let cena = AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal",
            roles: ["admin"]
        )
        let store = SettlementStore(rpc: mock)
        await store.load(context: cena)
        #expect(store.batches.isEmpty)

        let result = try? await store.generate(context: cena, currency: "MXN")
        #expect(result?.items.count == 3)
        #expect(store.batches.count == 1)

        // Marcar el pago de José
        if let batch = store.batches.first,
           let joseItem = store.items(for: batch.id).first(where: { $0.fromActorId == MockRuulRPCClient.DemoIds.jose }) {
            #expect(store.canMarkPaid(joseItem, context: cena, myActorId: MockRuulRPCClient.DemoIds.jose))
            let paid = try? await store.markPaid(itemId: joseItem.id, context: cena, myActorId: MockRuulRPCClient.DemoIds.jose)
            #expect(paid?.obligationsClosed == 1)
            // Tras recargar, el item aparece pagado
            if let updated = store.items(for: batch.id).first(where: { $0.id == joseItem.id }) {
                #expect(updated.isPaid)
                #expect(!store.canMarkPaid(updated, context: cena, myActorId: MockRuulRPCClient.DemoIds.jose))
            }
        } else {
            Issue.record("No se encontró el settlement item de José")
        }
    }

    // MARK: - ActivityStore

    @Test("ActivityStore carga el feed del contexto")
    func activityStore() async {
        let mock = await makeDemoClient()
        let cena = AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        )
        let store = ActivityStore(rpc: mock)
        await store.load(context: cena)
        #expect(store.phase == .loaded)
        #expect(!store.events.isEmpty)
        // Resolución de nombres: actor del contexto → nombre del contexto
        #expect(store.displayName(for: nil, contextId: cena.id, contextName: cena.displayName) == "Sistema")
    }
}
