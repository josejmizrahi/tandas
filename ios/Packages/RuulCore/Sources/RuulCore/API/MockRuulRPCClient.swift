import Foundation

/// Implementación in-memory de `RuulRPCClient` para previews y tests.
/// Simula los happy paths del backend MVP2: membresías, recursos/derechos,
/// eventos con check-in tarde → multa, reservaciones con conflicto,
/// decisiones con mayoría, gastos con split y settlement.
///
/// `MockRuulRPCClient.demo()` arranca seedeado con el escenario canónico del
/// founder: José + David + Isaac + Moisés + Daniel, "Cena Semanal", "Familia"
/// y "Casa Valle".
public actor MockRuulRPCClient: RuulRPCClient {

    // MARK: - Estado

    public var me: CurrentActor
    var actors: [UUID: ActorRecord] = [:]
    var memberships: [UUID: [ContextMember]] = [:]          // contextId → members
    var permissions: [UUID: [String]] = [:]                  // contextId → my permissions
    var invites: [String: (id: UUID, contextId: UUID)] = [:] // code → invite
    var resources: [UUID: Resource] = [:]
    var rights: [UUID: [ResourceRight]] = [:]                // resourceId → rights
    var resourceContext: [UUID: UUID] = [:]                  // resourceId → contextId
    var events: [UUID: CalendarEvent] = [:]
    var participants: [UUID: [EventParticipant]] = [:]       // eventId → participants
    var rules: [UUID: [Rule]] = [:]                          // contextId → rules
    var reservations: [UUID: Reservation] = [:]
    var conflicts: [UUID: ReservationConflict] = [:]
    var decisions: [UUID: Decision] = [:]
    var votes: [UUID: [DecisionVote]] = [:]                  // decisionId → votes
    var obligations: [UUID: Obligation] = [:]
    var batches: [UUID: SettlementBatch] = [:]
    var settlementItems: [UUID: [SettlementItem]] = [:]      // batchId → items
    var activity: [UUID: [ActivityEvent]] = [:]              // contextId → events

    /// Error a lanzar en la siguiente llamada (para probar manejo de errores).
    public var nextError: RuulError?

    public init(me: CurrentActor) {
        self.me = me
        self.actors[me.id] = me.actor
    }

    public func setNextError(_ error: RuulError?) {
        nextError = error
    }

    private func throwIfNeeded() throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
    }

    private func emit(_ contextId: UUID, _ type: String, actorId: UUID? = nil, payload: JSONValue? = nil) {
        let event = ActivityEvent(
            id: UUID(),
            eventType: type,
            actorId: actorId ?? me.id,
            payload: payload,
            occurredAt: Date()
        )
        activity[contextId, default: []].insert(event, at: 0)
    }

    // MARK: - Identity

    public func ensurePersonActor() async throws -> CurrentActor {
        try throwIfNeeded()
        return me
    }

    public func updateMyProfile(fullName: String?, preferredName: String?, avatarUrl: String?) async throws -> CurrentActor {
        try throwIfNeeded()
        let actor = ActorRecord(
            id: me.id,
            actorKind: .person,
            actorSubtype: "person",
            displayName: preferredName ?? fullName ?? me.displayName
        )
        let profile = PersonProfile(
            actorId: me.id,
            fullName: fullName ?? me.profile?.fullName,
            preferredName: preferredName ?? me.profile?.preferredName,
            phone: me.profile?.phone,
            email: me.profile?.email,
            avatarUrl: avatarUrl ?? me.profile?.avatarUrl
        )
        me = CurrentActor(actor: actor, profile: profile)
        actors[me.id] = actor
        return me
    }

    // MARK: - Contexts

    public func contextCandidates() async throws -> ContextCandidates {
        try throwIfNeeded()
        let candidates = memberships.compactMap { contextId, members -> ContextCandidate? in
            guard members.contains(where: { $0.actorId == me.id }),
                  let actor = actors[contextId] else { return nil }
            return ContextCandidate(
                contextActorId: contextId,
                displayName: actor.displayName,
                actorKind: actor.actorKind,
                actorSubtype: actor.actorSubtype,
                visibility: actor.visibility,
                membershipType: members.first { $0.actorId == me.id }?.membershipType,
                memberCount: members.count,
                roles: members.first { $0.actorId == me.id }?.roles ?? []
            )
        }.sorted { $0.displayName < $1.displayName }
        return ContextCandidates(personalContext: me.actor, contexts: candidates)
    }

    public func contextSummary(contextId: UUID) async throws -> ContextSummary {
        try throwIfNeeded()
        guard let context = actors[contextId] else {
            throw RuulError.backend(.notAMember)
        }
        let members = memberships[contextId] ?? []
        let contextResources = resources.values.filter { resourceContext[$0.id] == contextId }
        let contextEvents = events.values
            .filter { $0.contextActorId == contextId && $0.isScheduled }
            .sorted { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
        let openDecisions = decisions.values
            .filter { $0.contextActorId == contextId && $0.isOpen }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        let openObs = obligations.values
            .filter { $0.contextActorId == contextId && $0.isOpen }
        let contextRules = (rules[contextId] ?? []).filter(\.isActive)
        let recentActivity = (activity[contextId] ?? []).prefix(20)
        let myBalance = openObs.reduce(0.0) { sum, ob in
            if ob.creditorActorId == me.id { return sum + (ob.amount ?? 0) }
            if ob.debtorActorId == me.id { return sum - (ob.amount ?? 0) }
            return sum
        }

        return ContextSummary(
            context: context,
            asOf: Date(),
            membersCount: members.count,
            resourcesCount: contextResources.count,
            pendingDecisions: openDecisions.count,
            openObligationsCount: openObs.count,
            members: members,
            myPermissions: permissions[contextId] ?? [],
            resources: contextResources.map {
                SummaryResource(
                    resourceId: $0.id,
                    displayName: $0.displayName,
                    resourceType: $0.resourceType,
                    estimatedValue: $0.estimatedValue,
                    currency: $0.currency
                )
            },
            upcomingEvents: contextEvents.map {
                SummaryEvent(
                    eventId: $0.id,
                    title: $0.title,
                    eventType: $0.eventType,
                    startsAt: $0.startsAt,
                    hostActorId: $0.hostActorId,
                    status: $0.status
                )
            },
            openDecisions: openDecisions.map {
                SummaryDecision(decisionId: $0.id, title: $0.title, decisionType: $0.decisionType, createdAt: $0.createdAt)
            },
            money: SummaryMoney(
                openObligations: openObs.map {
                    SummaryObligation(
                        obligationId: $0.id,
                        debtorActorId: $0.debtorActorId,
                        creditorActorId: $0.creditorActorId,
                        obligationType: $0.obligationType,
                        amount: $0.amount,
                        currency: $0.currency
                    )
                },
                myBalance: myBalance
            ),
            activeRules: contextRules.map {
                SummaryRule(ruleId: $0.id, title: $0.title, triggerEventType: $0.triggerEventType)
            },
            recentActivity: recentActivity.map {
                SummaryActivity(eventType: $0.eventType, actorId: $0.actorId, payload: $0.payload, occurredAt: $0.occurredAt)
            }
        )
    }

    public func myWorld() async throws -> MyWorld {
        try throwIfNeeded()
        let myContexts = memberships.compactMap { contextId, members -> MyWorldContext? in
            guard members.contains(where: { $0.actorId == me.id }),
                  let actor = actors[contextId] else { return nil }
            return MyWorldContext(
                contextActorId: contextId,
                displayName: actor.displayName,
                actorKind: actor.actorKind,
                actorSubtype: actor.actorSubtype,
                membershipType: members.first { $0.actorId == me.id }?.membershipType
            )
        }
        let myResources = resources.values.compactMap { resource -> MyWorldResource? in
            let resourceRights = rights[resource.id] ?? []
            var reasons: [String] = resourceRights
                .filter { $0.holderActorId == me.id }
                .map(\.rightKind)
            // Derechos vía contextos donde soy admin
            for right in resourceRights where right.holderActorId != me.id {
                if let holder = actors[right.holderActorId], holder.actorKind != .person,
                   memberships[right.holderActorId]?.contains(where: { $0.actorId == me.id && $0.isAdmin }) == true {
                    reasons.append("\(right.rightKind) via \(holder.displayName)")
                }
            }
            guard !reasons.isEmpty else { return nil }
            return MyWorldResource(
                resourceId: resource.id,
                displayName: resource.displayName,
                resourceType: resource.resourceType,
                reasons: reasons
            )
        }
        let myObligations = obligations.values
            .filter { ($0.debtorActorId == me.id || $0.creditorActorId == me.id) && $0.isOpen }
            .map { ob in
                MyWorldObligation(
                    obligationId: ob.id,
                    contextActorId: ob.contextActorId,
                    contextName: ob.contextActorId.flatMap { actors[$0]?.displayName },
                    role: ob.debtorActorId == me.id ? "debtor" : "creditor",
                    obligationType: ob.obligationType,
                    amount: ob.amount,
                    currency: ob.currency
                )
            }
        return MyWorld(
            actorId: me.id,
            contexts: myContexts.sorted { $0.displayName < $1.displayName },
            resources: myResources.sorted { $0.displayName < $1.displayName },
            openObligations: myObligations
        )
    }

    public func createContext(_ input: CreateContextInput) async throws -> CreatedContext {
        try throwIfNeeded()
        let id = UUID()
        let actor = ActorRecord(
            id: id,
            actorKind: input.actorKind,
            actorSubtype: input.actorSubtype,
            displayName: input.displayName,
            visibility: input.visibility,
            createdAt: Date()
        )
        actors[id] = actor
        memberships[id] = [
            ContextMember(actorId: me.id, displayName: me.displayName, membershipType: "founder", joinedAt: Date(), roles: ["admin"])
        ]
        permissions[id] = MockRuulRPCClient.allPermissions
        emit(id, "context.created")
        return CreatedContext(contextActorId: id, context: actor)
    }

    // MARK: - Invites & membership

    public func createInvite(contextId: UUID, maxUses: Int?, expiresAt: Date?) async throws -> InviteCreated {
        try throwIfNeeded()
        let id = UUID()
        let code = String(UUID().uuidString.prefix(8)).lowercased()
        invites[code] = (id: id, contextId: contextId)
        emit(contextId, "invite.created")
        return InviteCreated(inviteId: id, code: code)
    }

    public func revokeInvite(inviteId: UUID) async throws {
        try throwIfNeeded()
        invites = invites.filter { $0.value.id != inviteId }
    }

    public func joinByInviteCode(_ code: String) async throws -> JoinResult {
        try throwIfNeeded()
        let normalized = code.trimmingCharacters(in: .whitespaces).lowercased()
        guard let invite = invites[normalized], let context = actors[invite.contextId] else {
            throw RuulError.backend(.invalidInvite(message: "invite not found"))
        }
        let membershipId = UUID()
        if memberships[invite.contextId]?.contains(where: { $0.actorId == me.id }) != true {
            memberships[invite.contextId, default: []].append(
                ContextMember(actorId: me.id, displayName: me.displayName, membershipType: "member", joinedAt: Date(), roles: ["member"])
            )
            permissions[invite.contextId] = MockRuulRPCClient.memberPermissions
        }
        emit(invite.contextId, "membership.joined")
        return JoinResult(contextActorId: invite.contextId, membershipId: membershipId, context: context)
    }

    public func removeMember(contextId: UUID, memberActorId: UUID, reason: String?) async throws {
        try throwIfNeeded()
        memberships[contextId]?.removeAll { $0.actorId == memberActorId }
        emit(contextId, "membership.removed", actorId: memberActorId)
    }

    public func leaveContext(contextId: UUID) async throws {
        try throwIfNeeded()
        memberships[contextId]?.removeAll { $0.actorId == me.id }
        emit(contextId, "membership.left")
    }

    public func assignRole(contextId: UUID, memberActorId: UUID, roleKey: String) async throws {
        try throwIfNeeded()
        guard var members = memberships[contextId],
              let index = members.firstIndex(where: { $0.actorId == memberActorId }) else { return }
        let member = members[index]
        members[index] = ContextMember(
            actorId: member.actorId,
            displayName: member.displayName,
            membershipType: member.membershipType,
            joinedAt: member.joinedAt,
            roles: Array(Set(member.roles + [roleKey]))
        )
        memberships[contextId] = members
    }

    // MARK: - Resources & rights

    public func createResource(_ input: CreateResourceInput) async throws -> Resource {
        try throwIfNeeded()
        let id = UUID()
        let resource = Resource(
            id: id,
            resourceType: input.resourceType.rawValue,
            displayName: input.displayName,
            description: input.description,
            estimatedValue: input.estimatedValue,
            currency: input.currency,
            canonicalOwnerActorId: input.contextId,
            createdAt: Date()
        )
        resources[id] = resource
        resourceContext[id] = input.contextId
        // Auto-OWN 100% al contexto dueño (trigger del backend).
        rights[id] = [
            ResourceRight(
                rightId: UUID(),
                holderActorId: input.contextId,
                holderDisplayName: actors[input.contextId]?.displayName,
                rightKind: RightKind.own.rawValue,
                percent: 100
            )
        ]
        emit(input.contextId, "resource.created")
        return resource
    }

    public func listContextResources(contextId: UUID) async throws -> [ContextResource] {
        try throwIfNeeded()
        return resources.values
            .filter { resource in
                resourceContext[resource.id] == contextId
                    || rights[resource.id]?.contains { $0.holderActorId == contextId } == true
            }
            .map { resource in
                ContextResource(
                    resourceId: resource.id,
                    resourceType: resource.resourceType,
                    displayName: resource.displayName,
                    status: resource.status,
                    estimatedValue: resource.estimatedValue,
                    currency: resource.currency,
                    canonicalOwnerActorId: resource.canonicalOwnerActorId,
                    rights: rights[resource.id] ?? []
                )
            }
            .sorted { $0.displayName < $1.displayName }
    }

    public func resourceDetail(resourceId: UUID) async throws -> ResourceDetail {
        try throwIfNeeded()
        guard let resource = resources[resourceId] else {
            throw RuulError.unexpected(message: "Recurso no encontrado")
        }
        return ResourceDetail(resource: resource, rights: rights[resourceId] ?? [])
    }

    public func grantRight(_ input: GrantRightInput) async throws -> UUID {
        try throwIfNeeded()
        let id = UUID()
        let right = ResourceRight(
            rightId: id,
            holderActorId: input.holderActorId,
            holderDisplayName: actors[input.holderActorId]?.displayName
                ?? lookupMemberName(input.holderActorId),
            rightKind: input.rightKind.rawValue,
            percent: input.percent,
            scope: input.scope,
            startsAt: input.startsAt,
            endsAt: input.endsAt
        )
        rights[input.resourceId, default: []].append(right)
        if let contextId = resourceContext[input.resourceId] {
            emit(contextId, "right.granted", actorId: input.holderActorId)
        }
        return id
    }

    public func revokeRight(rightId: UUID) async throws {
        try throwIfNeeded()
        for (resourceId, list) in rights {
            rights[resourceId] = list.filter { $0.rightId != rightId }
        }
    }

    public func archiveResource(resourceId: UUID) async throws {
        try throwIfNeeded()
        resources[resourceId] = nil
        rights[resourceId] = nil
    }

    private func lookupMemberName(_ actorId: UUID) -> String? {
        for members in memberships.values {
            if let member = members.first(where: { $0.actorId == actorId }) {
                return member.displayName
            }
        }
        return nil
    }

    // MARK: - Events

    public func createCalendarEvent(_ input: CreateEventInput) async throws -> CalendarEvent {
        try throwIfNeeded()
        let id = UUID()
        let event = CalendarEvent(
            id: id,
            contextActorId: input.contextId,
            title: input.title,
            description: input.description,
            eventType: input.eventType.rawValue,
            startsAt: input.startsAt,
            endsAt: input.endsAt,
            locationText: input.locationText,
            recurrenceRule: input.recurrenceRule,
            hostActorId: input.hostActorId ?? me.id,
            status: "scheduled",
            createdByActorId: me.id,
            createdAt: Date()
        )
        events[id] = event
        var eventParticipants: [EventParticipant] = []
        if input.inviteAllMembers {
            for member in memberships[input.contextId] ?? [] {
                eventParticipants.append(EventParticipant(
                    id: UUID(),
                    eventId: id,
                    participantActorId: member.actorId,
                    status: member.actorId == me.id ? "going" : "invited",
                    rsvpAt: member.actorId == me.id ? Date() : nil
                ))
            }
        } else {
            eventParticipants.append(EventParticipant(
                id: UUID(), eventId: id, participantActorId: me.id, status: "going", rsvpAt: Date()
            ))
        }
        participants[id] = eventParticipants
        emit(input.contextId, "event.created")
        return event
    }

    public func listEvents(contextId: UUID) async throws -> [CalendarEvent] {
        try throwIfNeeded()
        return events.values
            .filter { $0.contextActorId == contextId }
            .sorted { ($0.startsAt ?? .distantPast) > ($1.startsAt ?? .distantPast) }
    }

    public func getEvent(eventId: UUID) async throws -> CalendarEvent {
        try throwIfNeeded()
        guard let event = events[eventId] else {
            throw RuulError.unexpected(message: "Evento no encontrado")
        }
        return event
    }

    public func listEventParticipants(eventId: UUID) async throws -> [EventParticipant] {
        try throwIfNeeded()
        return participants[eventId] ?? []
    }

    public func rsvpEvent(eventId: UUID, status: RSVPStatus) async throws {
        try throwIfNeeded()
        updateParticipant(eventId: eventId, actorId: me.id) { participant in
            EventParticipant(
                id: participant.id,
                eventId: eventId,
                participantActorId: participant.participantActorId,
                status: status.rawValue,
                rsvpAt: Date()
            )
        }
        if let contextId = events[eventId]?.contextActorId {
            emit(contextId, "event.rsvp_updated")
        }
    }

    public func checkInParticipant(eventId: UUID, participantActorId: UUID?) async throws -> CheckInResult {
        try throwIfNeeded()
        let actorId = participantActorId ?? me.id
        guard let event = events[eventId] else {
            throw RuulError.unexpected(message: "Evento no encontrado")
        }
        let minutesLate = max(0, Date().timeIntervalSince(event.startsAt ?? Date()) / 60)
        let status = minutesLate > 15 ? "late" : "attended"
        var participantId = UUID()
        updateParticipant(eventId: eventId, actorId: actorId) { participant in
            participantId = participant.id
            return EventParticipant(
                id: participant.id,
                eventId: eventId,
                participantActorId: actorId,
                status: status,
                rsvpAt: participant.rsvpAt,
                checkedInAt: Date(),
                metadata: .object(["minutes_late": .number(minutesLate.rounded())])
            )
        }
        emit(event.contextActorId, "event.checked_in", actorId: actorId)
        // Rule engine simplificado: reglas late fee del contexto.
        evaluateLateRules(contextId: event.contextActorId, eventId: eventId, subjectActorId: actorId, minutesLate: minutesLate)
        return CheckInResult(participantId: participantId, status: status, checkedInAt: Date(), minutesLate: minutesLate.rounded())
    }

    public func cancelParticipation(eventId: UUID) async throws -> CancelParticipationResult {
        try throwIfNeeded()
        guard let event = events[eventId] else {
            throw RuulError.unexpected(message: "Evento no encontrado")
        }
        let sameDay = Calendar.current.isDate(event.startsAt ?? .distantFuture, inSameDayAs: Date())
        var participantId = UUID()
        updateParticipant(eventId: eventId, actorId: me.id) { participant in
            participantId = participant.id
            return EventParticipant(
                id: participant.id,
                eventId: eventId,
                participantActorId: me.id,
                status: "cancelled",
                rsvpAt: participant.rsvpAt,
                cancelledAt: Date(),
                metadata: .object(["same_day_cancellation": .bool(sameDay)])
            )
        }
        emit(event.contextActorId, "event.participation_cancelled")
        if sameDay {
            evaluateSameDayRules(contextId: event.contextActorId, eventId: eventId, subjectActorId: me.id)
        }
        return CancelParticipationResult(participantId: participantId, sameDayCancellation: sameDay)
    }

    public func closeEvent(eventId: UUID) async throws -> CloseEventResult {
        try throwIfNeeded()
        guard let event = events[eventId] else {
            throw RuulError.unexpected(message: "Evento no encontrado")
        }
        var noShows = 0
        for participant in participants[eventId] ?? [] where !participant.checkedIn
            && ["going", "invited", "maybe"].contains(participant.status) {
            noShows += 1
            updateParticipant(eventId: eventId, actorId: participant.participantActorId) { p in
                EventParticipant(id: p.id, eventId: eventId, participantActorId: p.participantActorId, status: "no_show", rsvpAt: p.rsvpAt)
            }
        }
        events[eventId] = CalendarEvent(
            id: event.id,
            contextActorId: event.contextActorId,
            title: event.title,
            description: event.description,
            eventType: event.eventType,
            startsAt: event.startsAt,
            endsAt: event.endsAt,
            locationText: event.locationText,
            recurrenceRule: event.recurrenceRule,
            hostActorId: event.hostActorId,
            status: "completed",
            createdByActorId: event.createdByActorId,
            createdAt: event.createdAt
        )
        emit(event.contextActorId, "event.closed")

        // Recurrencia semanal: crear la siguiente instancia con host rotado.
        var nextEventId: UUID?
        var nextHost: UUID?
        if event.recurrenceRule == "weekly" {
            let members = memberships[event.contextActorId] ?? []
            if let currentIndex = members.firstIndex(where: { $0.actorId == event.hostActorId }) {
                nextHost = members[(currentIndex + 1) % members.count].actorId
            } else {
                nextHost = members.first?.actorId
            }
            let nextId = UUID()
            nextEventId = nextId
            events[nextId] = CalendarEvent(
                id: nextId,
                contextActorId: event.contextActorId,
                title: event.title,
                description: event.description,
                eventType: event.eventType,
                startsAt: event.startsAt.map { $0.addingTimeInterval(7 * 24 * 3600) },
                endsAt: event.endsAt.map { $0.addingTimeInterval(7 * 24 * 3600) },
                locationText: event.locationText,
                recurrenceRule: event.recurrenceRule,
                hostActorId: nextHost,
                status: "scheduled",
                createdByActorId: event.createdByActorId,
                createdAt: Date()
            )
            participants[nextId] = (memberships[event.contextActorId] ?? []).map { member in
                EventParticipant(id: UUID(), eventId: nextId, participantActorId: member.actorId, status: "invited")
            }
        }
        return CloseEventResult(eventId: eventId, noShows: noShows, nextEventId: nextEventId, nextHostActorId: nextHost)
    }

    private func updateParticipant(eventId: UUID, actorId: UUID, transform: (EventParticipant) -> EventParticipant) {
        var list = participants[eventId] ?? []
        if let index = list.firstIndex(where: { $0.participantActorId == actorId }) {
            list[index] = transform(list[index])
        } else {
            let new = EventParticipant(id: UUID(), eventId: eventId, participantActorId: actorId, status: "invited")
            list.append(transform(new))
        }
        participants[eventId] = list
    }

    // MARK: - Rules

    public func createRule(_ input: CreateRuleInput) async throws -> Rule {
        try throwIfNeeded()
        let rule = Rule(
            id: UUID(),
            contextActorId: input.contextId,
            title: input.title,
            body: input.body,
            ruleType: input.ruleType,
            severity: input.severity,
            status: "active",
            triggerEventType: input.triggerEventType,
            conditionTree: input.conditionTree,
            consequences: input.consequences,
            createdAt: Date()
        )
        rules[input.contextId, default: []].append(rule)
        emit(input.contextId, "rule.created")
        return rule
    }

    public func listRules(contextId: UUID) async throws -> [Rule] {
        try throwIfNeeded()
        return rules[contextId] ?? []
    }

    private func evaluateLateRules(contextId: UUID, eventId: UUID, subjectActorId: UUID, minutesLate: Double) {
        for rule in rules[contextId] ?? [] where rule.isActive && rule.triggerEventType == RuleTrigger.checkedIn.rawValue {
            guard let threshold = rule.conditionTree?["value"]?.numberValue,
                  rule.conditionTree?["field"]?.stringValue == "minutes_late",
                  minutesLate > threshold else { continue }
            createFineFromRule(rule, contextId: contextId, eventId: eventId, subjectActorId: subjectActorId)
        }
    }

    private func evaluateSameDayRules(contextId: UUID, eventId: UUID, subjectActorId: UUID) {
        for rule in rules[contextId] ?? [] where rule.isActive && rule.triggerEventType == RuleTrigger.participationCancelled.rawValue {
            createFineFromRule(rule, contextId: contextId, eventId: eventId, subjectActorId: subjectActorId)
        }
    }

    private func createFineFromRule(_ rule: Rule, contextId: UUID, eventId: UUID, subjectActorId: UUID) {
        guard let consequence = rule.consequences?.arrayValue?.first,
              let amount = consequence["amount"]?.numberValue else { return }
        let currency = consequence["currency"]?.stringValue ?? "MXN"
        let obligation = Obligation(
            id: UUID(),
            contextActorId: contextId,
            debtorActorId: subjectActorId,
            creditorActorId: contextId,
            obligationType: "fine",
            amount: amount,
            currency: currency,
            sourceEventId: eventId,
            sourceRuleId: rule.id,
            createdAt: Date()
        )
        obligations[obligation.id] = obligation
        emit(contextId, "fine.created", actorId: subjectActorId, payload: .object(["system": .bool(true)]))
    }

    // MARK: - Reservations

    public func requestReservation(_ input: RequestReservationInput) async throws -> ReservationRequestResult {
        try throwIfNeeded()
        let id = UUID()
        let reservation = Reservation(
            id: id,
            resourceId: input.resourceId,
            contextActorId: input.contextId,
            requestedByActorId: me.id,
            reservedForActorId: input.reservedForActorId ?? me.id,
            startsAt: input.startsAt,
            endsAt: input.endsAt,
            status: "requested",
            createdAt: Date()
        )
        reservations[id] = reservation
        emit(input.contextId, "reservation.requested")

        // Detección de conflictos (overlap con otras solicitudes activas).
        var detected = 0
        for other in reservations.values where other.id != id
            && other.resourceId == input.resourceId
            && (other.isPending || other.isActive)
            && other.startsAt < input.endsAt && input.startsAt < other.endsAt {
            detected += 1
            let conflict = ReservationConflict(
                id: UUID(),
                resourceId: input.resourceId,
                reservationAId: other.id,
                reservationBId: id,
                createdAt: Date()
            )
            conflicts[conflict.id] = conflict
            emit(input.contextId, "reservation.conflict_detected", payload: .object(["system": .bool(true)]))
        }
        return ReservationRequestResult(reservationId: id, conflictsDetected: detected, reservation: reservation)
    }

    public func listReservations(resourceId: UUID) async throws -> [Reservation] {
        try throwIfNeeded()
        return reservations.values
            .filter { $0.resourceId == resourceId }
            .sorted { $0.startsAt < $1.startsAt }
    }

    public func listContextReservations(contextId: UUID) async throws -> [Reservation] {
        try throwIfNeeded()
        return reservations.values
            .filter { $0.contextActorId == contextId }
            .sorted { $0.startsAt < $1.startsAt }
    }

    public func listConflicts(resourceId: UUID) async throws -> [ReservationConflict] {
        try throwIfNeeded()
        return conflicts.values
            .filter { $0.resourceId == resourceId }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    public func approveReservation(reservationId: UUID) async throws {
        try throwIfNeeded()
        setReservationStatus(reservationId, "approved")
    }

    public func confirmReservation(reservationId: UUID) async throws {
        try throwIfNeeded()
        setReservationStatus(reservationId, "confirmed")
    }

    public func cancelReservation(reservationId: UUID) async throws {
        try throwIfNeeded()
        setReservationStatus(reservationId, "cancelled")
    }

    public func resolveReservationConflict(conflictId: UUID, winnerReservationId: UUID) async throws {
        try throwIfNeeded()
        guard let conflict = conflicts[conflictId] else { return }
        let loserId = conflict.reservationAId == winnerReservationId ? conflict.reservationBId : conflict.reservationAId
        setReservationStatus(loserId, "rejected")
        setReservationStatus(winnerReservationId, "approved")
        conflicts[conflictId] = ReservationConflict(
            id: conflict.id,
            resourceId: conflict.resourceId,
            reservationAId: conflict.reservationAId,
            reservationBId: conflict.reservationBId,
            conflictType: conflict.conflictType,
            resolutionStatus: "resolved",
            recommendedWinnerActorId: conflict.recommendedWinnerActorId,
            createdAt: conflict.createdAt,
            resolvedAt: Date()
        )
        if let contextId = reservations[winnerReservationId]?.contextActorId {
            emit(contextId, "reservation.conflict_resolved")
        }
    }

    private func setReservationStatus(_ id: UUID, _ status: String) {
        guard let r = reservations[id] else { return }
        reservations[id] = Reservation(
            id: r.id,
            resourceId: r.resourceId,
            contextActorId: r.contextActorId,
            requestedByActorId: r.requestedByActorId,
            reservedForActorId: r.reservedForActorId,
            startsAt: r.startsAt,
            endsAt: r.endsAt,
            status: status,
            priorityScore: r.priorityScore,
            createdAt: r.createdAt
        )
        emit(r.contextActorId, "reservation.\(status)")
    }

    // MARK: - Decisions

    public func createDecision(_ input: CreateDecisionInput) async throws -> Decision {
        try throwIfNeeded()
        let decision = Decision(
            id: UUID(),
            contextActorId: input.contextId,
            decisionType: input.decisionType.rawValue,
            title: input.title,
            description: input.description,
            status: "open",
            createdByActorId: me.id,
            closesAt: input.closesAt,
            payload: input.payload,
            createdAt: Date()
        )
        decisions[decision.id] = decision
        emit(input.contextId, "decision.created")
        return decision
    }

    public func listDecisions(contextId: UUID) async throws -> [Decision] {
        try throwIfNeeded()
        return decisions.values
            .filter { $0.contextActorId == contextId }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    public func listDecisionVotes(decisionId: UUID) async throws -> [DecisionVote] {
        try throwIfNeeded()
        return votes[decisionId] ?? []
    }

    public func voteDecision(decisionId: UUID, vote: VoteChoice, option: String?) async throws -> VoteResult {
        try throwIfNeeded()
        guard let decision = decisions[decisionId] else {
            throw RuulError.unexpected(message: "Decisión no encontrada")
        }
        var decisionVotes = (votes[decisionId] ?? []).filter { $0.voterActorId != me.id }
        decisionVotes.append(DecisionVote(id: UUID(), decisionId: decisionId, voterActorId: me.id, vote: vote.rawValue, votedAt: Date()))
        votes[decisionId] = decisionVotes

        let members = memberships[decision.contextActorId]?.count ?? 1
        let approve = decisionVotes.filter { $0.vote == "approve" }.count
        let reject = decisionVotes.filter { $0.vote == "reject" }.count
        var status = decision.status
        if Double(approve) > Double(members) / 2 {
            status = "approved"
            emit(decision.contextActorId, "decision.approved")
        } else if Double(reject) >= Double(members) / 2 && approve + (members - decisionVotes.count) <= members / 2 {
            status = "rejected"
            emit(decision.contextActorId, "decision.rejected")
        }
        setDecisionStatus(decisionId, status)
        return VoteResult(
            decisionId: decisionId,
            myVote: vote.rawValue,
            status: status,
            tally: VoteTally(approve: approve, reject: reject, members: members)
        )
    }

    public func closeDecision(decisionId: UUID) async throws -> VoteResult {
        try throwIfNeeded()
        guard let decision = decisions[decisionId] else {
            throw RuulError.unexpected(message: "Decisión no encontrada")
        }
        let decisionVotes = votes[decisionId] ?? []
        let members = memberships[decision.contextActorId]?.count ?? 1
        let approve = decisionVotes.filter { $0.vote == "approve" }.count
        let reject = decisionVotes.filter { $0.vote == "reject" }.count
        let status = approve > reject ? "approved" : "rejected"
        setDecisionStatus(decisionId, status)
        emit(decision.contextActorId, "decision.\(status)")
        return VoteResult(
            decisionId: decisionId,
            status: status,
            tally: VoteTally(approve: approve, reject: reject, members: members)
        )
    }

    public func executeDecision(decisionId: UUID, result: JSONValue?) async throws {
        try throwIfNeeded()
        guard let decision = decisions[decisionId], decision.isApproved else {
            throw RuulError.backend(.validation(message: "decision is not approved"))
        }
        setDecisionStatus(decisionId, "executed")
        emit(decision.contextActorId, "decision.executed")
    }

    private func setDecisionStatus(_ id: UUID, _ status: String) {
        guard let d = decisions[id] else { return }
        decisions[id] = Decision(
            id: d.id,
            contextActorId: d.contextActorId,
            decisionType: d.decisionType,
            title: d.title,
            description: d.description,
            status: status,
            createdByActorId: d.createdByActorId,
            closesAt: d.closesAt,
            decidedAt: status == "approved" || status == "rejected" ? Date() : d.decidedAt,
            executedAt: status == "executed" ? Date() : d.executedAt,
            payload: d.payload,
            result: d.result,
            createdAt: d.createdAt
        )
    }

    // MARK: - Money

    public func recordExpense(_ input: RecordExpenseInput) async throws -> ExpenseResult {
        try throwIfNeeded()
        let payer = input.paidByActorId ?? me.id
        let transactionId = UUID()
        var created: [ExpenseObligation] = []

        if input.splitMethod == "custom", let splits = input.splits {
            let total = splits.reduce(0.0) { $0 + $1.amount }
            guard abs(total - input.amount) <= 0.01 else {
                throw RuulError.backend(.validation(message: "splits must sum to amount (\(total) vs \(input.amount))"))
            }
            for split in splits where split.actorId != payer {
                created.append(makeObligation(
                    contextId: input.contextId, debtor: split.actorId, creditor: payer,
                    amount: split.amount, currency: input.currency, eventId: input.eventId
                ))
            }
        } else {
            var participantIds = input.splitWith
                ?? (memberships[input.contextId] ?? []).map(\.actorId)
            if let excluded = input.excludedActorIds {
                participantIds.removeAll { excluded.contains($0) }
            }
            if !participantIds.contains(payer) { participantIds.append(payer) }
            let share = (input.amount / Double(participantIds.count) * 100).rounded() / 100
            for participantId in participantIds where participantId != payer {
                created.append(makeObligation(
                    contextId: input.contextId, debtor: participantId, creditor: payer,
                    amount: share, currency: input.currency, eventId: input.eventId
                ))
            }
        }
        emit(input.contextId, "expense.recorded", payload: .object([
            "amount": .number(input.amount),
            "currency": .string(input.currency),
            "description": .string(input.description)
        ]))
        let share = input.splitMethod == "equal" && !created.isEmpty ? created[0].amount : nil
        return ExpenseResult(transactionId: transactionId, sharePerPerson: share, splitMethod: input.splitMethod, obligations: created)
    }

    public func recordFine(contextId: UUID, debtorActorId: UUID, amount: Double, currency: String, reason: String?) async throws -> UUID {
        try throwIfNeeded()
        let obligation = makeObligation(
            contextId: contextId, debtor: debtorActorId, creditor: contextId,
            amount: amount, currency: currency, eventId: nil, type: "fine"
        )
        emit(contextId, "fine.created", actorId: debtorActorId)
        return obligation.obligationId
    }

    public func recordGameResult(_ input: RecordGameResultInput) async throws -> GameResultRecorded {
        try throwIfNeeded()
        let obligation = makeObligation(
            contextId: input.contextId, debtor: input.loserActorId, creditor: input.winnerActorId,
            amount: input.amount, currency: input.currency, eventId: input.eventId, type: "game_debt"
        )
        emit(input.contextId, "game_result.recorded")
        return GameResultRecorded(transactionId: UUID(), obligationId: obligation.obligationId)
    }

    public func listObligations(contextId: UUID) async throws -> [Obligation] {
        try throwIfNeeded()
        return obligations.values
            .filter { $0.contextActorId == contextId }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    @discardableResult
    private func makeObligation(contextId: UUID, debtor: UUID, creditor: UUID, amount: Double, currency: String, eventId: UUID?, type: String = "expense_share") -> ExpenseObligation {
        let obligation = Obligation(
            id: UUID(),
            contextActorId: contextId,
            debtorActorId: debtor,
            creditorActorId: creditor,
            obligationType: type,
            amount: amount,
            currency: currency,
            sourceEventId: eventId,
            createdAt: Date()
        )
        obligations[obligation.id] = obligation
        return ExpenseObligation(obligationId: obligation.id, debtor: debtor, amount: amount)
    }

    // MARK: - Settlement

    public func generateSettlementBatch(contextId: UUID, currency: String) async throws -> SettlementBatchResult {
        try throwIfNeeded()
        let open = obligations.values.filter {
            $0.contextActorId == contextId && $0.isOpen && ($0.currency ?? "MXN") == currency
        }
        guard !open.isEmpty else {
            return SettlementBatchResult(batchId: nil, items: [], message: "no open obligations")
        }

        // Neteo greedy min-cashflow.
        var net: [UUID: Double] = [:]
        for ob in open {
            net[ob.debtorActorId, default: 0] -= ob.amount ?? 0
            net[ob.creditorActorId, default: 0] += ob.amount ?? 0
        }
        var debtors = net.filter { $0.value < -0.005 }.sorted { $0.value < $1.value }
        var creditors = net.filter { $0.value > 0.005 }.sorted { $0.value > $1.value }
        var transfers: [SettlementTransfer] = []
        var di = 0, ci = 0
        while di < debtors.count && ci < creditors.count {
            let owed = -debtors[di].value
            let due = creditors[ci].value
            let amount = min(owed, due)
            transfers.append(SettlementTransfer(from: debtors[di].key, to: creditors[ci].key, amount: (amount * 100).rounded() / 100))
            debtors[di].value += amount
            creditors[ci].value -= amount
            if -debtors[di].value < 0.005 { di += 1 }
            if creditors[ci].value < 0.005 { ci += 1 }
        }

        if transfers.isEmpty {
            // Todo netea a cero: cerrar obligations directamente.
            for ob in open { closeObligation(ob.id) }
            return SettlementBatchResult(batchId: nil, items: [], message: "all obligations net to zero — settled directly", obligationsNetted: open.count)
        }

        let batchId = UUID()
        batches[batchId] = SettlementBatch(id: batchId, contextActorId: contextId, status: "draft", currency: currency, createdAt: Date())
        settlementItems[batchId] = transfers.map {
            SettlementItem(id: UUID(), settlementBatchId: batchId, fromActorId: $0.from, toActorId: $0.to, amount: $0.amount, currency: currency)
        }
        emit(contextId, "settlement.generated")
        return SettlementBatchResult(batchId: batchId, items: transfers, obligationsNetted: open.count)
    }

    public func listSettlementBatches(contextId: UUID) async throws -> [SettlementBatch] {
        try throwIfNeeded()
        return batches.values
            .filter { $0.contextActorId == contextId }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    public func listSettlementItems(batchId: UUID) async throws -> [SettlementItem] {
        try throwIfNeeded()
        return settlementItems[batchId] ?? []
    }

    public func markSettlementPaid(itemId: UUID) async throws -> MarkPaidResult {
        try throwIfNeeded()
        for (batchId, items) in settlementItems {
            guard let index = items.firstIndex(where: { $0.id == itemId }) else { continue }
            let item = items[index]
            if item.isPaid {
                return MarkPaidResult(itemId: itemId, alreadyPaid: true)
            }
            var updated = items
            updated[index] = SettlementItem(
                id: item.id,
                settlementBatchId: item.settlementBatchId,
                fromActorId: item.fromActorId,
                toActorId: item.toActorId,
                amount: item.amount,
                currency: item.currency,
                status: "paid"
            )
            settlementItems[batchId] = updated

            // Cerrar obligations cubiertas (FIFO simplificado).
            var closed = 0
            var remaining = item.amount
            let batchContext = batches[batchId]?.contextActorId
            for ob in obligations.values.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) })
            where ob.isOpen && ob.debtorActorId == item.fromActorId
                && (ob.creditorActorId == item.toActorId || ob.creditorActorId == batchContext)
                && remaining > 0 {
                closeObligation(ob.id)
                remaining -= ob.amount ?? 0
                closed += 1
            }

            // ¿Batch completo?
            let allPaid = updated.allSatisfy(\.isPaid)
            if allPaid, let batch = batches[batchId] {
                batches[batchId] = SettlementBatch(
                    id: batch.id,
                    contextActorId: batch.contextActorId,
                    status: "finalized",
                    currency: batch.currency,
                    createdAt: batch.createdAt,
                    finalizedAt: Date()
                )
            }
            if let contextId = batchContext {
                emit(contextId, "settlement.paid")
            }
            return MarkPaidResult(itemId: itemId, transactionId: UUID(), batchFinalized: allPaid, obligationsClosed: closed)
        }
        throw RuulError.unexpected(message: "Settlement item no encontrado")
    }

    private func closeObligation(_ id: UUID) {
        guard let ob = obligations[id] else { return }
        obligations[id] = Obligation(
            id: ob.id,
            contextActorId: ob.contextActorId,
            debtorActorId: ob.debtorActorId,
            creditorActorId: ob.creditorActorId,
            obligationType: ob.obligationType,
            amount: ob.amount,
            currency: ob.currency,
            status: "settled",
            dueAt: ob.dueAt,
            sourceEventId: ob.sourceEventId,
            sourceRuleId: ob.sourceRuleId,
            createdAt: ob.createdAt
        )
    }

    // MARK: - Activity

    public func listActivity(contextId: UUID, limit: Int, before: Date?) async throws -> [ActivityEvent] {
        try throwIfNeeded()
        var list = activity[contextId] ?? []
        if let before {
            list = list.filter { ($0.occurredAt ?? .distantPast) < before }
        }
        return Array(list.prefix(min(limit, 100)))
    }

    // MARK: - Catálogos

    public static let allPermissions: [String] = [
        "context.view", "context.manage", "context.invite",
        "members.view", "members.manage",
        "resources.view", "resources.create", "resources.manage",
        "events.view", "events.create", "events.manage",
        "reservations.view", "reservations.request", "reservations.manage",
        "rules.view", "rules.manage",
        "decisions.view", "decisions.create", "decisions.vote", "decisions.execute",
        "money.view", "money.record", "money.settle",
        "documents.view", "documents.manage"
    ]

    public static let memberPermissions: [String] = [
        "context.view", "members.view", "resources.view", "events.view", "events.create",
        "reservations.view", "reservations.request", "rules.view",
        "decisions.view", "decisions.create", "decisions.vote",
        "money.view", "money.record", "documents.view"
    ]
}

// MARK: - Demo world (escenario canónico del founder)

extension MockRuulRPCClient {
    public enum DemoIds {
        public static let jose = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
        public static let david = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!
        public static let isaac = UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!
        public static let moises = UUID(uuidString: "00000000-0000-0000-0000-00000000000d")!
        public static let daniel = UUID(uuidString: "00000000-0000-0000-0000-00000000000e")!
        public static let cenaSemanal = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
        public static let familia = UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!
        public static let casaValle = UUID(uuidString: "00000000-0000-0000-0000-0000000000d1")!
    }

    /// Mundo seedeado con el escenario del founder para previews.
    public static func demo() -> MockRuulRPCClient {
        let jose = CurrentActor(
            actor: ActorRecord(id: DemoIds.jose, actorKind: .person, actorSubtype: "person", displayName: "José"),
            profile: PersonProfile(actorId: DemoIds.jose, fullName: "José Mizrahi", phone: "+5215555550001")
        )
        let mock = MockRuulRPCClient(me: jose)
        Task { await mock.seedDemoWorld() }
        return mock
    }

    /// Seed síncrono (para tests que necesitan el mundo listo).
    public func seedDemoWorld() {
        let friends: [(UUID, String)] = [
            (DemoIds.jose, "José"),
            (DemoIds.david, "David"),
            (DemoIds.isaac, "Isaac"),
            (DemoIds.moises, "Moisés"),
            (DemoIds.daniel, "Daniel")
        ]

        // Contexto: Cena Semanal
        let cena = ActorRecord(id: DemoIds.cenaSemanal, actorKind: .collective, actorSubtype: "friend_group", displayName: "Cena Semanal")
        actors[cena.id] = cena
        memberships[cena.id] = friends.enumerated().map { index, friend in
            ContextMember(
                actorId: friend.0,
                displayName: friend.1,
                membershipType: index == 0 ? "founder" : "member",
                joinedAt: Date().addingTimeInterval(Double(-index) * 86400),
                roles: index == 0 ? ["admin"] : ["member"]
            )
        }
        permissions[cena.id] = MockRuulRPCClient.allPermissions

        // Contexto: Familia
        let familia = ActorRecord(id: DemoIds.familia, actorKind: .collective, actorSubtype: "family", displayName: "Familia Mizrahi")
        actors[familia.id] = familia
        memberships[familia.id] = [
            ContextMember(actorId: DemoIds.jose, displayName: "José", membershipType: "founder", joinedAt: Date(), roles: ["admin"]),
            ContextMember(actorId: DemoIds.isaac, displayName: "Isaac", membershipType: "member", joinedAt: Date(), roles: ["member"]),
            ContextMember(actorId: DemoIds.david, displayName: "David", membershipType: "member", joinedAt: Date(), roles: ["member"])
        ]
        permissions[familia.id] = MockRuulRPCClient.allPermissions

        // Recurso: Casa Valle (de Familia, José tiene USE)
        let casa = Resource(
            id: DemoIds.casaValle,
            resourceType: ResourceType.house.rawValue,
            displayName: "Casa Valle",
            description: "Casa familiar en Valle de Bravo",
            estimatedValue: 4_500_000,
            currency: "MXN",
            canonicalOwnerActorId: familia.id,
            createdAt: Date()
        )
        resources[casa.id] = casa
        resourceContext[casa.id] = familia.id
        rights[casa.id] = [
            ResourceRight(rightId: UUID(), holderActorId: familia.id, holderDisplayName: "Familia Mizrahi", rightKind: "OWN", percent: 100),
            ResourceRight(rightId: UUID(), holderActorId: familia.id, holderDisplayName: "Familia Mizrahi", rightKind: "GOVERN"),
            ResourceRight(rightId: UUID(), holderActorId: DemoIds.jose, holderDisplayName: "José", rightKind: "USE"),
            ResourceRight(rightId: UUID(), holderActorId: DemoIds.david, holderDisplayName: "David", rightKind: "USE"),
            ResourceRight(rightId: UUID(), holderActorId: DemoIds.isaac, holderDisplayName: "Isaac", rightKind: "USE"),
            ResourceRight(rightId: UUID(), holderActorId: DemoIds.moises, holderDisplayName: "Moisés", rightKind: "VIEW")
        ]

        // Evento: cena de esta semana (recurrente, host José)
        let cenaEvent = CalendarEvent(
            id: UUID(),
            contextActorId: cena.id,
            title: "Cena de los jueves",
            eventType: EventType.dinner.rawValue,
            startsAt: Calendar.current.date(byAdding: .day, value: 2, to: Date()),
            locationText: "Casa de José",
            recurrenceRule: "weekly",
            hostActorId: DemoIds.jose,
            status: "scheduled",
            createdByActorId: DemoIds.jose,
            createdAt: Date()
        )
        events[cenaEvent.id] = cenaEvent
        participants[cenaEvent.id] = friends.map { friend in
            EventParticipant(
                id: UUID(),
                eventId: cenaEvent.id,
                participantActorId: friend.0,
                status: friend.0 == DemoIds.jose ? "going" : "invited",
                rsvpAt: friend.0 == DemoIds.jose ? Date() : nil
            )
        }

        // Reglas: llegar tarde y cancelar mismo día
        rules[cena.id] = [
            Rule(
                id: UUID(),
                contextActorId: cena.id,
                title: "Multa por llegar tarde",
                status: "active",
                triggerEventType: RuleTrigger.checkedIn.rawValue,
                conditionTree: RuleConditionBuilder.lateMoreThan(minutes: 15),
                consequences: RuleConsequenceBuilder.fine(amount: 100, currency: "MXN"),
                createdAt: Date()
            ),
            Rule(
                id: UUID(),
                contextActorId: cena.id,
                title: "Multa por cancelar el mismo día",
                status: "active",
                triggerEventType: RuleTrigger.participationCancelled.rawValue,
                conditionTree: RuleConditionBuilder.sameDayCancellation(),
                consequences: RuleConsequenceBuilder.fine(amount: 200, currency: "MXN"),
                createdAt: Date()
            )
        ]

        // Money: David pagó la cena pasada ($1,300 entre 4 — Daniel excluido)
        let david = DemoIds.david
        for debtor in [DemoIds.jose, DemoIds.isaac, DemoIds.moises] {
            let ob = Obligation(
                id: UUID(),
                contextActorId: cena.id,
                debtorActorId: debtor,
                creditorActorId: david,
                obligationType: "expense_share",
                amount: 325,
                currency: "MXN",
                status: "open",
                createdAt: Date()
            )
            obligations[ob.id] = ob
        }

        // Activity seed
        emit(cena.id, "context.created", actorId: DemoIds.jose)
        emit(cena.id, "event.created", actorId: DemoIds.jose)
        emit(cena.id, "rule.created", actorId: DemoIds.jose)
        emit(cena.id, "expense.recorded", actorId: david, payload: .object([
            "amount": .number(1300), "currency": .string("MXN"), "description": .string("Cena de la semana pasada")
        ]))
        emit(familia.id, "context.created", actorId: DemoIds.jose)
        emit(familia.id, "resource.created", actorId: DemoIds.jose)
    }
}
