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

    @Test("el mundo demo siembra una invitación pendiente para José")
    func demoSeedsPendingInvitation() async throws {
        let mock = await makeDemoClient()
        let pending = try await mock.listMyPendingInvitations(actorId: MockRuulRPCClient.DemoIds.jose)
        #expect(pending.count == 1)
        #expect(pending.first?.contextDisplayName == "Viaje a Japón 2026")
    }

    @Test("accept_invitation activa la membresía y vacía la pendiente")
    func acceptPendingInvitation() async throws {
        let mock = await makeDemoClient()
        let result = try await mock.acceptInvitation(contextId: MockRuulRPCClient.DemoIds.viajeJapon)
        #expect(result.status == "active")
        #expect(result.alreadyMember == false)

        // Ya no debe quedar pendiente.
        let pending = try await mock.listMyPendingInvitations(actorId: MockRuulRPCClient.DemoIds.jose)
        #expect(pending.isEmpty)

        // Segunda llamada → already_member=true (idempotente).
        let again = try await mock.acceptInvitation(contextId: MockRuulRPCClient.DemoIds.viajeJapon)
        #expect(again.alreadyMember == true)
    }

    @Test("accept_invitation sin invitación previa lanza error")
    func acceptWithoutPendingFails() async throws {
        let mock = await makeDemoClient()
        // José ya es miembro activo de Cena Semanal → already_member=true, no error
        let result = try await mock.acceptInvitation(contextId: MockRuulRPCClient.DemoIds.cenaSemanal)
        #expect(result.alreadyMember == true)

        // Un contexto random sin invitación → error
        let randomContext = UUID()
        await #expect(throws: RuulError.self) {
            _ = try await mock.acceptInvitation(contextId: randomContext)
        }
    }

    @Test("invite_member crea una invitación pendiente para el invitado")
    func inviteMemberCreatesPending() async throws {
        let mock = await makeDemoClient()
        // José invita a Daniel a "Familia" (Daniel no es miembro de Familia).
        let result = try await mock.inviteMember(
            contextId: MockRuulRPCClient.DemoIds.familia,
            memberActorId: MockRuulRPCClient.DemoIds.daniel,
            membershipType: "member"
        )
        #expect(result.status == "invited")

        let pending = try await mock.listMyPendingInvitations(actorId: MockRuulRPCClient.DemoIds.daniel)
        #expect(pending.contains { $0.contextActorId == MockRuulRPCClient.DemoIds.familia })
    }

    @Test("invite_member es no-op si el actor ya es miembro activo")
    func inviteMemberIdempotent() async throws {
        let mock = await makeDemoClient()
        // Isaac ya es miembro activo de Familia.
        let result = try await mock.inviteMember(
            contextId: MockRuulRPCClient.DemoIds.familia,
            memberActorId: MockRuulRPCClient.DemoIds.isaac,
            membershipType: "member"
        )
        #expect(result.status == "active")

        // No debió crear pendiente.
        let pending = try await mock.listMyPendingInvitations(actorId: MockRuulRPCClient.DemoIds.isaac)
        #expect(!pending.contains { $0.contextActorId == MockRuulRPCClient.DemoIds.familia })
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

    @Test("R.2M-3: resourceDetail deriva capabilities + available_actions (casa reservable, no monetaria)")
    func resourceDetailCapabilitiesAndActions() async throws {
        let mock = await makeDemoClient()
        let detail = try await mock.resourceDetail(resourceId: MockRuulRPCClient.DemoIds.casaValle)
        // capabilities desde el tipo (house)
        #expect(detail.capabilities.contains("reservable"))
        #expect(!detail.capabilities.contains("monetary"))
        // available_actions desde capability ∩ rights (José tiene USE)
        #expect(detail.can("reserve_resource"))
        #expect(detail.can("view_reservations"))
        // affordance incorrecto eliminado: una casa NO ofrece movimientos
        #expect(!detail.can("record_expense"))
        #expect(!detail.actions(in: .reservations).isEmpty)
        #expect(detail.actions(in: .money).isEmpty)
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

    @Test("R.2Q — decision yes_no_abstain auto-seedea approve/reject/abstain")
    func yesNoAbstainAutoSeed() async throws {
        let mock = await makeDemoClient()
        let familia = MockRuulRPCClient.DemoIds.familia

        let decision = try await mock.createDecision(CreateDecisionInput(
            contextId: familia,
            decisionType: .expenseApproval,
            title: "Aprobar gasto"
        ))
        #expect(decision.voting == .yesNoAbstain)

        let options = try await mock.listDecisionOptions(decisionId: decision.id)
        #expect(options.count == 3)
        #expect(options.map(\.optionKey) == ["approve", "reject", "abstain"])

        guard let approve = options.first(where: { $0.optionKey == "approve" }) else {
            Issue.record("No approve option"); return
        }
        let result = try await mock.voteForOption(decisionId: decision.id, optionId: approve.id)
        #expect(result.myOptionId == approve.id)
    }

    @Test("R.2Q — single_choice con payload.options auto-seedea options de strings")
    func singleChoicePayloadOptionsAutoSeed() async throws {
        let mock = await makeDemoClient()
        let familia = MockRuulRPCClient.DemoIds.familia

        let decision = try await mock.createDecision(CreateDecisionInput(
            contextId: familia,
            decisionType: .generic,
            title: "¿Hotel A o Hotel B?",
            payload: .object(["options": .array([.string("Hotel A"), .string("Hotel B")])])
        ))
        #expect(decision.voting == .singleChoice)

        let options = try await mock.listDecisionOptions(decisionId: decision.id)
        #expect(options.count == 2)
        #expect(options.map(\.optionKey) == ["Hotel A", "Hotel B"])
    }

    @Test("R.2Q.4 — createDecision override votingModel + createDecisionOption manual")
    func createDecisionWithVotingModelOverride() async throws {
        let mock = await makeDemoClient()
        let familia = MockRuulRPCClient.DemoIds.familia

        let decision = try await mock.createDecision(CreateDecisionInput(
            contextId: familia,
            decisionType: .generic,
            title: "Elegir hotel",
            votingModel: .singleChoice
        ))
        #expect(decision.voting == .singleChoice)
        // single_choice sin payload.options ni conflict_id → sin opciones
        let initialOpts = try await mock.listDecisionOptions(decisionId: decision.id)
        #expect(initialOpts.isEmpty)

        // El usuario agrega 2 opciones a mano
        _ = try await mock.createDecisionOption(CreateDecisionOptionInput(
            decisionId: decision.id, optionKey: "hotel-a", title: "Hotel A"
        ))
        _ = try await mock.createDecisionOption(CreateDecisionOptionInput(
            decisionId: decision.id, optionKey: "hotel-b", title: "Hotel B"
        ))

        let opts = try await mock.listDecisionOptions(decisionId: decision.id)
        #expect(opts.count == 2)
        #expect(opts.map(\.sortOrder) == [0, 1])
    }

    @Test("DecisionOptionDraft.slugify")
    func decisionOptionDraftSlugify() {
        #expect(DecisionOptionDraft.slugify("Hotel A") == "hotel-a")
        #expect(DecisionOptionDraft.slugify("  Hotel A!  ") == "hotel-a")
        #expect(DecisionOptionDraft.slugify("Mar y Sol") == "mar-y-sol")
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

    // MARK: - Actor capabilities (R.2S.1)

    @Test("actor_capabilities devuelve la matriz del subtype")
    func actorCapabilitiesForCollective() async throws {
        let mock = await makeDemoClient()
        let caps = try await mock.actorCapabilities(actorId: MockRuulRPCClient.DemoIds.cenaSemanal)
        #expect(caps.actorKind == .collective)
        #expect(caps.actorSubtype == "friend_group")
        #expect(caps.has(.canHaveMembers))
        #expect(caps.has(.canHoldMoney))
        #expect(caps.has(.canIssueDecisions))
        // friend_group NO tiene beneficiarios ni trustees
        #expect(!caps.has(.canHaveBeneficiaries))
        #expect(!caps.has(.canHaveTrustees))
    }

    @Test("actor_can refleja la matriz del catálogo")
    func actorCanMirrorsCatalog() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        #expect(try await mock.actorCan(actorId: cena, capability: "can_hold_money"))
        #expect(!(try await mock.actorCan(actorId: cena, capability: "can_have_shareholders")))
    }

    @Test("actor_capabilities_catalog incluye todos los subtypes seed")
    func actorCapabilitiesCatalog() async throws {
        let mock = await makeDemoClient()
        let catalog = try await mock.actorCapabilitiesCatalog()
        let subtypeKeys = Set(catalog.subtypes.map(\.actorSubtype))
        #expect(subtypeKeys.contains("friend_group"))
        #expect(subtypeKeys.contains("trust"))
        #expect(subtypeKeys.contains("company"))
        // Trust tiene beneficiarios pero NO miembros
        let trustCaps = catalog.capabilities(forSubtype: "trust")
        #expect(trustCaps.contains("can_have_beneficiaries"))
        #expect(!trustCaps.contains("can_have_members"))
        // El catálogo de 12 capabilities tiene displayName en español
        #expect(catalog.displayName(for: "can_have_members") == "Puede tener miembros")
        // subtypes(with:) filtra correctamente
        #expect(catalog.subtypes(with: .canHaveTrustees) == ["trust"])
    }

    // MARK: - decision_detail / reservation_detail (R.2S.2)

    @Test("decision_detail trae available_actions canónicos (forma 7 campos)")
    func decisionDetailMock() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let created = try await mock.createDecision(CreateDecisionInput(
            contextId: cena,
            decisionType: .ruleChange,
            title: "Subir multa de tarde a $150"
        ))
        let detail = try await mock.decisionDetail(decisionId: created.id)
        #expect(detail.title == "Subir multa de tarde a $150")
        #expect(detail.status == "open")
        // Como founder/admin debería poder votar Y cerrar/cancelar la decisión
        #expect(detail.can("vote"))
        #expect(detail.can("close_decision"))
        // Forma canónica (7 campos)
        if let vote = detail.action("vote") {
            #expect(vote.section == "decisions")
            #expect(vote.enabled)
            #expect(vote.reason != nil)
        }
    }

    @Test("reservation_detail trae approve/reject habilitados para admin con MANAGE/OWN")
    func reservationDetailMock() async throws {
        let mock = await makeDemoClient()
        let casa = MockRuulRPCClient.DemoIds.casaValle
        let david = MockRuulRPCClient.DemoIds.david
        // David tiene USE en Casa Valle (demo seed). Pedir reservación.
        let result = try await mock.requestReservation(RequestReservationInput(
            resourceId: casa,
            contextId: MockRuulRPCClient.DemoIds.familia,
            startsAt: Date().addingTimeInterval(86_400 * 3),
            endsAt: Date().addingTimeInterval(86_400 * 5),
            reservedForActorId: david
        ))
        let detail = try await mock.reservationDetail(reservationId: result.reservationId)
        #expect(detail.status == "requested")
        // José (admin de Familia) puede aprobar
        #expect(detail.can("approve"))
        #expect(detail.can("reject"))
        // Forma canónica
        if let approve = detail.action("approve") {
            #expect(approve.section == "reservations")
            #expect(approve.actionKey == "approve")
            #expect(approve.reason != nil)
        }
    }

    // MARK: - Explanation engine (R.2S.10)

    @Test("why_can_view_resource — Casa Valle visible para José por OWN/USE")
    func whyCanViewResourceMock() async throws {
        let mock = await makeDemoClient()
        let casa = MockRuulRPCClient.DemoIds.casaValle
        let jose = MockRuulRPCClient.DemoIds.jose
        let why = try await mock.whyCanViewResource(actorId: jose, resourceId: casa)
        #expect(why.canView)
        #expect(!why.reasons.isEmpty)
    }

    @Test("why_can_reserve — Casa Valle (house) reservable para José que tiene USE")
    func whyCanReserveMock() async throws {
        let mock = await makeDemoClient()
        let casa = MockRuulRPCClient.DemoIds.casaValle
        let jose = MockRuulRPCClient.DemoIds.jose
        let why = try await mock.whyCanReserve(actorId: jose, resourceId: casa)
        #expect(why.canReserve)
        #expect(why.requiredCapability == "reservable")
        #expect(why.reasons.contains { $0.contains("reservable") })
    }

    @Test("why_decision_result — tally refleja votos emitidos")
    func whyDecisionResultMock() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let created = try await mock.createDecision(CreateDecisionInput(
            contextId: cena, decisionType: .ruleChange, title: "Subir multa de tarde"
        ))
        _ = try await mock.voteDecision(decisionId: created.id, vote: .approve, option: nil)
        let why = try await mock.whyDecisionResult(decisionId: created.id)
        #expect(why.tally.approve == 1)
        #expect(why.activeMembers > 0)
        #expect(why.reasons.contains { $0.contains("Modelo de votación") })
    }

    // MARK: - R.2R Obligations universales

    @Test("create_action_obligation crea obligación kind=action sin amount")
    func createActionObligationMock() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let david = MockRuulRPCClient.DemoIds.david
        let result = try await mock.createActionObligation(CreateActionObligationInput(
            contextId: cena,
            debtorActorId: david,
            title: "Traer botella de vino",
            kind: "action",
            description: "Para la cena del viernes"
        ))
        #expect(result.kind == "action")
        #expect(result.status == "open")

        // El listado de obligations incluye la nueva
        let all = try await mock.listObligations(contextId: cena)
        let created = all.first { $0.id == result.obligationId }
        #expect(created?.title == "Traer botella de vino")
        #expect(created?.isActionKind == true)
        #expect(created?.amount == nil)
    }

    @Test("create_action_obligation rechaza kind=money")
    func createActionObligationRejectsMoney() async throws {
        let mock = await makeDemoClient()
        await #expect(throws: RuulError.self) {
            _ = try await mock.createActionObligation(CreateActionObligationInput(
                contextId: MockRuulRPCClient.DemoIds.cenaSemanal,
                debtorActorId: MockRuulRPCClient.DemoIds.jose,
                title: "Esto no debería pasar",
                kind: "money"
            ))
        }
    }

    @Test("obligation_detail trae available_actions canónicos")
    func obligationDetailMock() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let created = try await mock.createActionObligation(CreateActionObligationInput(
            contextId: cena,
            debtorActorId: MockRuulRPCClient.DemoIds.jose,
            title: "Mandar minuta",
            kind: "document"
        ))
        let detail = try await mock.obligationDetail(obligationId: created.obligationId)
        #expect(detail.kind == "document")
        #expect(detail.title == "Mandar minuta")
        // José es debtor + miembro → puede mark_completed
        #expect(detail.can("mark_completed"))
        // No money kind → no `pay` action
        #expect(!detail.can("pay"))
    }

    @Test("complete_obligation cierra acción + idempotente")
    func completeObligationMock() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let created = try await mock.createActionObligation(CreateActionObligationInput(
            contextId: cena,
            debtorActorId: MockRuulRPCClient.DemoIds.jose,
            title: "Confirmar reserva",
            kind: "approval"
        ))
        let result = try await mock.completeObligation(
            obligationId: created.obligationId,
            completionNotes: "Confirmado por WhatsApp",
            completionMetadata: nil
        )
        #expect(result.status == "completed")
        #expect(!result.alreadyCompleted)

        let detail = try await mock.obligationDetail(obligationId: created.obligationId)
        #expect(detail.status == "completed")
        #expect(detail.completedAt != nil)
        #expect(detail.completionNotes == "Confirmado por WhatsApp")

        // Segunda llamada es idempotente
        let second = try await mock.completeObligation(
            obligationId: created.obligationId,
            completionNotes: nil,
            completionMetadata: nil
        )
        #expect(second.alreadyCompleted)
    }

    @Test("complete_obligation rechaza obligaciones de dinero")
    func completeObligationRejectsMoney() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        // record_fine crea una money obligation que NO se completa
        let obligationId = try await mock.recordFine(
            contextId: cena,
            debtorActorId: MockRuulRPCClient.DemoIds.jose,
            amount: 100,
            currency: "MXN",
            reason: nil
        )
        await #expect(throws: RuulError.self) {
            _ = try await mock.completeObligation(
                obligationId: obligationId,
                completionNotes: nil,
                completionMetadata: nil
            )
        }
    }

    // MARK: - F.1A-1 Personal settings editors (R.2 polish)

    @Test("setPrivacy persiste el slot en personal_settings_summary")
    func setPrivacyPersists() async throws {
        let mock = await makeDemoClient()
        let store = await MainActor.run {
            PersonalSettingsStore(rpc: mock)
        }
        await MainActor.run { Task { await store.load() } }
        // Esperar el load inicial
        try await Task.sleep(for: .milliseconds(10))

        try await MainActor.run {
            Task {
                try await store.setPrivacy(.discoverableBy, value: "anyone")
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        let summary = try await mock.personalSettingsSummary()
        #expect(summary.privacy.discoverableBy == "anyone")
    }

    @Test("setCalendar persiste time_zone")
    func setCalendarPersists() async throws {
        let mock = await makeDemoClient()
        let store = await MainActor.run {
            PersonalSettingsStore(rpc: mock)
        }
        try await MainActor.run {
            Task { try await store.setCalendar(.timeZone, value: "America/Cancun") }
        }
        try await Task.sleep(for: .milliseconds(20))

        let summary = try await mock.personalSettingsSummary()
        #expect(summary.calendar.timeZone == "America/Cancun")
    }

    @Test("setDefaultContext persiste UUID")
    func setDefaultContextPersists() async throws {
        let mock = await makeDemoClient()
        let store = await MainActor.run {
            PersonalSettingsStore(rpc: mock)
        }
        let target = MockRuulRPCClient.DemoIds.cenaSemanal
        try await MainActor.run {
            Task { try await store.setDefaultContext(target) }
        }
        try await Task.sleep(for: .milliseconds(20))

        let summary = try await mock.personalSettingsSummary()
        #expect(summary.contexts.defaultContextActorId == target)
    }

    // MARK: - F.1A polish Resource editor

    @Test("update_resource cambia display_name y description preservando otros campos")
    func updateResourceMock() async throws {
        let mock = await makeDemoClient()
        let casa = MockRuulRPCClient.DemoIds.casaValle
        let updated = try await mock.updateResource(UpdateResourceInput(
            resourceId: casa,
            displayName: "Casa Valle (rebautizada)",
            description: "Nueva descripción"
        ))
        #expect(updated.displayName == "Casa Valle (rebautizada)")
        #expect(updated.description == "Nueva descripción")
        // El tipo no cambia
        #expect(updated.resourceType == "house")
    }

    @Test("update_resource rechaza sin OWN/MANAGE")
    func updateResourceRejectsWithoutRight() async throws {
        // Crear un cliente como David (USE pero no OWN/MANAGE sobre Casa Valle)
        let david = CurrentActor(
            actor: ActorRecord(
                id: MockRuulRPCClient.DemoIds.david,
                actorKind: .person,
                actorSubtype: "person",
                displayName: "David"
            )
        )
        let mock = MockRuulRPCClient(me: david)
        await mock.seedDemoWorld()
        await #expect(throws: RuulError.self) {
            _ = try await mock.updateResource(UpdateResourceInput(
                resourceId: MockRuulRPCClient.DemoIds.casaValle,
                displayName: "Intento sin permiso"
            ))
        }
    }

    // MARK: - F.1A polish update_context (backend RPC + iOS wire)

    @Test("update_context cambia display_name + description y persiste en summary")
    func updateContextGeneralMock() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let result = try await mock.updateContext(UpdateContextInput(
            contextId: cena,
            displayName: "Cena Semanal (rebautizada)",
            description: "Cena de los viernes",
            visibility: "members"
        ))
        #expect(result.general.displayName == "Cena Semanal (rebautizada)")
        #expect(result.general.description == "Cena de los viernes")
        #expect(result.general.visibility == "members")
    }

    @Test("update_context merge profundo en money_config preserva keys existentes")
    func updateContextDeepMergeMock() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        // Cambia solo currency. settlement_policy debe quedar en su default (monthly).
        let first = try await mock.updateContext(UpdateContextInput(
            contextId: cena, moneyConfig: .object(["currency": .string("USD")])
        ))
        #expect(first.moneyConfig.currency == "USD")
        #expect(first.moneyConfig.settlementPolicy == "monthly")
        // Ahora cambia solo settlement_policy. currency debe seguir USD.
        let second = try await mock.updateContext(UpdateContextInput(
            contextId: cena, moneyConfig: .object(["settlement_policy": .string("weekly")])
        ))
        #expect(second.moneyConfig.currency == "USD")
        #expect(second.moneyConfig.settlementPolicy == "weekly")
    }

    @Test("update_context rechaza visibility inválida")
    func updateContextRejectsInvalidVisibility() async throws {
        let mock = await makeDemoClient()
        await #expect(throws: RuulError.self) {
            _ = try await mock.updateContext(UpdateContextInput(
                contextId: MockRuulRPCClient.DemoIds.cenaSemanal,
                visibility: "invalid_value"
            ))
        }
    }

    // MARK: - F.1A polish transfer_resource_ownership

    @Test("transfer_resource_ownership revoca OWN del caller + grant al recipient")
    func transferResourceOwnershipMock() async throws {
        let mock = await makeDemoClient()
        let casa = MockRuulRPCClient.DemoIds.casaValle
        let jose = MockRuulRPCClient.DemoIds.jose
        let david = MockRuulRPCClient.DemoIds.david
        // En el seed, José tiene USE (no OWN). Le otorgamos OWN para poder probar
        // el transfer (mock no chequea permission al grant).
        _ = try await mock.grantRight(GrantRightInput(
            resourceId: casa, holderActorId: jose, rightKind: .own, percent: 100
        ))

        let result = try await mock.transferResourceOwnership(
            resourceId: casa, toActorId: david, reason: "Smoke test"
        )
        #expect(result.fromActorId == jose)
        #expect(result.toActorId == david)
        #expect(result.rightsRevoked == 1)

        // Verificar: David ahora tiene OWN; José ya no.
        let detail = try await mock.resourceDetail(resourceId: casa)
        let davidOwns = detail.rights.contains {
            $0.holderActorId == david && $0.rightKind == "OWN"
        }
        let joseOwns = detail.rights.contains {
            $0.holderActorId == jose && $0.rightKind == "OWN"
        }
        #expect(davidOwns)
        #expect(!joseOwns)
    }

    @Test("transfer_resource_ownership rechaza self-transfer")
    func transferRejectsSelf() async throws {
        let mock = await makeDemoClient()
        await #expect(throws: RuulError.self) {
            _ = try await mock.transferResourceOwnership(
                resourceId: MockRuulRPCClient.DemoIds.casaValle,
                toActorId: MockRuulRPCClient.DemoIds.jose,
                reason: nil
            )
        }
    }

    @Test("transfer_resource_ownership rechaza si el caller no tiene OWN")
    func transferRejectsWithoutOwn() async throws {
        // David no tiene OWN en Casa Valle (solo USE) — desde su perspectiva, falla.
        let david = CurrentActor(
            actor: ActorRecord(
                id: MockRuulRPCClient.DemoIds.david,
                actorKind: .person, actorSubtype: "person",
                displayName: "David"
            )
        )
        let mock = MockRuulRPCClient(me: david)
        await mock.seedDemoWorld()
        await #expect(throws: RuulError.self) {
            _ = try await mock.transferResourceOwnership(
                resourceId: MockRuulRPCClient.DemoIds.casaValle,
                toActorId: MockRuulRPCClient.DemoIds.isaac,
                reason: nil
            )
        }
    }

    // MARK: - R.2Q-6 multiple_choice voting

    @Test("multiple_choice permite varios votos del mismo voter")
    func multipleChoiceVoteAccumulates() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let created = try await mock.createDecision(CreateDecisionInput(
            contextId: cena,
            decisionType: .generic,
            title: "Qué hacemos viernes",
            votingModel: .multipleChoice
        ))
        let opt1 = try await mock.createDecisionOption(CreateDecisionOptionInput(
            decisionId: created.id, optionKey: "cine", title: "Cine"
        ))
        let opt2 = try await mock.createDecisionOption(CreateDecisionOptionInput(
            decisionId: created.id, optionKey: "cena", title: "Cena"
        ))

        _ = try await mock.voteForOption(decisionId: created.id, optionId: opt1.id)
        _ = try await mock.voteForOption(decisionId: created.id, optionId: opt2.id)

        let votes = try await mock.listDecisionVotes(decisionId: created.id)
        let myVotes = votes.filter { $0.voterActorId == MockRuulRPCClient.DemoIds.jose }
        #expect(myVotes.count == 2)
    }

    @Test("multiple_choice duplicate vote es idempotente")
    func multipleChoiceDuplicateIdempotent() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let created = try await mock.createDecision(CreateDecisionInput(
            contextId: cena, decisionType: .generic, title: "X",
            votingModel: .multipleChoice
        ))
        let opt = try await mock.createDecisionOption(CreateDecisionOptionInput(
            decisionId: created.id, optionKey: "a", title: "A"
        ))
        _ = try await mock.voteForOption(decisionId: created.id, optionId: opt.id)
        _ = try await mock.voteForOption(decisionId: created.id, optionId: opt.id)
        let votes = try await mock.listDecisionVotes(decisionId: created.id)
        #expect(votes.filter { $0.voterActorId == MockRuulRPCClient.DemoIds.jose }.count == 1)
    }

    @Test("unvote_option remueve uno de varios votos")
    func unvoteOptionRemoves() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let created = try await mock.createDecision(CreateDecisionInput(
            contextId: cena, decisionType: .generic, title: "Y",
            votingModel: .multipleChoice
        ))
        let optA = try await mock.createDecisionOption(CreateDecisionOptionInput(
            decisionId: created.id, optionKey: "a", title: "A"
        ))
        let optB = try await mock.createDecisionOption(CreateDecisionOptionInput(
            decisionId: created.id, optionKey: "b", title: "B"
        ))
        _ = try await mock.voteForOption(decisionId: created.id, optionId: optA.id)
        _ = try await mock.voteForOption(decisionId: created.id, optionId: optB.id)
        let result = try await mock.unvoteOption(decisionId: created.id, optionId: optA.id)
        #expect(result.removed)
        let votes = try await mock.listDecisionVotes(decisionId: created.id)
        #expect(votes.filter { $0.voterActorId == MockRuulRPCClient.DemoIds.jose }.count == 1)
        // Repeat → no-op
        let noop = try await mock.unvoteOption(decisionId: created.id, optionId: optA.id)
        #expect(!noop.removed)
    }

    @Test("unvote_option rechaza en yes_no_abstain")
    func unvoteRejectsWrongModel() async throws {
        let mock = await makeDemoClient()
        let cena = MockRuulRPCClient.DemoIds.cenaSemanal
        let created = try await mock.createDecision(CreateDecisionInput(
            contextId: cena, decisionType: .generic, title: "Z",
            votingModel: .yesNoAbstain
        ))
        await #expect(throws: RuulError.self) {
            _ = try await mock.unvoteOption(decisionId: created.id, optionId: UUID())
        }
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
