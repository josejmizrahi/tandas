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
        // persona + Cena Semanal + Familia + 3 hijos de Familia (Comidas,
        // Mundial, Proyecto) + Fideicomiso (hijo de Proyecto) = 7
        #expect(store.availableContexts.count == 7)
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

    // MARK: - ResourcesStore

    @Test("ResourcesStore: contexto personal usa my_world; colectivo usa list_context_resources")
    func resourcesStorePersonalVsCollective() async {
        let mock = await makeDemoClient()

        // Personal: "Todos los recursos" debe coincidir con el home (my_world),
        // no con list_context_resources(actor_persona).
        let personal = AppContext(
            id: MockRuulRPCClient.DemoIds.jose,
            kind: .person,
            subtype: "person",
            displayName: "José"
        )
        let personalStore = ResourcesStore(rpc: mock)
        await personalStore.load(context: personal)
        #expect(personalStore.resources.isEmpty)
        #expect(personalStore.personalResources.contains { $0.displayName == "Casa Valle" })

        // Colectivo: ruta clásica por list_context_resources.
        let familia = AppContext(
            id: MockRuulRPCClient.DemoIds.familia,
            kind: .collective,
            subtype: "family",
            displayName: "Familia Mizrahi"
        )
        let collectiveStore = ResourcesStore(rpc: mock)
        await collectiveStore.load(context: familia)
        #expect(collectiveStore.personalResources.isEmpty)
        #expect(collectiveStore.resources.contains { $0.displayName == "Casa Valle" })
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

    // MARK: - Resolución de nombres

    @Test("displayName resuelve 'Tú' cuando el actor no está en members")
    func displayNameFallbackToMe() async {
        let mock = await makeDemoClient()

        // Sin members cargados (p.ej. contexto personal): yo → "Tú", otro → "Alguien".
        let store = DecisionsStore(rpc: mock, myActorId: MockRuulRPCClient.DemoIds.jose)
        #expect(store.displayName(for: MockRuulRPCClient.DemoIds.jose) == "Tú")
        #expect(store.displayName(for: MockRuulRPCClient.DemoIds.david) == "Alguien")
        #expect(store.displayName(for: nil) == "—")

        // Con members cargados, el nombre real gana sobre "Tú".
        let cena = AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal",
            roles: ["admin"]
        )
        await store.load(context: cena)
        #expect(store.displayName(for: MockRuulRPCClient.DemoIds.jose) != "Tú")
        #expect(store.displayName(for: MockRuulRPCClient.DemoIds.jose) != "Alguien")
    }

    // MARK: - ReservationsStore

    @Test("ReservationsStore.reservations(covering:) cubre el rango y excluye canceladas")
    func reservationsCalendarCoverage() async {
        let mock = await makeDemoClient()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let active = Reservation(
            id: UUID(),
            resourceId: MockRuulRPCClient.DemoIds.casaValle,
            contextActorId: MockRuulRPCClient.DemoIds.familia,
            requestedByActorId: MockRuulRPCClient.DemoIds.david,
            startsAt: today.addingTimeInterval(1 * 86_400),
            endsAt: today.addingTimeInterval(3 * 86_400),
            status: "confirmed"
        )
        let cancelled = Reservation(
            id: UUID(),
            resourceId: MockRuulRPCClient.DemoIds.casaValle,
            contextActorId: MockRuulRPCClient.DemoIds.familia,
            requestedByActorId: MockRuulRPCClient.DemoIds.jose,
            startsAt: today.addingTimeInterval(1 * 86_400),
            endsAt: today.addingTimeInterval(3 * 86_400),
            status: "cancelled"
        )
        let store = ReservationsStore(rpc: mock, previewReservations: [active, cancelled])

        // Día dentro del rango → solo la activa (la cancelada no pinta).
        let midStay = store.reservations(covering: today.addingTimeInterval(86_400 + 3_600), calendar: calendar)
        #expect(midStay.count == 1)
        #expect(midStay.first?.id == active.id)

        // Hoy (antes del check-in) → libre.
        #expect(store.reservations(covering: today, calendar: calendar).isEmpty)

        // Último día completo de la estancia → cubierto.
        #expect(!store.reservations(covering: today.addingTimeInterval(2 * 86_400), calendar: calendar).isEmpty)

        // Día del checkout a las 00:00 → ya libre.
        #expect(store.reservations(covering: today.addingTimeInterval(3 * 86_400), calendar: calendar).isEmpty)
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

    // MARK: - ContextHierarchyStore (R.2U.3)

    @Test("ContextHierarchyStore carga children, parents y ancestors de la jerarquía Mizrahi")
    func contextHierarchyStore() async {
        let mock = await makeDemoClient()
        let store = ContextHierarchyStore(rpc: mock)

        // Familia Mizrahi = raíz: 3 children (Comidas, Mundial, Proyecto), 0 parents
        await store.load(contextId: MockRuulRPCClient.DemoIds.familia)
        #expect(store.phase == .loaded)
        #expect(store.parents.isEmpty)
        #expect(store.children.count == 3)
        #expect(store.children.contains { $0.id == MockRuulRPCClient.DemoIds.comidasMiercoles })
        #expect(store.children.contains { $0.id == MockRuulRPCClient.DemoIds.mundialPalco2026 })
        #expect(store.children.contains { $0.id == MockRuulRPCClient.DemoIds.proyectoNave })
        #expect(store.ancestors.isEmpty)

        // Fideicomiso = profundidad 2: 0 children, 1 parent (Proyecto), 2 ancestors
        await store.load(contextId: MockRuulRPCClient.DemoIds.fideicomiso)
        #expect(store.phase == .loaded)
        #expect(store.children.isEmpty)
        #expect(store.parents.count == 1)
        #expect(store.parents.first?.id == MockRuulRPCClient.DemoIds.proyectoNave)
        #expect(store.ancestors.count == 2)
        // Ancestor más profundo (raíz) = Familia con depth=2
        #expect(store.ancestors.contains { $0.id == MockRuulRPCClient.DemoIds.familia })
        #expect(store.ancestors.contains { $0.id == MockRuulRPCClient.DemoIds.proyectoNave })
    }

    @Test("ContextHierarchyStore.loadTree construye árbol completo desde la raíz")
    func contextHierarchyStoreTree() async {
        let mock = await makeDemoClient()
        let store = ContextHierarchyStore(rpc: mock)

        await store.loadTree(rootContextId: MockRuulRPCClient.DemoIds.familia)
        #expect(store.treePhase == .loaded)
        #expect(store.tree?.id == MockRuulRPCClient.DemoIds.familia)
        #expect(store.tree?.children?.count == 3)
        // Proyecto Nave debe contener a Fideicomiso (recursión).
        let proyecto = store.tree?.children?.first { $0.id == MockRuulRPCClient.DemoIds.proyectoNave }
        #expect(proyecto?.children?.count == 1)
        #expect(proyecto?.children?.first?.id == MockRuulRPCClient.DemoIds.fideicomiso)
    }

    @Test("createChildContext crea hijo + registra contains + emite activity")
    func createChildContextFlow() async throws {
        let mock = await makeDemoClient()
        let store = ContextHierarchyStore(rpc: mock)

        let result = try await mock.createChildContext(CreateChildContextInput(
            parentContextActorId: MockRuulRPCClient.DemoIds.familia,
            displayName: "Vacaciones Europa 2027",
            actorKind: .collective,
            actorSubtype: "trip"
        ))
        #expect(result.parentContextActorId == MockRuulRPCClient.DemoIds.familia)
        #expect(result.context.displayName == "Vacaciones Europa 2027")

        // El store ahora ve 4 children (Comidas, Mundial, Proyecto, Vacaciones)
        await store.load(contextId: MockRuulRPCClient.DemoIds.familia)
        #expect(store.children.count == 4)
        #expect(store.children.contains { $0.id == result.childContextActorId })
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
