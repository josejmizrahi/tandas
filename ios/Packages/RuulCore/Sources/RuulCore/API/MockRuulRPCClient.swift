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
    var profileMetadata: JSONValue = .object([:])     // F.1A-1 persiste prefs personales
    /// F.1A polish — overrides de metadata por contexto (description, image_url, *_config).
    var contextMetadata: [UUID: JSONValue] = [:]
    var memberships: [UUID: [ContextMember]] = [:]          // contextId → members
    var permissions: [UUID: [String]] = [:]                  // contextId → my permissions
    var invites: [String: (id: UUID, contextId: UUID)] = [:] // code → invite
    /// Invitaciones pendientes por actor_id invitado → lista.
    var pendingInvitations: [UUID: [PendingInvitation]] = [:]
    var documents: [UUID: Document] = [:]
    /// Storage simulado: path → binary.
    var documentBlobs: [String: Data] = [:]
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
    var decisionOptions: [UUID: [DecisionOption]] = [:]      // decisionId → options
    var obligations: [UUID: Obligation] = [:]
    var batches: [UUID: SettlementBatch] = [:]
    var settlementItems: [UUID: [SettlementItem]] = [:]      // batchId → items
    var activity: [UUID: [ActivityEvent]] = [:]              // contextId → events
    /// R.2U — Context Hierarchy: parent → children directos activos.
    var contextChildrenById: [UUID: [UUID]] = [:]

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

    public func updateMyProfileMetadata(_ metadata: JSONValue) async throws -> CurrentActor {
        try throwIfNeeded()
        // Merge profundo: cada slot top-level se reemplaza con lo que mande el caller.
        if case .object(let incoming) = metadata, case .object(var current) = profileMetadata {
            for (key, value) in incoming { current[key] = value }
            profileMetadata = .object(current)
        } else {
            profileMetadata = metadata
        }
        return me
    }

    public func resourceSettingsSummary(resourceId: UUID) async throws -> ResourceSettings {
        try throwIfNeeded()
        guard let resource = resources[resourceId] else {
            throw RuulError.unexpected(message: "Recurso no encontrado")
        }
        let resourceRights = rights[resourceId] ?? []
        let hasOwn = resourceRights.contains { ($0.holderActorId == me.id) && ($0.rightKind == "OWN") }
        let hasManage = resourceRights.contains { ($0.holderActorId == me.id) && ($0.rightKind == "MANAGE") }
        guard hasOwn || hasManage else {
            throw RuulError.unexpected(message: "Solo OWN o MANAGE pueden ver settings del recurso")
        }

        // Capability matrix mínima (sólo lo que iOS exige). Espeja
        // public.resource_type_capabilities del backend.
        let capabilities: [String]
        switch resource.resourceType {
        case "house":             capabilities = ["auditable", "maintainable", "ownership_trackable", "reservable"]
        case "vehicle":           capabilities = ["maintainable", "ownership_trackable", "reservable"]
        case "equipment":         capabilities = ["maintainable", "ownership_trackable", "reservable"]
        case "bank_account":      capabilities = ["auditable", "monetary", "ownership_trackable"]
        case "cash_pool":         capabilities = ["auditable", "monetary"]
        case "security":          capabilities = ["auditable", "beneficiary_supported", "ownership_trackable", "transferable"]
        case "trust_asset":       capabilities = ["auditable", "beneficiary_supported", "ownership_trackable"]
        case "contract":          capabilities = ["approval_required", "auditable", "documentable"]
        case "document":          capabilities = ["documentable"]
        case "trip_booking":      capabilities = ["documentable", "reservable", "transferable"]
        case "membership_asset":  capabilities = ["ownership_trackable", "transferable"]
        case "digital_asset":     capabilities = ["auditable", "ownership_trackable", "transferable"]
        default:                  capabilities = ["auditable", "ownership_trackable"]
        }

        var rightsSummary: [String: Int] = [:]
        for r in resourceRights {
            rightsSummary[r.rightKind, default: 0] += 1
        }

        var actions: [String] = []
        if hasOwn {
            actions = ["edit_general", "manage_rights", "edit_policies", "archive", "transfer_ownership", "view"]
        } else if hasManage {
            actions = ["edit_general", "manage_rights", "edit_policies", "view"]
        }

        return ResourceSettings(
            resourceId: resourceId,
            general: ResourceGeneralSummary(
                resourceType: resource.resourceType,
                displayName: resource.displayName,
                description: resource.description,
                status: "active",
                estimatedValue: resource.estimatedValue,
                currency: resource.currency,
                archivedAt: nil
            ),
            capabilities: capabilities,
            rightsSummary: rightsSummary,
            policies: ResourcePolicies(
                reservable: ReservablePolicy(
                    maxWindowDays: 14, cancellationPolicy: "open",
                    priorityPolicy: "least_recent_use_wins", capacity: 1
                ),
                monetary: MonetaryPolicy(
                    currency: resource.currency ?? "MXN", settlementPolicy: "monthly"
                ),
                beneficiary: BeneficiaryPolicy(beneficiaries: [], distribution: "equal"),
                documentable: DocumentablePolicy(versioningEnabled: false, approvalsRequired: 0)
            ),
            availableActions: actions
        )
    }

    public func contextSettingsSummary(contextId: UUID) async throws -> ContextSettings {
        try throwIfNeeded()
        guard let ctxActor = actors[contextId] else {
            throw RuulError.unexpected(message: "Contexto no encontrado")
        }
        guard ctxActor.actorKind != .person else {
            throw RuulError.backend(.validation(message: "personal contexts have no settings"))
        }
        guard memberships[contextId]?.contains(where: { $0.actorId == me.id }) == true else {
            throw RuulError.unexpected(message: "No eres miembro del contexto")
        }
        let myPerms = permissions[contextId] ?? []
        var actions: [String] = ["view"]
        if myPerms.contains("context.manage") {
            actions.append(contentsOf: ["edit_general", "edit_decisions", "edit_money", "edit_reservations", "edit_invitations", "view_audit"])
        }
        if myPerms.contains("members.manage") {
            actions.append(contentsOf: ["manage_members", "manage_roles"])
        }
        if myPerms.contains("rules.manage") {
            actions.append("manage_rules")
        }
        if myPerms.contains("context.invite") {
            actions.append("create_invite")
        }

        let memberCount = memberships[contextId]?.count ?? 0
        let meta = contextMetadata[contextId]?.objectValue ?? [:]
        let decisionsMeta = meta["decisions_config"]?.objectValue ?? [:]
        let moneyMeta = meta["money_config"]?.objectValue ?? [:]
        let reservationsMeta = meta["reservations_config"]?.objectValue ?? [:]
        let invitationsMeta = meta["invitations_config"]?.objectValue ?? [:]

        return ContextSettings(
            contextActorId: contextId,
            general: ContextGeneralSummary(
                displayName: ctxActor.displayName,
                description: meta["description"]?.stringValue,
                subtype: ctxActor.actorSubtype,
                visibility: ctxActor.visibility,
                memberCount: memberCount,
                imageUrl: meta["image_url"]?.stringValue
            ),
            decisionsConfig: ContextDecisionsConfig(
                defaultVotingModel: decisionsMeta["default_voting_model"]?.stringValue ?? "yes_no_abstain",
                quorum: decisionsMeta["quorum"]?.stringValue ?? "simple_majority",
                majorityRule: decisionsMeta["majority_rule"]?.stringValue ?? "simple"
            ),
            moneyConfig: ContextMoneyConfig(
                currency: moneyMeta["currency"]?.stringValue ?? "MXN",
                defaultSplit: moneyMeta["default_split"]?.stringValue ?? "equal",
                settlementPolicy: moneyMeta["settlement_policy"]?.stringValue ?? "monthly"
            ),
            reservationsConfig: ContextReservationsConfig(
                priorityPolicy: reservationsMeta["priority_policy"]?.stringValue ?? "least_recent_use_wins",
                conflictResolution: reservationsMeta["conflict_resolution"]?.stringValue ?? "community_vote",
                cancellationPolicy: reservationsMeta["cancellation_policy"]?.stringValue ?? "open"
            ),
            invitationsConfig: ContextInvitationsConfig(
                whoCanInvite: invitationsMeta["who_can_invite"]?.stringValue ?? "admins",
                openInvites: invitationsMeta["open_invites"]?.boolValue ?? false
            ),
            availableActions: actions
        )
    }

    public func updateContext(_ input: UpdateContextInput) async throws -> ContextSettings {
        try throwIfNeeded()
        guard let ctxActor = actors[input.contextId] else {
            throw RuulError.unexpected(message: "Contexto no encontrado")
        }
        guard ctxActor.actorKind != .person else {
            throw RuulError.backend(.validation(message: "cannot update personal context via update_context"))
        }
        let myPerms = permissions[input.contextId] ?? []
        guard myPerms.contains("context.manage") else {
            throw RuulError.unexpected(message: "context.manage required to edit this context")
        }
        if let visibility = input.visibility,
           !["private", "members", "public"].contains(visibility) {
            throw RuulError.unexpected(message: "invalid visibility \"\(visibility)\"")
        }
        if let displayName = input.displayName,
           displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            throw RuulError.unexpected(message: "display_name cannot be empty")
        }

        // Merge metadata por slot — mismo deep-merge que el backend.
        var meta = contextMetadata[input.contextId]?.objectValue ?? [:]
        if let description = input.description {
            meta["description"] = .string(description)
        }
        if let imageUrl = input.imageUrl {
            meta["image_url"] = .string(imageUrl)
        }
        func mergeSlot(_ key: String, with newValue: JSONValue?) {
            guard let newValue, case .object(let newDict) = newValue else { return }
            var current = meta[key]?.objectValue ?? [:]
            for (k, v) in newDict { current[k] = v }
            meta[key] = .object(current)
        }
        mergeSlot("decisions_config", with: input.decisionsConfig)
        mergeSlot("money_config", with: input.moneyConfig)
        mergeSlot("reservations_config", with: input.reservationsConfig)
        mergeSlot("invitations_config", with: input.invitationsConfig)
        contextMetadata[input.contextId] = .object(meta)

        // Actualizar actor (display_name, visibility) si vinieron.
        if input.displayName != nil || input.visibility != nil {
            let updated = ActorRecord(
                id: ctxActor.id,
                actorKind: ctxActor.actorKind,
                actorSubtype: ctxActor.actorSubtype,
                displayName: input.displayName?.trimmingCharacters(in: .whitespaces) ?? ctxActor.displayName,
                slug: ctxActor.slug,
                status: ctxActor.status,
                visibility: input.visibility ?? ctxActor.visibility,
                createdAt: ctxActor.createdAt
            )
            actors[input.contextId] = updated
        }

        emit(input.contextId, "context.updated", payload: .object([
            "context_actor_id": .string(input.contextId.uuidString)
        ]))
        return try await contextSettingsSummary(contextId: input.contextId)
    }

    public func personalSettingsSummary() async throws -> PersonalSettings {
        try throwIfNeeded()
        let meta = profileMetadata.objectValue ?? [:]
        let notifMeta = meta["notifications"]?.objectValue ?? [:]
        func slot(_ key: String, emailDefault: Bool = true) -> NotificationSlot {
            if let obj = notifMeta[key]?.objectValue {
                let push = obj["push"]?.boolValue ?? true
                let email = obj["email"]?.boolValue ?? emailDefault
                return NotificationSlot(push: push, email: email)
            }
            return NotificationSlot(push: true, email: emailDefault)
        }
        let privMeta = meta["privacy"]?.objectValue ?? [:]
        let calMeta = meta["calendar"]?.objectValue ?? [:]
        let ctxMeta = meta["contexts"]?.objectValue ?? [:]
        let intMeta = meta["integrations"]?.objectValue ?? [:]
        func integration(_ key: String) -> IntegrationStatus {
            IntegrationStatus(connected: intMeta[key]?["connected"]?.boolValue ?? false)
        }

        return PersonalSettings(
            actorId: me.id,
            profile: PersonalProfileSummary(
                fullName: me.profile?.fullName,
                preferredName: me.profile?.preferredName,
                phone: me.profile?.phone,
                email: me.profile?.email,
                avatarUrl: me.profile?.avatarUrl
            ),
            notifications: NotificationSettings(
                invitations:  slot("invitations"),
                decisions:    slot("decisions"),
                reservations: slot("reservations"),
                events:       slot("events"),
                obligations:  slot("obligations"),
                money:        slot("money"),
                rules:        slot("rules", emailDefault: false)
            ),
            privacy: PrivacySettings(
                discoverableBy:    privMeta["discoverable_by"]?.stringValue    ?? "members_in_common",
                whoCanInviteMe:    privMeta["who_can_invite_me"]?.stringValue   ?? "members_in_common",
                profileVisibility: privMeta["profile_visibility"]?.stringValue  ?? "members_in_common"
            ),
            calendar: CalendarSettings(
                timeZone:       calMeta["time_zone"]?.stringValue       ?? "America/Mexico_City",
                firstDayOfWeek: calMeta["first_day_of_week"]?.stringValue ?? "monday"
            ),
            contexts: ContextPreferences(
                defaultContextActorId: ctxMeta["default_context_actor_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                lastContextActorId:    ctxMeta["last_context_actor_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            ),
            integrations: IntegrationsState(
                googleCalendar: integration("google_calendar"),
                appleCalendar:  integration("apple_calendar"),
                wise:           integration("wise"),
                whatsapp:       integration("whatsapp")
            ),
            availableActions: [
                "edit_profile", "edit_notifications", "edit_privacy",
                "edit_calendar", "edit_contexts", "edit_integrations"
            ]
        )
    }

    // MARK: - Actor capabilities (R.2S.1)

    public func actorCapabilities(actorId: UUID) async throws -> ActorCapabilities {
        try throwIfNeeded()
        guard let actor = actors[actorId] else {
            throw RuulError.unexpected(message: "Actor no encontrado")
        }
        return ActorCapabilities(
            actorId: actorId,
            actorKind: actor.actorKind,
            actorSubtype: actor.actorSubtype,
            capabilities: Self.mockActorCapabilities(forSubtype: actor.actorSubtype)
        )
    }

    public func actorCapabilitiesCatalog() async throws -> ActorCapabilitiesCatalog {
        try throwIfNeeded()
        return ActorCapabilitiesCatalog(
            capabilities: Self.mockActorCapabilityCatalog,
            subtypes: Self.mockSubtypeMatrix
        )
    }

    public func actorCan(actorId: UUID, capability: String) async throws -> Bool {
        let caps = try await actorCapabilities(actorId: actorId)
        return caps.has(capability)
    }

    /// Matriz `actor_subtype → capabilities` (espeja `public.actor_type_capabilities`).
    static func mockActorCapabilities(forSubtype subtype: String) -> [String] {
        mockSubtypeMatrix.first { $0.actorSubtype == subtype }?.capabilities ?? []
    }

    static let mockActorCapabilityCatalog: [ActorCapabilityCatalogEntry] = [
        .init(capabilityKey: "can_govern_resources", displayName: "Puede gobernar recursos", description: "Ejerce GOVERN/MANAGE sobre recursos del contexto"),
        .init(capabilityKey: "can_have_beneficiaries", displayName: "Puede tener beneficiarios", description: "Puede designar actores como beneficiarios"),
        .init(capabilityKey: "can_have_members", displayName: "Puede tener miembros", description: "Otros actores participan en él vía membership"),
        .init(capabilityKey: "can_have_shareholders", displayName: "Puede tener accionistas", description: "Su propiedad se reparte en acciones (shares)"),
        .init(capabilityKey: "can_have_trustees", displayName: "Puede tener fideicomisarios", description: "Administrado por trustees en nombre de beneficiarios"),
        .init(capabilityKey: "can_hold_assets", displayName: "Puede tener activos", description: "Puede ser holder de rights OWN sobre recursos"),
        .init(capabilityKey: "can_hold_money", displayName: "Puede tener dinero", description: "Participa en transacciones y settlement"),
        .init(capabilityKey: "can_issue_decisions", displayName: "Puede emitir decisiones", description: "Puede abrir decisiones y votar"),
        .init(capabilityKey: "can_issue_obligations", displayName: "Puede emitir obligaciones", description: "Puede ser acreedor / originar obligaciones"),
        .init(capabilityKey: "can_own_resources", displayName: "Puede poseer recursos", description: "Puede ser dueño (OWN) de recursos"),
        .init(capabilityKey: "can_receive_contributions", displayName: "Puede recibir aportaciones", description: "Recibe contribuciones de sus miembros"),
        .init(capabilityKey: "can_receive_obligations", displayName: "Puede recibir obligaciones", description: "Puede ser deudor de una obligación"),
    ]

    static let mockSubtypeMatrix: [ActorSubtypeCapabilities] = [
        .init(actorSubtype: "community", capabilities: ["can_govern_resources","can_have_members","can_hold_money","can_issue_decisions","can_issue_obligations","can_receive_contributions","can_receive_obligations"]),
        .init(actorSubtype: "company", capabilities: ["can_govern_resources","can_have_members","can_have_shareholders","can_hold_assets","can_hold_money","can_issue_decisions","can_issue_obligations","can_own_resources","can_receive_contributions","can_receive_obligations"]),
        .init(actorSubtype: "family", capabilities: ["can_govern_resources","can_have_beneficiaries","can_have_members","can_hold_assets","can_hold_money","can_issue_decisions","can_issue_obligations","can_own_resources","can_receive_contributions","can_receive_obligations"]),
        .init(actorSubtype: "friend_group", capabilities: ["can_govern_resources","can_have_members","can_hold_money","can_issue_decisions","can_issue_obligations","can_receive_contributions","can_receive_obligations"]),
        .init(actorSubtype: "other", capabilities: ["can_hold_assets","can_own_resources"]),
        .init(actorSubtype: "person", capabilities: ["can_hold_assets","can_hold_money","can_issue_obligations","can_own_resources","can_receive_obligations"]),
        .init(actorSubtype: "project", capabilities: ["can_govern_resources","can_have_members","can_hold_money","can_issue_decisions","can_issue_obligations","can_receive_contributions","can_receive_obligations"]),
        .init(actorSubtype: "system", capabilities: ["can_issue_decisions","can_issue_obligations"]),
        .init(actorSubtype: "trip", capabilities: ["can_govern_resources","can_have_members","can_hold_money","can_issue_obligations","can_receive_contributions","can_receive_obligations"]),
        .init(actorSubtype: "trust", capabilities: ["can_govern_resources","can_have_beneficiaries","can_have_trustees","can_hold_assets","can_issue_decisions","can_own_resources"]),
    ]

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

    // MARK: - Context hierarchy (R.2U)

    private func hierarchyNode(_ actorId: UUID, depth: Int? = nil, linkedAt: Date? = nil) -> ContextHierarchyNode? {
        guard let actor = actors[actorId] else { return nil }
        return ContextHierarchyNode(
            id: actor.id,
            name: actor.displayName,
            actorKind: actor.actorKind,
            actorSubtype: actor.actorSubtype,
            visibility: actor.visibility,
            linkedAt: linkedAt,
            depth: depth
        )
    }

    public func contextChildren(contextId: UUID) async throws -> [ContextHierarchyNode] {
        try throwIfNeeded()
        let children = contextChildrenById[contextId, default: []]
        return children.compactMap { hierarchyNode($0, linkedAt: Date()) }
            .sorted { $0.name < $1.name }
    }

    public func contextParents(contextId: UUID) async throws -> [ContextHierarchyNode] {
        try throwIfNeeded()
        let parents = contextChildrenById
            .filter { $0.value.contains(contextId) }
            .map { $0.key }
        return parents.compactMap { hierarchyNode($0, linkedAt: Date()) }
            .sorted { $0.name < $1.name }
    }

    public func contextTree(rootContextId: UUID) async throws -> ContextTreeNode {
        try throwIfNeeded()
        return buildTree(rootContextId)
    }

    private func buildTree(_ id: UUID) -> ContextTreeNode {
        guard let actor = actors[id] else {
            return ContextTreeNode(
                id: id,
                name: "Desconocido",
                actorKind: .collective,
                actorSubtype: "other",
                restricted: true,
                children: nil
            )
        }
        let kids = contextChildrenById[id, default: []].sorted { (a, b) in
            (actors[a]?.displayName ?? "") < (actors[b]?.displayName ?? "")
        }
        return ContextTreeNode(
            id: actor.id,
            name: actor.displayName,
            actorKind: actor.actorKind,
            actorSubtype: actor.actorSubtype,
            restricted: false,
            children: kids.map { buildTree($0) }
        )
    }

    public func contextAncestors(contextId: UUID) async throws -> [ContextHierarchyNode] {
        try throwIfNeeded()
        var result: [ContextHierarchyNode] = []
        var current = contextId
        var depth = 1
        while let parentId = contextChildrenById.first(where: { $0.value.contains(current) })?.key {
            if let node = hierarchyNode(parentId, depth: depth) {
                result.append(node)
            }
            current = parentId
            depth += 1
            if depth > 64 { break }
        }
        return result
    }

    public func contextDescendants(contextId: UUID) async throws -> [ContextHierarchyNode] {
        try throwIfNeeded()
        var result: [ContextHierarchyNode] = []
        var queue: [(UUID, Int)] = contextChildrenById[contextId, default: []].map { ($0, 1) }
        while !queue.isEmpty {
            let (id, depth) = queue.removeFirst()
            if let node = hierarchyNode(id, depth: depth) {
                result.append(node)
            }
            for child in contextChildrenById[id, default: []] {
                queue.append((child, depth + 1))
            }
            if result.count > 256 { break }
        }
        return result
            .sorted { ($0.depth ?? 0, $0.name) < ($1.depth ?? 0, $1.name) }
    }

    public func createChildContext(_ input: CreateChildContextInput) async throws -> CreatedChildContext {
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
        contextChildrenById[input.parentContextActorId, default: []].append(id)
        emit(input.parentContextActorId, "context.child.created", payload: .object([
            "child_actor_id": .string(id.uuidString),
            "display_name": .string(input.displayName)
        ]))
        emit(id, "context.created")
        return CreatedChildContext(
            parentContextActorId: input.parentContextActorId,
            childContextActorId: id,
            relationshipId: UUID(),
            context: actor
        )
    }

    public func linkChildContext(parentId: UUID, childId: UUID) async throws -> LinkChildContextResult {
        try throwIfNeeded()
        var children = contextChildrenById[parentId, default: []]
        if children.contains(childId) {
            return LinkChildContextResult(
                parentContextActorId: parentId,
                childContextActorId: childId,
                relationshipId: UUID(),
                alreadyLinked: true
            )
        }
        children.append(childId)
        contextChildrenById[parentId] = children
        emit(parentId, "context.child.linked", payload: .object([
            "child_actor_id": .string(childId.uuidString)
        ]))
        return LinkChildContextResult(
            parentContextActorId: parentId,
            childContextActorId: childId,
            relationshipId: UUID(),
            alreadyLinked: false
        )
    }

    public func unlinkChildContext(parentId: UUID, childId: UUID) async throws -> UnlinkChildContextResult {
        try throwIfNeeded()
        let children = contextChildrenById[parentId, default: []]
        guard children.contains(childId) else {
            return UnlinkChildContextResult(
                parentContextActorId: parentId,
                childContextActorId: childId,
                relationshipId: nil,
                unlinked: false
            )
        }
        contextChildrenById[parentId] = children.filter { $0 != childId }
        emit(parentId, "context.child.unlinked", payload: .object([
            "child_actor_id": .string(childId.uuidString)
        ]))
        return UnlinkChildContextResult(
            parentContextActorId: parentId,
            childContextActorId: childId,
            relationshipId: UUID(),
            unlinked: true
        )
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

    public func inviteMember(contextId: UUID, memberActorId: UUID, membershipType: String) async throws -> InviteMemberResult {
        try throwIfNeeded()
        guard let context = actors[contextId] else {
            throw RuulError.backend(.unknown(message: "context not found"))
        }
        // Si ya es miembro activo, devolver su status actual sin re-invitar.
        if let existing = memberships[contextId]?.first(where: { $0.actorId == memberActorId }) {
            return InviteMemberResult(membershipId: existing.id, status: "active")
        }
        let membershipId = UUID()
        let invitation = PendingInvitation(
            membershipId: membershipId,
            contextActorId: contextId,
            contextDisplayName: context.displayName,
            contextActorKind: context.actorKind,
            contextActorSubtype: context.actorSubtype,
            invitedAt: Date()
        )
        // Reemplazar invitación pendiente previa al mismo contexto si existe.
        pendingInvitations[memberActorId, default: []].removeAll { $0.contextActorId == contextId }
        pendingInvitations[memberActorId, default: []].insert(invitation, at: 0)
        emit(contextId, "member.invited", actorId: me.id)
        return InviteMemberResult(membershipId: membershipId, status: "invited")
    }

    public func acceptInvitation(contextId: UUID) async throws -> AcceptInvitationResult {
        try throwIfNeeded()
        // Idempotente: si ya soy miembro activo, devolver already_member=true.
        if let existing = memberships[contextId]?.first(where: { $0.actorId == me.id }) {
            return AcceptInvitationResult(membershipId: existing.id, status: "active", alreadyMember: true)
        }
        guard let pending = pendingInvitations[me.id]?.first(where: { $0.contextActorId == contextId }) else {
            throw RuulError.backend(.unknown(message: "no pending invitation"))
        }
        pendingInvitations[me.id]?.removeAll { $0.contextActorId == contextId }
        memberships[contextId, default: []].append(
            ContextMember(
                actorId: me.id,
                displayName: me.displayName,
                membershipType: "member",
                joinedAt: Date(),
                roles: ["member"]
            )
        )
        permissions[contextId] = MockRuulRPCClient.memberPermissions
        emit(contextId, "member.joined", actorId: me.id, payload: .object(["via": .string("invitation")]))
        return AcceptInvitationResult(membershipId: pending.membershipId, status: "active", alreadyMember: false)
    }

    public func listMyPendingInvitations(actorId: UUID) async throws -> [PendingInvitation] {
        try throwIfNeeded()
        return pendingInvitations[actorId] ?? []
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

    // MARK: - Documents

    public func registerDocument(_ input: RegisterDocumentInput) async throws -> DocumentRegistered {
        try throwIfNeeded()
        let id = UUID()
        let doc = Document(
            id: id,
            ownerActorId: me.id,
            contextActorId: input.contextActorId,
            title: input.title,
            documentType: input.documentType,
            storagePath: input.storagePath,
            mimeType: input.mimeType,
            fileSizeBytes: input.fileSizeBytes,
            resourceId: input.resourceId,
            eventId: input.eventId,
            createdAt: Date()
        )
        documents[id] = doc
        let contextId = input.contextActorId ?? input.resourceId.flatMap { resourceContext[$0] }
        if let contextId {
            emit(contextId, "document.created", payload: .object([
                "title": .string(input.title),
                "document_type": .string(input.documentType.rawValue)
            ]))
        }
        return DocumentRegistered(documentId: id)
    }

    public func listResourceDocuments(resourceId: UUID) async throws -> [Document] {
        try throwIfNeeded()
        return documents.values
            .filter { $0.resourceId == resourceId }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    public func uploadDocumentFile(path: String, data: Data, contentType: String) async throws {
        try throwIfNeeded()
        documentBlobs[path] = data
    }

    public func documentSignedURL(path: String, expiresIn: Int) async throws -> URL {
        try throwIfNeeded()
        return URL(string: "https://mock.ruul.test/documents/\(path)")!
    }

    // MARK: - Resources & rights

    public func resourceAvailableActions(resourceId: UUID, actorId: UUID) async throws -> [AvailableAction] {
        try throwIfNeeded()
        // El mock devuelve las mismas actions que resource_detail derivaría.
        let detail = try await resourceDetail(resourceId: resourceId)
        return detail.availableActions
    }

    public func resourceTypeCatalog() async throws -> ResourceTypeCatalog {
        try throwIfNeeded()
        // Cat catálogo mock — espejea los tipos del enum con capabilities razonables
        // (no es identico al backend live; el live lo provee resource_type_catalog).
        let entries: [ResourceTypeCatalogEntry] = ResourceType.allCases.map { type in
            ResourceTypeCatalogEntry(
                typeKey: type.rawValue,
                displayName: type.label,
                description: nil,
                icon: type.symbolName,
                capabilities: MockRuulRPCClient.mockCapabilities(for: type)
            )
        }
        return ResourceTypeCatalog(entries: entries)
    }

    /// Capabilities razonables para previews — NO es la verdad del backend.
    private static func mockCapabilities(for type: ResourceType) -> [String] {
        switch type {
        case .house, .property:
            return ["reservable", "ownership_trackable", "documentable", "maintainable", "auditable"]
        case .vehicle:
            return ["reservable", "ownership_trackable", "documentable", "maintainable", "depreciable"]
        case .security, .trustAsset, .digitalAsset:
            return ["ownership_trackable", "beneficiary_supported", "transferable", "auditable"]
        case .bankAccount, .cashPool:
            return ["monetary", "auditable", "ownership_trackable"]
        case .contract, .document:
            return ["documentable", "expirable", "approval_required"]
        case .reservation, .tripBooking, .game:
            return ["reservable"]
        case .equipment:
            return ["reservable", "shareable", "maintainable", "documentable"]
        case .other:
            return []
        }
    }

    public func createResource(_ input: CreateResourceInput) async throws -> Resource {
        try throwIfNeeded()
        let id = UUID()
        let resource = Resource(
            id: id,
            resourceType: input.resourceType,
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
        let resourceRights = rights[resourceId] ?? []
        let caps = Self.capabilities(for: resource.resourceType)
        let effective = effectiveRights(on: resourceId, rights: resourceRights)
        let actions = Self.actionCatalog
            .filter { action in
                (action.capability == nil || caps.contains(action.capability!))
                    && (action.rights.isEmpty || !action.rights.isDisjoint(with: effective))
            }
            .map { AvailableAction(actionKey: $0.key, label: $0.label, section: $0.section, enabled: true) }
        return ResourceDetail(
            resource: resource,
            rights: resourceRights,
            capabilities: caps,
            availableActions: actions,
            whyVisible: whyVisible(on: resourceId, rights: resourceRights)
        )
    }

    // MARK: R.2M-3 capability/action mirror (para previews y tests)

    /// Matriz tipo→capability alineada a la doctrina R.2M-3.
    static func capabilities(for resourceType: String) -> [String] {
        switch resourceType {
        case "house": return ["auditable", "maintainable", "ownership_trackable", "reservable"]
        case "property": return ["auditable", "ownership_trackable"]
        case "vehicle": return ["maintainable", "ownership_trackable", "reservable"]
        case "bank_account": return ["auditable", "monetary", "ownership_trackable"]
        case "cash_pool": return ["auditable", "monetary"]
        case "security": return ["auditable", "beneficiary_supported", "ownership_trackable", "transferable"]
        case "contract": return ["approval_required", "auditable", "documentable"]
        case "document": return ["documentable"]
        case "equipment": return ["maintainable", "ownership_trackable", "reservable"]
        case "trust_asset": return ["auditable", "beneficiary_supported", "ownership_trackable"]
        case "digital_asset": return ["auditable", "ownership_trackable", "transferable"]
        case "trip_booking": return ["documentable", "reservable", "transferable"]
        case "game": return ["auditable"]
        default: return ["auditable", "ownership_trackable"]
        }
    }

    struct ActionDef: Sendable { let key: String; let label: String; let section: String; let capability: String?; let rights: Set<String> }

    static let actionCatalog: [ActionDef] = [
        ActionDef(key: "view_reservations", label: "Ver reservaciones", section: "reservations", capability: "reservable", rights: ["VIEW", "USE", "MANAGE", "OWN", "GOVERN"]),
        ActionDef(key: "reserve_resource", label: "Reservar", section: "reservations", capability: "reservable", rights: ["USE", "MANAGE", "OWN"]),
        ActionDef(key: "manage_reservations", label: "Administrar reservas", section: "reservations", capability: "reservable", rights: ["MANAGE", "OWN", "GOVERN"]),
        ActionDef(key: "view_transactions", label: "Ver movimientos", section: "money", capability: "monetary", rights: ["VIEW", "MANAGE", "OWN", "GOVERN"]),
        ActionDef(key: "record_expense", label: "Registrar gasto", section: "money", capability: "monetary", rights: ["MANAGE", "OWN"]),
        ActionDef(key: "record_contribution", label: "Registrar aportación", section: "money", capability: "monetary", rights: ["MANAGE", "OWN"]),
        ActionDef(key: "generate_settlement", label: "Generar liquidación", section: "money", capability: "monetary", rights: ["MANAGE", "OWN", "GOVERN"]),
        ActionDef(key: "view_beneficiaries", label: "Ver beneficiarios", section: "beneficiaries", capability: "beneficiary_supported", rights: ["VIEW", "MANAGE", "OWN", "GOVERN", "BENEFICIARY"]),
        ActionDef(key: "grant_beneficiary", label: "Designar beneficiario", section: "beneficiaries", capability: "beneficiary_supported", rights: ["MANAGE", "OWN"]),
        ActionDef(key: "view_ownership", label: "Ver participaciones", section: "ownership", capability: "ownership_trackable", rights: ["VIEW", "USE", "MANAGE", "OWN", "GOVERN", "BENEFICIARY"]),
        ActionDef(key: "transfer_interest", label: "Transferir participación", section: "ownership", capability: "transferable", rights: ["OWN"]),
        ActionDef(key: "view_document", label: "Ver documento", section: "documents", capability: "documentable", rights: ["VIEW", "USE", "MANAGE", "OWN", "GOVERN"]),
        ActionDef(key: "review_document", label: "Revisar documento", section: "documents", capability: "documentable", rights: ["MANAGE", "OWN"]),
        ActionDef(key: "approve_document", label: "Aprobar", section: "approvals", capability: "approval_required", rights: ["MANAGE", "OWN", "GOVERN"]),
        ActionDef(key: "view_maintenance", label: "Ver mantenimiento", section: "maintenance", capability: "maintainable", rights: ["VIEW", "USE", "MANAGE", "OWN", "GOVERN"]),
        ActionDef(key: "log_maintenance", label: "Registrar mantenimiento", section: "maintenance", capability: "maintainable", rights: ["MANAGE", "OWN"]),
        ActionDef(key: "view_audit", label: "Ver auditoría", section: "audit", capability: "auditable", rights: ["VIEW", "MANAGE", "OWN", "GOVERN"]),
        ActionDef(key: "grant_right", label: "Otorgar derecho", section: "rights", capability: nil, rights: ["MANAGE", "OWN", "GOVERN"])
    ]

    /// Right kinds efectivos de `me` sobre el recurso: directos + vía contexto admin + VIEW por membresía.
    private func effectiveRights(on resourceId: UUID, rights resourceRights: [ResourceRight]) -> Set<String> {
        var result = Set<String>()
        for right in resourceRights where right.holderActorId == me.id {
            result.insert(right.rightKind)
        }
        for right in resourceRights where right.holderActorId != me.id {
            let members = memberships[right.holderActorId]
            if members?.contains(where: { $0.actorId == me.id && $0.isAdmin }) == true {
                result.insert(right.rightKind)
            }
            if members?.contains(where: { $0.actorId == me.id }) == true {
                result.insert("VIEW")
            }
        }
        return result
    }

    private func whyVisible(on resourceId: UUID, rights resourceRights: [ResourceRight]) -> [String] {
        var reasons: [String] = resourceRights.filter { $0.holderActorId == me.id }.map(\.rightKind)
        for right in resourceRights where right.holderActorId != me.id {
            if let holder = actors[right.holderActorId],
               memberships[right.holderActorId]?.contains(where: { $0.actorId == me.id }) == true {
                reasons.append("\(right.rightKind) via \(holder.displayName)")
            }
        }
        return Array(Set(reasons)).sorted()
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

    public func transferResourceOwnership(resourceId: UUID, toActorId: UUID, reason: String?) async throws -> TransferOwnershipResult {
        try throwIfNeeded()
        guard let resource = resources[resourceId] else {
            throw RuulError.unexpected(message: "Recurso no encontrado")
        }
        if me.id == toActorId {
            throw RuulError.unexpected(message: "cannot transfer ownership to yourself")
        }
        // Recipient debe tener can_own_resources.
        guard let recipient = actors[toActorId] else {
            throw RuulError.unexpected(message: "recipient actor not found")
        }
        let recipientCaps = Self.mockActorCapabilities(forSubtype: recipient.actorSubtype)
        guard recipientCaps.contains("can_own_resources") else {
            throw RuulError.unexpected(message: "recipient cannot own resources")
        }
        // Caller debe tener OWN activo.
        let callerOwn = (rights[resourceId] ?? []).filter { $0.holderActorId == me.id && $0.rightKind == "OWN" }
        guard !callerOwn.isEmpty else {
            throw RuulError.unexpected(message: "caller has no active OWN right on this resource")
        }

        let allNull = callerOwn.allSatisfy { $0.percent == nil }
        let totalPercent: Double? = allNull ? nil : callerOwn.compactMap { $0.percent }.reduce(0, +)

        // Revocar OWN del caller (en el mock, los removemos del array).
        rights[resourceId] = (rights[resourceId] ?? []).filter {
            !($0.holderActorId == me.id && $0.rightKind == "OWN")
        }

        // Otorgar OWN al recipient.
        let newRightId = UUID()
        rights[resourceId, default: []].append(ResourceRight(
            rightId: newRightId,
            holderActorId: toActorId,
            holderDisplayName: recipient.displayName,
            rightKind: "OWN",
            percent: totalPercent
        ))

        // canonical_owner si caller era el canonical.
        let wasCanonical = (resource.canonicalOwnerActorId == me.id)
        if wasCanonical {
            resources[resourceId] = Resource(
                id: resource.id,
                resourceType: resource.resourceType,
                displayName: resource.displayName,
                description: resource.description,
                estimatedValue: resource.estimatedValue,
                currency: resource.currency,
                canonicalOwnerActorId: toActorId,
                createdAt: resource.createdAt
            )
        }

        if let ctxId = resourceContext[resourceId] ?? resource.canonicalOwnerActorId {
            emit(ctxId, "right.transferred", payload: .object([
                "from": .string(me.id.uuidString),
                "to": .string(toActorId.uuidString),
                "right_kind": .string("OWN"),
                "reason": reason.map { .string($0) } ?? .null
            ]))
        }

        return TransferOwnershipResult(
            resourceId: resourceId,
            fromActorId: me.id,
            toActorId: toActorId,
            newRightId: newRightId,
            rightsRevoked: callerOwn.count,
            percentTotal: totalPercent,
            canonicalOwnerChanged: wasCanonical
        )
    }

    public func updateResource(_ input: UpdateResourceInput) async throws -> Resource {
        try throwIfNeeded()
        guard let existing = resources[input.resourceId] else {
            throw RuulError.unexpected(message: "Recurso no encontrado")
        }
        // Gate: solo OWN/MANAGE puede editar (espeja al backend).
        let myEffective = effectiveRights(on: input.resourceId, rights: rights[input.resourceId] ?? [])
        guard myEffective.contains("OWN") || myEffective.contains("MANAGE") else {
            throw RuulError.unexpected(message: "Necesitas OWN o MANAGE para editar el recurso")
        }
        let updated = Resource(
            id: existing.id,
            resourceType: existing.resourceType,
            displayName: input.displayName ?? existing.displayName,
            description: input.description ?? existing.description,
            estimatedValue: input.estimatedValue ?? existing.estimatedValue,
            currency: input.currency ?? existing.currency,
            canonicalOwnerActorId: existing.canonicalOwnerActorId,
            createdAt: existing.createdAt
        )
        resources[input.resourceId] = updated
        if let ctxId = resourceContext[input.resourceId] {
            emit(ctxId, "resource.updated", payload: .object([
                "resource_id": .string(input.resourceId.uuidString)
            ]))
        }
        return updated
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
            targetScope: input.targetScope,
            targetFilter: input.targetFilter,
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
            sourceEventId: input.sourceEventId,
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

    public func detectReservationConflicts(resourceId: UUID) async throws -> [ReservationConflict] {
        try throwIfNeeded()
        // El mock devuelve el mismo set persistido (no detecta dinámicamente).
        return try await listConflicts(resourceId: resourceId)
    }

    public func reservationDetail(reservationId: UUID) async throws -> ReservationDetail {
        try throwIfNeeded()
        guard let reservation = reservations[reservationId] else {
            throw RuulError.unexpected(message: "Reservación no encontrada")
        }
        let isMember = memberships[reservation.contextActorId]?.contains(where: { $0.actorId == me.id }) == true
        let resourceRights = rights[reservation.resourceId] ?? []
        let myEffectiveRights = effectiveRights(on: reservation.resourceId, rights: resourceRights)
        let canSeeViaResource = !myEffectiveRights.isEmpty
        guard isMember || canSeeViaResource else {
            throw RuulError.unexpected(message: "No autorizado para ver esta reservación")
        }

        let canManage = myEffectiveRights.contains("MANAGE") || myEffectiveRights.contains("OWN")
            || myEffectiveRights.contains("GOVERN")
            || (permissions[reservation.contextActorId] ?? []).contains("reservations.manage")
        let isParty = me.id == reservation.requestedByActorId || me.id == reservation.reservedForActorId
        let hasConflict = conflicts.values.contains { c in
            c.resolutionStatus == "open" && (c.reservationAId == reservationId || c.reservationBId == reservationId)
        }

        var actions: [AvailableAction] = []
        if reservation.status == "requested" {
            actions.append(AvailableAction(
                actionKey: "approve", label: "Aprobar", section: "reservations",
                enabled: canManage,
                reason: canManage ? "Puedes administrar reservaciones del recurso"
                                  : "Requiere MANAGE/OWN/GOVERN o permiso reservations.manage"
            ))
            actions.append(AvailableAction(
                actionKey: "reject", label: "Rechazar", section: "reservations",
                enabled: canManage,
                reason: canManage ? "Puedes administrar reservaciones del recurso"
                                  : "Requiere MANAGE/OWN/GOVERN o permiso reservations.manage"
            ))
        }
        if reservation.status == "approved" {
            actions.append(AvailableAction(
                actionKey: "confirm", label: "Confirmar", section: "reservations",
                enabled: isParty || canManage,
                reason: (isParty || canManage)
                    ? "Puedes confirmar esta reservación"
                    : "Solo quien reserva o un administrador puede confirmar"
            ))
        }
        if reservation.status == "requested" || reservation.status == "approved" || reservation.status == "confirmed" {
            actions.append(AvailableAction(
                actionKey: "cancel", label: "Cancelar", section: "reservations",
                enabled: isParty || canManage,
                reason: (isParty || canManage)
                    ? "Puedes cancelar esta reservación"
                    : "Solo quien reserva o un administrador puede cancelar"
            ))
        }
        if hasConflict {
            actions.append(AvailableAction(
                actionKey: "resolve_conflict", label: "Resolver conflicto", section: "reservations",
                enabled: canManage,
                reason: canManage ? "Hay un conflicto abierto que puedes resolver"
                                  : "Requiere administrar reservaciones del recurso"
            ))
        }

        return ReservationDetail(
            id: reservation.id,
            resourceId: reservation.resourceId,
            contextActorId: reservation.contextActorId,
            requestedByActorId: reservation.requestedByActorId,
            reservedForActorId: reservation.reservedForActorId,
            startsAt: reservation.startsAt,
            endsAt: reservation.endsAt,
            status: reservation.status,
            priorityScore: reservation.priorityScore,
            sourceDecisionId: nil,
            metadata: nil,
            availableActions: actions,
            createdAt: reservation.createdAt
        )
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
        _ = try await resolveReservationConflictWith(
            conflictId: conflictId,
            resolutionModel: .winner,
            winnerReservationId: winnerReservationId,
            metadata: nil
        )
    }

    public func resolveReservationConflictWith(
        conflictId: UUID,
        resolutionModel: ResolutionModel,
        winnerReservationId: UUID?,
        metadata: JSONValue?
    ) async throws -> ResolveConflictResult {
        try throwIfNeeded()
        guard let conflict = conflicts[conflictId] else {
            throw RuulError.backend(.unknown(message: "conflict not found"))
        }
        let aId = conflict.reservationAId
        let bId = conflict.reservationBId
        let contextId = reservations[aId]?.contextActorId ?? reservations[bId]?.contextActorId

        var winner: UUID?
        var loser: UUID?
        var splitAt: Date?
        var decisionId: UUID?
        var newStatus = "resolved"

        switch resolutionModel {
        case .winner, .priorityBased, .adminOverride:
            guard let w = winnerReservationId else {
                throw RuulError.backend(.validation(message: "winner required for \(resolutionModel.rawValue)"))
            }
            winner = w
            loser = (aId == w) ? bId : aId
            setReservationStatus(w, "approved")
            setReservationStatus(loser!, "rejected")

        case .lottery:
            let pick = Bool.random() ? aId : bId
            winner = pick
            loser = (aId == pick) ? bId : aId
            setReservationStatus(pick, "approved")
            setReservationStatus(loser!, "rejected")

        case .waitlisted:
            guard let w = winnerReservationId else {
                throw RuulError.backend(.validation(message: "winner required for waitlisted"))
            }
            winner = w
            loser = (aId == w) ? bId : aId
            setReservationStatus(w, "approved")
            setReservationStatus(loser!, "waitlisted")

        case .splitDates, .partialApproval:
            guard let resA = reservations[aId], let resB = reservations[bId] else {
                throw RuulError.backend(.unknown(message: "reservations missing"))
            }
            let overlapStart = max(resA.startsAt, resB.startsAt)
            let overlapEnd = min(resA.endsAt, resB.endsAt)
            let mid = Date(timeIntervalSince1970: (overlapStart.timeIntervalSince1970 + overlapEnd.timeIntervalSince1970) / 2)
            splitAt = mid
            setReservationStatus(aId, "approved")
            setReservationStatus(bId, "approved")

        case .requiresDecision:
            let id = UUID()
            decisionId = id
            // El conflicto queda abierto hasta que se ejecute la decisión.
            newStatus = "open"
        }

        if newStatus == "resolved" {
            conflicts[conflictId] = ReservationConflict(
                id: conflict.id,
                resourceId: conflict.resourceId,
                reservationAId: conflict.reservationAId,
                reservationBId: conflict.reservationBId,
                conflictType: conflict.conflictType,
                resolutionStatus: newStatus,
                recommendedWinnerActorId: conflict.recommendedWinnerActorId,
                createdAt: conflict.createdAt,
                resolvedAt: Date()
            )
        }

        if let contextId {
            emit(contextId, "reservation.conflict_resolved", payload: .object([
                "resolution_model": .string(resolutionModel.rawValue)
            ]))
        }

        return ResolveConflictResult(
            conflictId: conflictId,
            resolutionModel: resolutionModel.rawValue,
            resolutionStatus: newStatus,
            winnerReservationId: winner,
            loserReservationId: loser,
            splitAt: splitAt,
            decisionId: decisionId
        )
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
        let votingModel = input.votingModel?.rawValue
            ?? inferVotingModel(decisionType: input.decisionType, payload: input.payload)
        let decision = Decision(
            id: UUID(),
            contextActorId: input.contextId,
            decisionType: input.decisionType.rawValue,
            title: input.title,
            description: input.description,
            status: "open",
            votingModel: votingModel,
            createdByActorId: me.id,
            closesAt: input.closesAt,
            payload: input.payload,
            createdAt: Date()
        )
        decisions[decision.id] = decision
        decisionOptions[decision.id] = seedOptions(for: decision, payload: input.payload)
        emit(input.contextId, "decision.created")
        return decision
    }

    /// Espeja la heurística de `create_decision` en el backend (R.2Q).
    private func inferVotingModel(decisionType: DecisionType, payload: JSONValue?) -> String {
        if payload?["options"]?.arrayValue != nil {
            return "single_choice"
        }
        if decisionType == .reservationDispute,
           (payload?["conflict_id"]?.stringValue != nil
            || payload?["reservation_conflict_id"]?.stringValue != nil) {
            return "single_choice"
        }
        return "yes_no_abstain"
    }

    /// Espeja el trigger `_auto_seed_decision_options` del backend (R.2Q).
    private func seedOptions(for decision: Decision, payload: JSONValue?) -> [DecisionOption] {
        switch decision.voting {
        case .yesNoAbstain:
            return [
                DecisionOption(id: UUID(), decisionId: decision.id, optionKey: "approve", title: "A favor", sortOrder: 0),
                DecisionOption(id: UUID(), decisionId: decision.id, optionKey: "reject", title: "En contra", sortOrder: 1),
                DecisionOption(id: UUID(), decisionId: decision.id, optionKey: "abstain", title: "Abstención", sortOrder: 2),
            ]
        case .singleChoice:
            if let options = payload?["options"]?.arrayValue {
                return options.enumerated().compactMap { idx, opt in
                    guard let label = opt.stringValue else { return nil }
                    return DecisionOption(
                        id: UUID(),
                        decisionId: decision.id,
                        optionKey: label,
                        title: label,
                        sortOrder: idx
                    )
                }
            }
            // reservation_dispute con conflict_id: 4 opciones canónicas
            if decision.type == .reservationDispute,
               let conflictIdRaw = (payload?["conflict_id"]?.stringValue ?? payload?["reservation_conflict_id"]?.stringValue),
               let conflictId = UUID(uuidString: conflictIdRaw),
               let conflict = conflicts[conflictId] {
                let resA = reservations[conflict.reservationAId]
                let resB = reservations[conflict.reservationBId]
                let nameA = lookupActorName(resA?.reservedForActorId ?? resA?.requestedByActorId) ?? "Solicitud A"
                let nameB = lookupActorName(resB?.reservedForActorId ?? resB?.requestedByActorId) ?? "Solicitud B"
                return [
                    DecisionOption(
                        id: UUID(), decisionId: decision.id, optionKey: "award_a",
                        title: "Asignar a \(nameA)",
                        payload: .object([
                            "action": .string("reservation_award"),
                            "winner_reservation_id": .string(conflict.reservationAId.uuidString),
                            "conflict_id": .string(conflict.id.uuidString),
                        ]),
                        sortOrder: 0
                    ),
                    DecisionOption(
                        id: UUID(), decisionId: decision.id, optionKey: "award_b",
                        title: "Asignar a \(nameB)",
                        payload: .object([
                            "action": .string("reservation_award"),
                            "winner_reservation_id": .string(conflict.reservationBId.uuidString),
                            "conflict_id": .string(conflict.id.uuidString),
                        ]),
                        sortOrder: 1
                    ),
                    DecisionOption(
                        id: UUID(), decisionId: decision.id, optionKey: "split",
                        title: "Dividir fechas",
                        payload: .object([
                            "action": .string("split_reservation"),
                            "conflict_id": .string(conflict.id.uuidString),
                        ]),
                        sortOrder: 2
                    ),
                    DecisionOption(
                        id: UUID(), decisionId: decision.id, optionKey: "cancel",
                        title: "Cancelar ambas",
                        payload: .object([
                            "action": .string("cancel_reservations"),
                            "conflict_id": .string(conflict.id.uuidString),
                        ]),
                        sortOrder: 3
                    ),
                ]
            }
            return []
        default:
            return []
        }
    }

    private func lookupActorName(_ actorId: UUID?) -> String? {
        guard let actorId else { return nil }
        return actors[actorId]?.displayName
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
        let resolvedOptionId: UUID? = {
            if let option {
                return decisionOptions[decisionId]?.first(where: { $0.optionKey == option })?.id
            }
            return decisionOptions[decisionId]?.first(where: { $0.optionKey == vote.rawValue })?.id
        }()
        var decisionVotes = votes[decisionId] ?? []
        // R.2Q-6: branch por voting_model.
        if decision.voting == .multipleChoice {
            // Duplicate (voter, option) → no-op idempotente.
            let alreadyVoted = decisionVotes.contains {
                $0.voterActorId == me.id && $0.optionId == resolvedOptionId
            }
            if !alreadyVoted {
                decisionVotes.append(DecisionVote(
                    id: UUID(), decisionId: decisionId, voterActorId: me.id,
                    vote: vote.rawValue, optionId: resolvedOptionId, votedAt: Date()
                ))
            }
        } else {
            // yes_no_abstain / single_choice: 1 vote per voter (reemplaza el anterior).
            decisionVotes = decisionVotes.filter { $0.voterActorId != me.id }
            decisionVotes.append(DecisionVote(
                id: UUID(), decisionId: decisionId, voterActorId: me.id,
                vote: vote.rawValue, optionId: resolvedOptionId, votedAt: Date()
            ))
        }
        votes[decisionId] = decisionVotes

        let members = memberships[decision.contextActorId]?.count ?? 1
        let approve = decisionVotes.filter { $0.vote == "approve" }.count
        let reject = decisionVotes.filter { $0.vote == "reject" }.count
        var status = decision.status
        var winningOption: String?
        var winningOptionId: UUID?

        if decision.voting == .multipleChoice {
            // Sin auto-finalize — cierre manual con close_decision.
        } else if decision.voting == .singleChoice {
            let tally = Dictionary(grouping: decisionVotes.compactMap { $0.optionId }, by: { $0 })
                .mapValues(\.count)
            if let (topId, topCount) = tally.max(by: { $0.value < $1.value }),
               topCount > members / 2 || (decisionVotes.count >= members && topCount > 0) {
                status = "approved"
                winningOptionId = topId
                winningOption = decisionOptions[decisionId]?.first(where: { $0.id == topId })?.optionKey
                emit(decision.contextActorId, "decision.approved")
            }
        } else {
            if Double(approve) > Double(members) / 2 {
                status = "approved"
                winningOption = "approve"
                winningOptionId = decisionOptions[decisionId]?.first(where: { $0.optionKey == "approve" })?.id
                emit(decision.contextActorId, "decision.approved")
            } else if Double(reject) >= Double(members) / 2 && approve + (members - decisionVotes.count) <= members / 2 {
                status = "rejected"
                winningOption = "reject"
                winningOptionId = decisionOptions[decisionId]?.first(where: { $0.optionKey == "reject" })?.id
                emit(decision.contextActorId, "decision.rejected")
            }
        }
        setDecisionStatus(decisionId, status, winningOption: winningOption, winningOptionId: winningOptionId)
        return VoteResult(
            decisionId: decisionId,
            myVote: vote.rawValue,
            myOptionId: resolvedOptionId,
            status: status,
            winningOption: winningOption,
            winningOptionId: winningOptionId,
            tally: VoteTally(approve: approve, reject: reject, members: members)
        )
    }

    public func listDecisionOptions(decisionId: UUID) async throws -> [DecisionOption] {
        try throwIfNeeded()
        return (decisionOptions[decisionId] ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    public func unvoteOption(decisionId: UUID, optionId: UUID) async throws -> UnvoteResult {
        try throwIfNeeded()
        guard let decision = decisions[decisionId] else {
            throw RuulError.unexpected(message: "Decisión no encontrada")
        }
        guard decision.voting == .multipleChoice else {
            throw RuulError.unexpected(message: "unvote_option solo aplica a multiple_choice")
        }
        let before = votes[decisionId] ?? []
        let after = before.filter { !($0.voterActorId == me.id && $0.optionId == optionId) }
        let removed = before.count != after.count
        votes[decisionId] = after
        if removed {
            emit(decision.contextActorId, "decision.vote_removed", payload: .object([
                "decision_id": .string(decisionId.uuidString),
                "option_id": .string(optionId.uuidString)
            ]))
        }
        return UnvoteResult(decisionId: decisionId, optionId: optionId, removed: removed)
    }

    public func decisionDetail(decisionId: UUID) async throws -> DecisionDetail {
        try throwIfNeeded()
        guard let decision = decisions[decisionId] else {
            throw RuulError.unexpected(message: "Decisión no encontrada")
        }
        guard memberships[decision.contextActorId]?.contains(where: { $0.actorId == me.id }) == true else {
            throw RuulError.unexpected(message: "No autorizado para ver esta decisión")
        }
        let votesList = votes[decisionId] ?? []
        let detailOptions: [DecisionDetailOption] = (decisionOptions[decisionId] ?? [])
            .filter(\.isActive)
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { option in
                DecisionDetailOption(
                    id: option.id,
                    optionKey: option.optionKey,
                    title: option.title,
                    description: option.description,
                    payload: option.payload,
                    sortOrder: option.sortOrder,
                    votes: votesList.filter { $0.optionId == option.id }.count
                )
            }
        let myPerms = permissions[decision.contextActorId] ?? []
        let canVote = myPerms.contains("decisions.vote") || myPerms.contains("decisions.create")
        let canManage = myPerms.contains("decisions.execute") || myPerms.contains("context.manage")
        let alreadyVoted = votesList.contains { $0.voterActorId == me.id }

        var actions: [AvailableAction] = []
        switch decision.status {
        case "open":
            if alreadyVoted {
                actions.append(AvailableAction(
                    actionKey: "change_vote", label: "Cambiar voto", section: "decisions",
                    enabled: canVote,
                    reason: canVote ? "Ya votaste; puedes cambiar tu voto"
                                    : "No tienes permiso para votar en este contexto"
                ))
            } else {
                actions.append(AvailableAction(
                    actionKey: "vote", label: "Votar", section: "decisions",
                    enabled: canVote,
                    reason: canVote ? "La decisión está abierta y puedes votar"
                                    : "No tienes permiso para votar en este contexto"
                ))
            }
            actions.append(AvailableAction(
                actionKey: "close_decision", label: "Cerrar votación", section: "decisions",
                enabled: canManage,
                reason: canManage ? "Puedes cerrar la votación" : "Requiere permiso decisions.execute"
            ))
            actions.append(AvailableAction(
                actionKey: "cancel_decision", label: "Cancelar decisión", section: "decisions",
                enabled: canManage,
                reason: canManage ? "Puedes cancelar la decisión" : "Requiere permiso decisions.execute"
            ))
        case "approved", "rejected":
            actions.append(AvailableAction(
                actionKey: "execute_decision", label: "Ejecutar resultado", section: "decisions",
                enabled: canManage,
                reason: canManage ? "La decisión está cerrada y lista para ejecutar"
                                  : "Requiere permiso decisions.execute"
            ))
        default:
            break
        }

        return DecisionDetail(
            id: decision.id,
            contextActorId: decision.contextActorId,
            decisionType: decision.decisionType,
            votingModel: decision.votingModel,
            title: decision.title,
            description: decision.description,
            status: decision.status,
            opensAt: decision.createdAt,
            closesAt: decision.closesAt,
            decidedAt: decision.decidedAt,
            executedAt: decision.executedAt,
            payload: decision.payload,
            result: decision.result,
            options: detailOptions,
            votesCount: votesList.count,
            availableActions: actions,
            createdAt: decision.createdAt
        )
    }

    public func voteForOption(decisionId: UUID, optionId: UUID) async throws -> VoteResult {
        guard let option = decisionOptions[decisionId]?.first(where: { $0.id == optionId }) else {
            throw RuulError.unexpected(message: "Opción no encontrada")
        }
        let voteValue: VoteChoice = {
            switch option.optionKey {
            case "reject": return .reject
            case "abstain": return .abstain
            default: return .approve
            }
        }()
        return try await voteDecision(decisionId: decisionId, vote: voteValue, option: option.optionKey)
    }

    public func createDecisionOption(_ input: CreateDecisionOptionInput) async throws -> DecisionOption {
        try throwIfNeeded()
        guard decisions[input.decisionId] != nil else {
            throw RuulError.unexpected(message: "Decisión no encontrada")
        }
        let existing = decisionOptions[input.decisionId] ?? []
        let nextOrder = input.sortOrder ?? ((existing.map(\.sortOrder).max() ?? -1) + 1)
        let option = DecisionOption(
            id: UUID(),
            decisionId: input.decisionId,
            optionKey: input.optionKey,
            title: input.title.trimmingCharacters(in: .whitespaces),
            description: input.description,
            payload: input.payload,
            sortOrder: nextOrder,
            status: "active",
            createdAt: Date()
        )
        decisionOptions[input.decisionId] = existing + [option]
        return option
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
        var status: String
        var winningOption: String?
        var winningOptionId: UUID?

        if decision.voting == .singleChoice {
            let tally = Dictionary(grouping: decisionVotes.compactMap { $0.optionId }, by: { $0 })
                .mapValues(\.count)
            if let (topId, _) = tally.max(by: { $0.value < $1.value }) {
                status = "approved"
                winningOptionId = topId
                winningOption = decisionOptions[decisionId]?.first(where: { $0.id == topId })?.optionKey
            } else {
                status = "rejected"
            }
        } else {
            status = approve > reject ? "approved" : "rejected"
            winningOption = status == "approved" ? "approve" : "reject"
            winningOptionId = decisionOptions[decisionId]?.first(where: { $0.optionKey == winningOption })?.id
        }

        setDecisionStatus(decisionId, status, winningOption: winningOption, winningOptionId: winningOptionId)
        emit(decision.contextActorId, "decision.\(status)")
        return VoteResult(
            decisionId: decisionId,
            status: status,
            winningOption: winningOption,
            winningOptionId: winningOptionId,
            tally: VoteTally(approve: approve, reject: reject, members: members)
        )
    }

    public func executeDecision(decisionId: UUID, result: JSONValue?) async throws {
        try throwIfNeeded()
        guard let decision = decisions[decisionId], decision.isApproved else {
            throw RuulError.backend(.validation(message: "decision is not approved"))
        }
        setDecisionStatus(decisionId, "executed", winningOption: decision.winningOptionKey, winningOptionId: decision.winningOptionId)
        emit(decision.contextActorId, "decision.executed")
    }

    private func setDecisionStatus(_ id: UUID, _ status: String, winningOption: String? = nil, winningOptionId: UUID? = nil) {
        guard let d = decisions[id] else { return }
        var newResult: JSONValue? = d.result
        if winningOption != nil || winningOptionId != nil {
            var obj: [String: JSONValue] = d.result?.objectValue ?? [:]
            if let winningOption { obj["winning_option"] = .string(winningOption) }
            if let winningOptionId { obj["winning_option_id"] = .string(winningOptionId.uuidString) }
            newResult = .object(obj)
        }
        decisions[id] = Decision(
            id: d.id,
            contextActorId: d.contextActorId,
            decisionType: d.decisionType,
            title: d.title,
            description: d.description,
            status: status,
            votingModel: d.votingModel,
            createdByActorId: d.createdByActorId,
            closesAt: d.closesAt,
            decidedAt: status == "approved" || status == "rejected" ? Date() : d.decidedAt,
            executedAt: status == "executed" ? Date() : d.executedAt,
            payload: d.payload,
            result: newResult,
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

    // MARK: - R.2R Obligations universales

    public func createActionObligation(_ input: CreateActionObligationInput) async throws -> ActionObligationCreated {
        try throwIfNeeded()
        let validKinds = ["action","approval","delivery","attendance","document","reservation","custom"]
        guard validKinds.contains(input.kind) else {
            throw RuulError.unexpected(message: "invalid obligation_kind: \(input.kind)")
        }
        guard !input.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RuulError.unexpected(message: "title is required for an action obligation")
        }
        guard memberships[input.contextId]?.contains(where: { $0.actorId == me.id }) == true else {
            throw RuulError.unexpected(message: "no eres miembro del contexto")
        }
        let myPerms = permissions[input.contextId] ?? []
        if input.debtorActorId != me.id, !myPerms.contains("members.manage") {
            throw RuulError.unexpected(message: "assigning obligations to others requires members.manage")
        }

        let id = UUID()
        let obligation = Obligation(
            id: id,
            contextActorId: input.contextId,
            debtorActorId: input.debtorActorId,
            creditorActorId: input.creditorActorId ?? input.contextId,
            obligationType: "other",
            obligationKind: input.kind,
            amount: nil,
            currency: nil,
            status: "open",
            dueAt: input.dueAt,
            sourceEventId: input.sourceEventId,
            sourceRuleId: nil,
            sourceDecisionId: input.sourceDecisionId,
            sourceReservationId: input.sourceReservationId,
            title: input.title.trimmingCharacters(in: .whitespaces),
            description: input.description,
            completedAt: nil,
            completedByActorId: nil,
            completionNotes: nil,
            createdAt: Date()
        )
        obligations[id] = obligation
        emit(input.contextId, "obligation.created", actorId: me.id, payload: .object([
            "kind": .string(input.kind),
            "title": .string(input.title),
            "debtor": .string(input.debtorActorId.uuidString)
        ]))
        return ActionObligationCreated(obligationId: id, kind: input.kind, status: "open")
    }

    public func completeObligation(obligationId: UUID, completionNotes: String?, completionMetadata: JSONValue?) async throws -> ObligationCompletedResult {
        try throwIfNeeded()
        guard let existing = obligations[obligationId] else {
            throw RuulError.unexpected(message: "obligación no encontrada")
        }
        if existing.obligationKind == "money" {
            throw RuulError.unexpected(message: "money obligations are settled, not completed")
        }
        let myPerms = existing.contextActorId.flatMap { permissions[$0] } ?? []
        let isParty = existing.debtorActorId == me.id || existing.creditorActorId == me.id
        guard isParty || myPerms.contains("members.manage") else {
            throw RuulError.unexpected(message: "no autorizado para completar esta obligación")
        }
        if existing.status == "completed" {
            return try JSONDecoder.ruul.decode(
                ObligationCompletedResult.self,
                from: Data("""
                {"obligation_id": "\(existing.id.uuidString)", "status": "completed", "already_completed": true}
                """.utf8)
            )
        }
        let terminal: Set<String> = ["cancelled","expired","forgiven","settled","disputed"]
        guard !terminal.contains(existing.status) else {
            throw RuulError.unexpected(message: "no se puede completar una obligación en estado \(existing.status)")
        }

        let now = Date()
        obligations[obligationId] = Obligation(
            id: existing.id,
            contextActorId: existing.contextActorId,
            debtorActorId: existing.debtorActorId,
            creditorActorId: existing.creditorActorId,
            obligationType: existing.obligationType,
            obligationKind: existing.obligationKind,
            amount: existing.amount,
            currency: existing.currency,
            status: "completed",
            dueAt: existing.dueAt,
            sourceEventId: existing.sourceEventId,
            sourceRuleId: existing.sourceRuleId,
            sourceDecisionId: existing.sourceDecisionId,
            sourceReservationId: existing.sourceReservationId,
            title: existing.title,
            description: existing.description,
            completedAt: now,
            completedByActorId: me.id,
            completionNotes: completionNotes,
            createdAt: existing.createdAt
        )
        if let ctxId = existing.contextActorId {
            emit(ctxId, "obligation.completed", actorId: me.id, payload: .object([
                "kind": .string(existing.obligationKind),
                "title": .string(existing.title ?? existing.obligationType),
                "completed_by": .string(me.id.uuidString),
                "debtor": .string(existing.debtorActorId.uuidString)
            ]))
        }
        return ObligationCompletedResult(
            obligationId: existing.id,
            status: "completed",
            completedBy: me.id,
            completedAt: now,
            alreadyCompleted: false
        )
    }

    public func obligationDetail(obligationId: UUID) async throws -> ObligationDetail {
        try throwIfNeeded()
        guard let obligation = obligations[obligationId] else {
            throw RuulError.unexpected(message: "obligación no encontrada")
        }
        let ctxId = obligation.contextActorId
        let isParty = obligation.debtorActorId == me.id || obligation.creditorActorId == me.id
        let isMember = ctxId.flatMap { memberships[$0] }?.contains(where: { $0.actorId == me.id }) == true
        guard isParty || isMember else {
            throw RuulError.unexpected(message: "no autorizado para ver esta obligación")
        }

        let active: Set<String> = ["open","accepted","in_progress"]
        let myPerms = ctxId.flatMap { permissions[$0] } ?? []
        let isDebtor = obligation.debtorActorId == me.id
        let isCreditor = obligation.creditorActorId == me.id
        let isManager = myPerms.contains("money.settle") || myPerms.contains("members.manage")
        var actions: [AvailableAction] = []
        if obligation.obligationKind == "money", active.contains(obligation.status) {
            actions.append(AvailableAction(
                actionKey: "pay", label: "Pagar", section: "obligations",
                enabled: isDebtor,
                reason: isDebtor ? "Eres el deudor de esta obligación" : "Solo el deudor puede pagar"
            ))
        }
        if obligation.obligationKind != "money", active.contains(obligation.status) {
            let canComplete = isParty || isManager
            actions.append(AvailableAction(
                actionKey: "mark_completed", label: "Marcar como cumplida", section: "obligations",
                enabled: canComplete,
                reason: canComplete ? "Participas en esta obligación" : "Solo deudor, acreedor o un administrador pueden marcarla"
            ))
        }
        if ["open","accepted","in_progress","completed"].contains(obligation.status) {
            actions.append(AvailableAction(
                actionKey: "dispute", label: "Disputar", section: "obligations",
                enabled: isParty,
                reason: isParty ? "Eres parte de la obligación" : "Solo deudor o acreedor pueden disputar"
            ))
        }
        if active.contains(obligation.status) {
            actions.append(AvailableAction(
                actionKey: "forgive", label: "Condonar", section: "obligations",
                enabled: isCreditor,
                reason: isCreditor ? "Eres el acreedor y puedes condonar" : "Solo el acreedor puede condonar"
            ))
            actions.append(AvailableAction(
                actionKey: "cancel", label: "Cancelar", section: "obligations",
                enabled: isCreditor || isManager,
                reason: (isCreditor || isManager) ? "Eres acreedor o administrador" : "Solo el acreedor o un administrador pueden cancelar"
            ))
        }

        return ObligationDetail(
            id: obligation.id,
            contextActorId: obligation.contextActorId,
            kind: obligation.obligationKind,
            obligationType: obligation.obligationType,
            status: obligation.status,
            title: obligation.title,
            description: obligation.description,
            amount: obligation.amount,
            currency: obligation.currency,
            dueAt: obligation.dueAt,
            debtorActorId: obligation.debtorActorId,
            creditorActorId: obligation.creditorActorId,
            completedAt: obligation.completedAt,
            completedByActorId: obligation.completedByActorId,
            completionNotes: obligation.completionNotes,
            sourceEventId: obligation.sourceEventId,
            sourceRuleId: obligation.sourceRuleId,
            sourceReservationId: obligation.sourceReservationId,
            sourceDecisionId: obligation.sourceDecisionId,
            metadata: nil,
            availableActions: actions,
            createdAt: obligation.createdAt
        )
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

    // MARK: - Explanation engine (R.2S.10)

    public func whyCanViewResource(actorId: UUID, resourceId: UUID) async throws -> WhyCanViewResource {
        try throwIfNeeded()
        let allRights = rights[resourceId] ?? []
        let mine = allRights.filter { $0.holderActorId == actorId }
        var reasons: [String] = []
        if let resource = resources[resourceId], resource.canonicalOwnerActorId == actorId {
            reasons.append("Es el dueño canónico del recurso (OWN dominante)")
        }
        for right in mine {
            reasons.append("Tiene el derecho \(right.rightKind) sobre el recurso")
        }
        let canView = !mine.isEmpty || resources[resourceId]?.canonicalOwnerActorId == actorId
        if reasons.isEmpty {
            reasons = ["No tiene ningún derecho activo ni autoridad sobre un holder del recurso"]
        }
        return WhyCanViewResource(actorId: actorId, resourceId: resourceId, canView: canView, reasons: reasons)
    }

    public func whyCanReserve(actorId: UUID, resourceId: UUID) async throws -> WhyCanReserve {
        try throwIfNeeded()
        guard let resource = resources[resourceId] else {
            throw RuulError.unexpected(message: "Recurso no encontrado")
        }
        let caps = Self.capabilities(for: resource.resourceType)
        let isReservable = caps.contains("reservable")
        let actorRights = (rights[resourceId] ?? []).filter { $0.holderActorId == actorId }
        let hasRight = actorRights.contains {
            $0.rightKind == "USE" || $0.rightKind == "MANAGE" || $0.rightKind == "OWN"
        }
        var reasons: [String] = []
        if isReservable {
            reasons.append("El recurso es reservable")
        } else {
            reasons.append("El tipo \"\(resource.resourceType)\" no tiene la capability reservable")
        }
        if isReservable && !hasRight {
            reasons.append("Falta un derecho USE, MANAGE u OWN (o autoridad para administrar reservaciones)")
        } else if hasRight {
            reasons.append("Tiene un derecho que habilita reservar")
        }
        return WhyCanReserve(
            actorId: actorId,
            resourceId: resourceId,
            canReserve: isReservable && hasRight,
            requiredCapability: "reservable",
            reasons: reasons
        )
    }

    public func whyDecisionResult(decisionId: UUID) async throws -> WhyDecisionResult {
        try throwIfNeeded()
        guard let decision = decisions[decisionId] else {
            throw RuulError.unexpected(message: "Decisión no encontrada")
        }
        let votesList = votes[decisionId] ?? []
        let approve = Double(votesList.filter { $0.vote == "approve" }.count)
        let reject = Double(votesList.filter { $0.vote == "reject" }.count)
        let abstain = Double(votesList.filter { $0.vote == "abstain" }.count)
        let members = Double(memberships[decision.contextActorId]?.count ?? 0)

        var optionTally: [String: Double] = [:]
        let options = decisionOptions[decisionId] ?? []
        for option in options {
            let count = votesList.filter { $0.optionId == option.id }.count
            if count > 0 { optionTally[option.title] = Double(count) }
        }

        var reasons: [String] = []
        reasons.append("Modelo de votación: \(decision.votingModel)")
        reasons.append("Conteo: \(Int(approve)) a favor, \(Int(reject)) en contra, \(Int(abstain)) abstención sobre \(Int(members)) miembros")
        if let winning = decision.result?["winning_option"]?.stringValue {
            reasons.append("Opción ganadora: \(winning)")
        }
        reasons.append("Estado actual: \(decision.status)")

        return WhyDecisionResult(
            decisionId: decisionId,
            status: decision.status,
            votingModel: decision.votingModel,
            tally: WhyDecisionTally(approve: approve, reject: reject, abstain: abstain),
            optionTally: optionTally,
            activeMembers: members,
            result: decision.result,
            reasons: reasons
        )
    }

    public func whyReservationWon(conflictId: UUID) async throws -> WhyReservationWon {
        try throwIfNeeded()
        guard let conflict = conflicts[conflictId] else {
            throw RuulError.unexpected(message: "Conflicto no encontrado")
        }
        var reasons: [String] = []
        if conflict.resolutionStatus != "resolved" {
            reasons.append("El conflicto aún no se resuelve")
            return WhyReservationWon(
                conflictId: conflictId,
                resolutionStatus: conflict.resolutionStatus,
                recommendedWinnerActorId: conflict.recommendedWinnerActorId,
                reasons: reasons
            )
        }
        let a = reservations[conflict.reservationAId]
        let b = reservations[conflict.reservationBId]
        let winner: Reservation? = (a?.status == "approved" || a?.status == "confirmed") ? a : b
        if conflict.recommendedWinnerActorId != nil {
            reasons.append("El motor de conflictos había recomendado a este actor")
        }
        reasons.append("Lo resolvió un administrador con autoridad sobre las reservaciones")
        return WhyReservationWon(
            conflictId: conflictId,
            resolutionStatus: conflict.resolutionStatus,
            winnerReservationId: winner?.id,
            winnerActorId: winner?.reservedForActorId ?? winner?.requestedByActorId,
            recommendedWinnerActorId: conflict.recommendedWinnerActorId,
            reasons: reasons
        )
    }

    public func whyObligationExists(obligationId: UUID) async throws -> WhyObligationExists {
        try throwIfNeeded()
        guard let obligation = obligations[obligationId] else {
            throw RuulError.unexpected(message: "Obligación no encontrada")
        }
        let source: String
        if obligation.sourceRuleId != nil { source = "rule" }
        else if obligation.sourceEventId != nil { source = "event" }
        else { source = "manual" }
        let ruleTitle: String? = obligation.sourceRuleId.flatMap { ruleId in
            rules.values.flatMap { $0 }.first { $0.id == ruleId }?.title
        }
        return WhyObligationExists(
            obligationId: obligationId,
            kind: "money", // R.2R kind aún no en el domain — defaultea a money.
            source: source,
            reason: ruleTitle ?? obligation.typeLabel,
            sourceRuleId: obligation.sourceRuleId,
            sourceDecisionId: nil,
            sourceEventId: obligation.sourceEventId,
            sourceReservationId: nil,
            ruleTitle: ruleTitle,
            metadata: nil
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
        public static let viajeJapon = UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!
        // R.2U — Familia Mizrahi → { Comidas, Mundial, Proyecto Nave → Fideicomiso }
        public static let comidasMiercoles = UUID(uuidString: "00000000-0000-0000-0000-0000000000c4")!
        public static let mundialPalco2026 = UUID(uuidString: "00000000-0000-0000-0000-0000000000c5")!
        public static let proyectoNave = UUID(uuidString: "00000000-0000-0000-0000-0000000000c6")!
        public static let fideicomiso = UUID(uuidString: "00000000-0000-0000-0000-0000000000c7")!
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
        // Registrar a cada friend en `actors` para que las RPCs que requieren
        // actor_kind/subtype (p. ej. transfer_resource_ownership con check de
        // actor_can('can_own_resources')) funcionen contra el mock.
        for friend in friends where actors[friend.0] == nil {
            actors[friend.0] = ActorRecord(
                id: friend.0,
                actorKind: .person,
                actorSubtype: "person",
                displayName: friend.1
            )
        }

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

        // R.2U — Jerarquía Mizrahi: Familia → { Comidas, Mundial, Proyecto → Fideicomiso }
        let comidas = ActorRecord(id: DemoIds.comidasMiercoles, actorKind: .collective, actorSubtype: "community", displayName: "Comidas Miércoles")
        actors[comidas.id] = comidas
        memberships[comidas.id] = [
            ContextMember(actorId: DemoIds.jose, displayName: "José", membershipType: "founder", joinedAt: Date(), roles: ["admin"])
        ]
        permissions[comidas.id] = MockRuulRPCClient.allPermissions

        let mundial = ActorRecord(id: DemoIds.mundialPalco2026, actorKind: .collective, actorSubtype: "friend_group", displayName: "Mundial Palco 2026")
        actors[mundial.id] = mundial
        memberships[mundial.id] = [
            ContextMember(actorId: DemoIds.jose, displayName: "José", membershipType: "founder", joinedAt: Date(), roles: ["admin"])
        ]
        permissions[mundial.id] = MockRuulRPCClient.allPermissions

        let proyecto = ActorRecord(id: DemoIds.proyectoNave, actorKind: .collective, actorSubtype: "project", displayName: "Proyecto Nave Industrial")
        actors[proyecto.id] = proyecto
        memberships[proyecto.id] = [
            ContextMember(actorId: DemoIds.jose, displayName: "José", membershipType: "founder", joinedAt: Date(), roles: ["admin"])
        ]
        permissions[proyecto.id] = MockRuulRPCClient.allPermissions

        let fideo = ActorRecord(id: DemoIds.fideicomiso, actorKind: .legalEntity, actorSubtype: "trust", displayName: "Fideicomiso Nave Industrial")
        actors[fideo.id] = fideo
        memberships[fideo.id] = [
            ContextMember(actorId: DemoIds.jose, displayName: "José", membershipType: "founder", joinedAt: Date(), roles: ["admin"])
        ]
        permissions[fideo.id] = MockRuulRPCClient.allPermissions

        contextChildrenById[familia.id] = [comidas.id, mundial.id, proyecto.id]
        contextChildrenById[proyecto.id] = [fideo.id]

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

        // Documento adjunto a Casa Valle (escritura).
        let escritura = Document(
            id: UUID(),
            ownerActorId: DemoIds.jose,
            contextActorId: familia.id,
            title: "Escritura Casa Valle",
            documentType: .contract,
            storagePath: "\(familia.id)/escritura-casa-valle.pdf",
            mimeType: "application/pdf",
            fileSizeBytes: 482_136,
            resourceId: casa.id,
            createdAt: Date().addingTimeInterval(-86400 * 30)
        )
        documents[escritura.id] = escritura

        // Invitación pendiente: Isaac invitó a José a "Viaje a Japón 2026".
        let viaje = ActorRecord(
            id: DemoIds.viajeJapon,
            actorKind: .collective,
            actorSubtype: "trip",
            displayName: "Viaje a Japón 2026"
        )
        actors[viaje.id] = viaje
        pendingInvitations[DemoIds.jose] = [
            PendingInvitation(
                membershipId: UUID(),
                contextActorId: viaje.id,
                contextDisplayName: viaje.displayName,
                contextActorKind: viaje.actorKind,
                contextActorSubtype: viaje.actorSubtype,
                invitedAt: Date().addingTimeInterval(-3600)
            )
        ]
    }
}
