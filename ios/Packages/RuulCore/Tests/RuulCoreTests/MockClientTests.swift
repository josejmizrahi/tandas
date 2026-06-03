import Testing
import Foundation
@testable import RuulCore

/// Tests del mock client — validan que el mundo simulado se comporte como el
/// backend en los happy paths que las vistas y stores asumen.
@Suite("MockRuulRPCClient")
struct MockClientTests {

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

    @Test("el mundo demo tiene los contextos del founder")
    func demoWorld() async throws {
        let mock = await makeDemoClient()
        let candidates = try await mock.contextCandidates()
        let names = candidates.contexts.map(\.displayName)
        #expect(names.contains("Cena Semanal"))
        #expect(names.contains("Familia Mizrahi"))
        // persona + 2 colectivos
        #expect(candidates.appContexts.count == 3)
    }

    @Test("crear contexto + invitar + unirse")
    func createInviteJoin() async throws {
        let mock = await makeDemoClient()
        let created = try await mock.createContext(CreateContextInput(displayName: "Viaje Japón", actorSubtype: "trip"))
        #expect(created.context.displayName == "Viaje Japón")

        let invite = try await mock.createInvite(contextId: created.contextActorId, maxUses: nil, expiresAt: nil)
        #expect(!invite.code.isEmpty)

        let join = try await mock.joinByInviteCode(invite.code.uppercased())
        #expect(join.contextActorId == created.contextActorId)

        // Código inválido → error de invite
        await #expect(throws: RuulError.self) {
            _ = try await mock.joinByInviteCode("no-existe")
        }
    }

    @Test("context_summary refleja members, rules y obligations del demo")
    func contextSummary() async throws {
        let mock = await makeDemoClient()
        let summary = try await mock.contextSummary(contextId: MockRuulRPCClient.DemoIds.cenaSemanal)
        #expect(summary.membersCount == 5)
        #expect(summary.activeRules.count == 2)
        // David es acreedor de 3 obligations de $325
        #expect(summary.money.openObligations.count == 3)
        // José debe $325 → balance negativo
        #expect(summary.money.myBalance == -325)
    }

    @Test("Casa Valle visible en Familia (GOVERN/OWN) y en mi mundo por USE")
    func casaValleVisibility() async throws {
        let mock = await makeDemoClient()
        let familiaResources = try await mock.listContextResources(contextId: MockRuulRPCClient.DemoIds.familia)
        #expect(familiaResources.contains { $0.displayName == "Casa Valle" })

        let world = try await mock.myWorld()
        let casa = world.resources.first { $0.displayName == "Casa Valle" }
        #expect(casa != nil)
        #expect(casa?.reasons.contains("USE") == true)
    }

    @Test("gasto con split equal excluye a Daniel y genera 3 obligations de $325")
    func expenseEqualSplit() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let result = try await mock.recordExpense(RecordExpenseInput(
            contextId: cena,
            amount: 1300,
            currency: "MXN",
            description: "Cena en el restaurante",
            excludedActorIds: [MockRuulRPCClient.DemoIds.daniel],
            paidByActorId: MockRuulRPCClient.DemoIds.david
        ))
        // 4 participantes (José, David, Isaac, Moisés) → 3 deudores (David pagó)
        #expect(result.obligations.count == 3)
        #expect(result.sharePerPerson == 325)
        #expect(!result.obligations.contains { $0.debtor == MockRuulRPCClient.DemoIds.daniel })
    }

    @Test("gasto custom debe sumar el total")
    func expenseCustomSplitValidation() async throws {
        let mock = await makeDemoClient()
        await #expect(throws: RuulError.self) {
            _ = try await mock.recordExpense(RecordExpenseInput(
                contextId: MockRuulRPCClient.DemoIds.cenaSemanal,
                amount: 1000,
                currency: "MXN",
                description: "No suma",
                splitMethod: "custom",
                splits: [
                    ExpenseSplit(actorId: MockRuulRPCClient.DemoIds.david, amount: 100),
                    ExpenseSplit(actorId: MockRuulRPCClient.DemoIds.isaac, amount: 100)
                ]
            ))
        }
    }

    @Test("settlement netea las obligations del demo")
    func settlement() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let result = try await mock.generateSettlementBatch(contextId: cena, currency: "MXN")
        // 3 deudores → máximo 3 transferencias hacia David
        #expect(result.batchId != nil)
        #expect(result.items.count == 3)
        #expect(result.items.allSatisfy { $0.to == MockRuulRPCClient.DemoIds.david })
        #expect(result.items.allSatisfy { $0.amount == 325 })

        // Marcar pagado el item de José cierra su obligation
        let items = try await mock.listSettlementItems(batchId: result.batchId!)
        let joseItem = items.first { $0.fromActorId == MockRuulRPCClient.DemoIds.jose }!
        let paid = try await mock.markSettlementPaid(itemId: joseItem.id)
        #expect(paid.obligationsClosed == 1)
        #expect(!paid.batchFinalized)

        // Idempotencia: marcar de nuevo no duplica
        let again = try await mock.markSettlementPaid(itemId: joseItem.id)
        #expect(again.alreadyPaid)
    }

    @Test("check-in tarde dispara la regla de multa")
    func lateCheckInTriggersFine() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal

        // Evento que empezó hace 30 minutos
        let event = try await mock.createCalendarEvent(CreateEventInput(
            contextId: cena,
            title: "Cena de prueba",
            eventType: .dinner,
            startsAt: Date().addingTimeInterval(-30 * 60)
        ))
        let result = try await mock.checkInParticipant(eventId: event.id, participantActorId: nil)
        #expect(result.isLate)

        // La regla "llegar tarde > 15 min → $100" generó la multa
        let obligations = try await mock.listObligations(contextId: cena)
        let fine = obligations.first { $0.obligationType == "fine" && $0.debtorActorId == MockRuulRPCClient.DemoIds.jose }
        #expect(fine != nil)
        #expect(fine?.amount == 100)
    }

    @Test("cerrar evento recurrente rota el host y crea la siguiente instancia")
    func closeRecurringEvent() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let events = try await mock.listEvents(contextId: cena)
        let dinner = events.first { $0.isRecurring }!

        let result = try await mock.closeEvent(eventId: dinner.id)
        #expect(result.nextEventId != nil)
        #expect(result.nextHostActorId != nil)
        #expect(result.nextHostActorId != dinner.hostActorId)

        let after = try await mock.listEvents(contextId: cena)
        #expect(after.contains { $0.id == result.nextEventId })
    }

    @Test("conflicto de reservación: detectar y resolver")
    func reservationConflict() async throws {
        let mock = await makeDemoClient()
        let casa = MockRuulRPCClient.DemoIds.casaValle
        let familia = MockRuulRPCClient.DemoIds.familia
        let weekend = Date().addingTimeInterval(7 * 86400)

        // David pide el fin de semana
        let first = try await mock.requestReservation(RequestReservationInput(
            resourceId: casa, contextId: familia,
            startsAt: weekend, endsAt: weekend.addingTimeInterval(2 * 86400),
            reservedForActorId: MockRuulRPCClient.DemoIds.david
        ))
        #expect(first.conflictsDetected == 0)

        // Isaac pide el mismo fin de semana → conflicto
        let second = try await mock.requestReservation(RequestReservationInput(
            resourceId: casa, contextId: familia,
            startsAt: weekend.addingTimeInterval(86400), endsAt: weekend.addingTimeInterval(3 * 86400),
            reservedForActorId: MockRuulRPCClient.DemoIds.isaac
        ))
        #expect(second.conflictsDetected == 1)

        // Resolver a favor de Isaac
        let conflicts = try await mock.listConflicts(resourceId: casa)
        #expect(conflicts.count == 1)
        try await mock.resolveReservationConflict(
            conflictId: conflicts[0].id,
            winnerReservationId: second.reservationId
        )
        let reservations = try await mock.listReservations(resourceId: casa)
        #expect(reservations.first { $0.id == second.reservationId }?.status == "approved")
        #expect(reservations.first { $0.id == first.reservationId }?.status == "rejected")
    }

    @Test("decisión: votar con mayoría aprueba y ejecutar cierra")
    func decisionLifecycle() async throws {
        let mock = await makeDemoClient()
        let familia = MockRuulRPCClient.DemoIds.familia

        let decision = try await mock.createDecision(CreateDecisionInput(
            contextId: familia,
            decisionType: .reservationDispute,
            title: "¿Quién se queda con Casa Valle este fin?"
        ))
        #expect(decision.isOpen)

        // Familia tiene 3 miembros → 2 approve = mayoría
        let vote1 = try await mock.voteDecision(decisionId: decision.id, vote: .approve, option: nil)
        #expect(vote1.status == "open")

        // Simular voto del segundo miembro: el mock vota como "me", así que
        // cerramos manualmente para verificar el cierre
        let closed = try await mock.closeDecision(decisionId: decision.id)
        #expect(closed.status == "approved")

        try await mock.executeDecision(decisionId: decision.id, result: nil)
        let decisions = try await mock.listDecisions(contextId: familia)
        #expect(decisions.first { $0.id == decision.id }?.isExecuted == true)
    }

    @Test("la actividad queda registrada por contexto sin mezclarse")
    func activityIsolation() async throws {
        let mock = await makeDemoClient()
        let cenaActivity = try await mock.listActivity(contextId: MockRuulRPCClient.DemoIds.cenaSemanal, limit: 50, before: nil)
        let familiaActivity = try await mock.listActivity(contextId: MockRuulRPCClient.DemoIds.familia, limit: 50, before: nil)
        #expect(!cenaActivity.isEmpty)
        #expect(!familiaActivity.isEmpty)
        // Cena tiene expense.recorded; Familia tiene resource.created — no se mezclan
        #expect(cenaActivity.contains { $0.eventType == "expense.recorded" })
        #expect(!familiaActivity.contains { $0.eventType == "expense.recorded" })
        #expect(familiaActivity.contains { $0.eventType == "resource.created" })
    }

    @Test("nextError se lanza una sola vez")
    func nextError() async throws {
        let mock = await makeDemoClient()
        await mock.setNextError(.network(message: "sin internet"))
        await #expect(throws: RuulError.self) {
            _ = try await mock.contextCandidates()
        }
        // La siguiente llamada ya funciona
        _ = try await mock.contextCandidates()
    }
}
