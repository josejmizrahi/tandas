import Foundation

/// Contrato Swift ↔ backend MVP 2.0. Cada método mapea 1:1 a un RPC
/// (`Plans/Active/MVP2_iOS_Contract.md`) o a una lectura PostgREST directa
/// (tablas read-only vía RLS). El frontend NO inventa lógica: el backend
/// valida todo y este protocolo solo transporta.
public protocol RuulRPCClient: Sendable {

    // MARK: - Identity

    /// `ensure_person_actor()` — idempotente; crea el person actor si no existe.
    func ensurePersonActor() async throws -> CurrentActor
    /// `update_my_profile(...)`
    func updateMyProfile(fullName: String?, preferredName: String?, avatarUrl: String?) async throws -> CurrentActor
    /// `update_my_profile(p_metadata := ...)` — F.1A-1: setea slot del metadata jsonb.
    func updateMyProfileMetadata(_ metadata: JSONValue) async throws -> CurrentActor
    /// `personal_settings_summary()` — F.1A-1.
    func personalSettingsSummary() async throws -> PersonalSettings
    /// `context_settings_summary(p_context_actor_id)` — F.1A-2.
    func contextSettingsSummary(contextId: UUID) async throws -> ContextSettings
    /// `resource_settings_summary(p_resource_id)` — F.1A-3.
    func resourceSettingsSummary(resourceId: UUID) async throws -> ResourceSettings

    // MARK: - Actor capabilities (R.2S.1)

    /// `actor_capabilities(p_actor_id)` — capabilities universales del actor
    /// (subtype + overrides). El frontend NO deriva comportamiento por subtype.
    func actorCapabilities(actorId: UUID) async throws -> ActorCapabilities
    /// `actor_capabilities_catalog()` — catálogo global + matriz subtype→capabilities.
    func actorCapabilitiesCatalog() async throws -> ActorCapabilitiesCatalog
    /// `actor_can(p_actor_id, p_capability)` — boolean.
    func actorCan(actorId: UUID, capability: String) async throws -> Bool

    // MARK: - Contexts

    /// `context_candidates()`
    func contextCandidates() async throws -> ContextCandidates
    /// `context_summary(p_context_actor_id)`
    func contextSummary(contextId: UUID) async throws -> ContextSummary
    /// `my_world()`
    func myWorld() async throws -> MyWorld
    /// `create_context(...)`
    func createContext(_ input: CreateContextInput) async throws -> CreatedContext

    // MARK: - Invites & membership

    /// `create_invite(...)`
    func createInvite(contextId: UUID, maxUses: Int?, expiresAt: Date?) async throws -> InviteCreated
    /// `revoke_invite(p_invite_id)`
    func revokeInvite(inviteId: UUID) async throws
    /// `join_by_invite_code(p_code)`
    func joinByInviteCode(_ code: String) async throws -> JoinResult
    /// `remove_member(...)`
    func removeMember(contextId: UUID, memberActorId: UUID, reason: String?) async throws
    /// `leave_context(p_context_actor_id)`
    func leaveContext(contextId: UUID) async throws
    /// `assign_role(...)`
    func assignRole(contextId: UUID, memberActorId: UUID, roleKey: String) async throws

    // MARK: - Resources & rights

    /// `create_resource(...)`
    func createResource(_ input: CreateResourceInput) async throws -> Resource
    /// `list_context_resources(p_context_actor_id)`
    func listContextResources(contextId: UUID) async throws -> [ContextResource]
    /// `resource_detail(p_resource_id)`
    func resourceDetail(resourceId: UUID) async throws -> ResourceDetail
    /// `grant_right(...)` → right id
    func grantRight(_ input: GrantRightInput) async throws -> UUID
    /// `revoke_right(p_right_id)`
    func revokeRight(rightId: UUID) async throws
    /// `archive_resource(p_resource_id)`
    func archiveResource(resourceId: UUID) async throws
    /// `update_resource(p_resource_id, p_display_name?, p_description?, p_estimated_value?, p_currency?, p_metadata?)`
    /// — F.1A polish: editor general + metadata (policies). Devuelve el recurso actualizado.
    func updateResource(_ input: UpdateResourceInput) async throws -> Resource

    // MARK: - Events

    /// `create_calendar_event(...)`
    func createCalendarEvent(_ input: CreateEventInput) async throws -> CalendarEvent
    /// Lectura PostgREST: `calendar_events` del contexto (más recientes primero).
    func listEvents(contextId: UUID) async throws -> [CalendarEvent]
    /// Lectura PostgREST: un evento por id.
    func getEvent(eventId: UUID) async throws -> CalendarEvent
    /// Lectura PostgREST: `event_participants` del evento.
    func listEventParticipants(eventId: UUID) async throws -> [EventParticipant]
    /// `rsvp_event(p_event_id, p_status)`
    func rsvpEvent(eventId: UUID, status: RSVPStatus) async throws
    /// `check_in_participant(p_event_id, p_participant_actor_id?)`
    func checkInParticipant(eventId: UUID, participantActorId: UUID?) async throws -> CheckInResult
    /// `cancel_participation(p_event_id)`
    func cancelParticipation(eventId: UUID) async throws -> CancelParticipationResult
    /// `close_event(p_event_id)`
    func closeEvent(eventId: UUID) async throws -> CloseEventResult

    // MARK: - Rules

    /// `create_rule(...)`
    func createRule(_ input: CreateRuleInput) async throws -> Rule
    /// Lectura PostgREST: `rules` activas/pausadas del contexto.
    func listRules(contextId: UUID) async throws -> [Rule]

    // MARK: - Reservations

    /// `request_resource_reservation(...)`
    func requestReservation(_ input: RequestReservationInput) async throws -> ReservationRequestResult
    /// Lectura PostgREST: reservaciones de un recurso.
    func listReservations(resourceId: UUID) async throws -> [Reservation]
    /// Lectura PostgREST: reservaciones de un contexto.
    func listContextReservations(contextId: UUID) async throws -> [Reservation]
    /// Lectura PostgREST: conflictos abiertos de un recurso.
    func listConflicts(resourceId: UUID) async throws -> [ReservationConflict]
    /// `reservation_detail(p_reservation_id)` — R.2S: detalle + `available_actions` canónicos.
    func reservationDetail(reservationId: UUID) async throws -> ReservationDetail
    /// `approve_reservation(p_reservation_id)`
    func approveReservation(reservationId: UUID) async throws
    /// `confirm_reservation(p_reservation_id)`
    func confirmReservation(reservationId: UUID) async throws
    /// `cancel_reservation(p_reservation_id)`
    func cancelReservation(reservationId: UUID) async throws
    /// `resolve_reservation_conflict(p_conflict_id, p_winner_reservation_id)`
    func resolveReservationConflict(conflictId: UUID, winnerReservationId: UUID) async throws

    // MARK: - Decisions

    /// `create_decision(...)`
    func createDecision(_ input: CreateDecisionInput) async throws -> Decision
    /// Lectura PostgREST: `decisions` del contexto.
    func listDecisions(contextId: UUID) async throws -> [Decision]
    /// Lectura PostgREST: `decision_votes` de una decisión.
    func listDecisionVotes(decisionId: UUID) async throws -> [DecisionVote]
    /// `vote_decision(p_decision_id, p_vote, p_option?)`
    func voteDecision(decisionId: UUID, vote: VoteChoice, option: String?) async throws -> VoteResult
    /// `close_decision(p_decision_id)`
    func closeDecision(decisionId: UUID) async throws -> VoteResult
    /// `execute_decision(p_decision_id, p_result?)`
    func executeDecision(decisionId: UUID, result: JSONValue?) async throws
    /// `decision_detail(p_decision_id)` — R.2S: detalle + `available_actions` canónicos.
    func decisionDetail(decisionId: UUID) async throws -> DecisionDetail
    /// `list_decision_options(p_decision_id)` — R.2Q.
    func listDecisionOptions(decisionId: UUID) async throws -> [DecisionOption]
    /// `vote_for_option(p_decision_id, p_option_id)` — R.2Q.
    func voteForOption(decisionId: UUID, optionId: UUID) async throws -> VoteResult
    /// `create_decision_option(...)` — R.2Q.
    func createDecisionOption(_ input: CreateDecisionOptionInput) async throws -> DecisionOption

    // MARK: - Money

    /// `record_expense(...)`
    func recordExpense(_ input: RecordExpenseInput) async throws -> ExpenseResult
    /// `record_fine(...)` → obligation id
    func recordFine(contextId: UUID, debtorActorId: UUID, amount: Double, currency: String, reason: String?) async throws -> UUID
    /// `record_game_result(...)`
    func recordGameResult(_ input: RecordGameResultInput) async throws -> GameResultRecorded
    /// Lectura PostgREST: `obligations` del contexto.
    func listObligations(contextId: UUID) async throws -> [Obligation]
    /// `create_action_obligation(...)` — R.2R obligaciones de acción (no money).
    func createActionObligation(_ input: CreateActionObligationInput) async throws -> ActionObligationCreated
    /// `complete_obligation(p_obligation_id, p_completion_notes?, p_completion_metadata?)` — R.2R.
    func completeObligation(obligationId: UUID, completionNotes: String?, completionMetadata: JSONValue?) async throws -> ObligationCompletedResult
    /// `obligation_detail(p_obligation_id)` — R.2R: detalle + `available_actions`.
    func obligationDetail(obligationId: UUID) async throws -> ObligationDetail

    // MARK: - Settlement

    /// `generate_settlement_batch(p_context_actor_id, p_currency)`
    func generateSettlementBatch(contextId: UUID, currency: String) async throws -> SettlementBatchResult
    /// Lectura PostgREST: `settlement_batches` del contexto.
    func listSettlementBatches(contextId: UUID) async throws -> [SettlementBatch]
    /// Lectura PostgREST: `settlement_items` de un batch.
    func listSettlementItems(batchId: UUID) async throws -> [SettlementItem]
    /// `mark_settlement_paid(p_settlement_item_id)`
    func markSettlementPaid(itemId: UUID) async throws -> MarkPaidResult

    // MARK: - Explanation engine (R.2S.10)

    /// `why_can_view_resource(p_actor_id, p_resource_id)`.
    func whyCanViewResource(actorId: UUID, resourceId: UUID) async throws -> WhyCanViewResource
    /// `why_can_reserve(p_actor_id, p_resource_id)`.
    func whyCanReserve(actorId: UUID, resourceId: UUID) async throws -> WhyCanReserve
    /// `why_decision_result(p_decision_id)`.
    func whyDecisionResult(decisionId: UUID) async throws -> WhyDecisionResult
    /// `why_reservation_won(p_conflict_id)`.
    func whyReservationWon(conflictId: UUID) async throws -> WhyReservationWon
    /// `why_obligation_exists(p_obligation_id)`.
    func whyObligationExists(obligationId: UUID) async throws -> WhyObligationExists

    // MARK: - Activity

    /// `list_activity(p_context_actor_id, p_limit, p_before)`
    func listActivity(contextId: UUID, limit: Int, before: Date?) async throws -> [ActivityEvent]
}

// MARK: - Inputs

/// Input de `create_context`.
public struct CreateContextInput: Sendable, Equatable {
    public var displayName: String
    /// `collective` o `legal_entity`.
    public var actorKind: ActorKind
    /// `friend_group`, `family`, `trip`, `community`, `company`, `trust`, `project`, `other`.
    public var actorSubtype: String
    public var visibility: String

    public init(
        displayName: String,
        actorKind: ActorKind = .collective,
        actorSubtype: String = "friend_group",
        visibility: String = "private"
    ) {
        self.displayName = displayName
        self.actorKind = actorKind
        self.actorSubtype = actorSubtype
        self.visibility = visibility
    }
}

/// Input de `create_resource`.
public struct CreateResourceInput: Sendable, Equatable {
    public var contextId: UUID
    public var resourceType: ResourceType
    public var displayName: String
    public var description: String?
    public var estimatedValue: Double?
    public var currency: String?
    public var clientId: String?

    public init(
        contextId: UUID,
        resourceType: ResourceType,
        displayName: String,
        description: String? = nil,
        estimatedValue: Double? = nil,
        currency: String? = nil,
        clientId: String? = nil
    ) {
        self.contextId = contextId
        self.resourceType = resourceType
        self.displayName = displayName
        self.description = description
        self.estimatedValue = estimatedValue
        self.currency = currency
        self.clientId = clientId
    }
}

/// Input de `update_resource`. Todos los campos son opcionales — solo se aplica
/// lo que llegue distinto de nil. `metadata` es jsonb (incluye policies por capability).
public struct UpdateResourceInput: Sendable, Equatable {
    public var resourceId: UUID
    public var displayName: String?
    public var description: String?
    public var estimatedValue: Double?
    public var currency: String?
    public var metadata: JSONValue?

    public init(
        resourceId: UUID,
        displayName: String? = nil,
        description: String? = nil,
        estimatedValue: Double? = nil,
        currency: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.resourceId = resourceId
        self.displayName = displayName
        self.description = description
        self.estimatedValue = estimatedValue
        self.currency = currency
        self.metadata = metadata
    }
}

/// Input de `grant_right`.
public struct GrantRightInput: Sendable, Equatable {
    public var resourceId: UUID
    public var holderActorId: UUID
    public var rightKind: RightKind
    public var percent: Double?
    public var scope: String?
    public var startsAt: Date?
    public var endsAt: Date?

    public init(
        resourceId: UUID,
        holderActorId: UUID,
        rightKind: RightKind,
        percent: Double? = nil,
        scope: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil
    ) {
        self.resourceId = resourceId
        self.holderActorId = holderActorId
        self.rightKind = rightKind
        self.percent = percent
        self.scope = scope
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

/// Input de `create_calendar_event`.
public struct CreateEventInput: Sendable, Equatable {
    public var contextId: UUID
    public var title: String
    public var eventType: EventType
    public var startsAt: Date
    public var endsAt: Date?
    public var description: String?
    public var locationText: String?
    /// `weekly` para cenas recurrentes con host rotativo.
    public var recurrenceRule: String?
    public var hostActorId: UUID?
    public var inviteAllMembers: Bool
    public var clientId: String?

    public init(
        contextId: UUID,
        title: String,
        eventType: EventType,
        startsAt: Date,
        endsAt: Date? = nil,
        description: String? = nil,
        locationText: String? = nil,
        recurrenceRule: String? = nil,
        hostActorId: UUID? = nil,
        inviteAllMembers: Bool = true,
        clientId: String? = nil
    ) {
        self.contextId = contextId
        self.title = title
        self.eventType = eventType
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.description = description
        self.locationText = locationText
        self.recurrenceRule = recurrenceRule
        self.hostActorId = hostActorId
        self.inviteAllMembers = inviteAllMembers
        self.clientId = clientId
    }
}

/// Input de `create_rule`.
public struct CreateRuleInput: Sendable, Equatable {
    public var contextId: UUID
    public var title: String
    public var triggerEventType: String?
    public var conditionTree: JSONValue?
    public var consequences: JSONValue?
    public var body: String?
    public var ruleType: String
    public var severity: Int

    public init(
        contextId: UUID,
        title: String,
        triggerEventType: String? = nil,
        conditionTree: JSONValue? = nil,
        consequences: JSONValue? = nil,
        body: String? = nil,
        ruleType: String = "automation",
        severity: Int = 1
    ) {
        self.contextId = contextId
        self.title = title
        self.triggerEventType = triggerEventType
        self.conditionTree = conditionTree
        self.consequences = consequences
        self.body = body
        self.ruleType = ruleType
        self.severity = severity
    }
}

/// Input de `request_resource_reservation`.
public struct RequestReservationInput: Sendable, Equatable {
    public var resourceId: UUID
    public var contextId: UUID
    public var startsAt: Date
    public var endsAt: Date
    public var reservedForActorId: UUID?
    public var clientId: String?

    public init(
        resourceId: UUID,
        contextId: UUID,
        startsAt: Date,
        endsAt: Date,
        reservedForActorId: UUID? = nil,
        clientId: String? = nil
    ) {
        self.resourceId = resourceId
        self.contextId = contextId
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.reservedForActorId = reservedForActorId
        self.clientId = clientId
    }
}

/// Input de `create_decision`.
public struct CreateDecisionInput: Sendable, Equatable {
    public var contextId: UUID
    public var decisionType: DecisionType
    public var title: String
    public var description: String?
    public var closesAt: Date?
    public var payload: JSONValue?
    public var clientId: String?
    /// R.2Q — override del voting_model. Si es nil, el backend autodetecta.
    public var votingModel: VotingModel?

    public init(
        contextId: UUID,
        decisionType: DecisionType,
        title: String,
        description: String? = nil,
        closesAt: Date? = nil,
        payload: JSONValue? = nil,
        clientId: String? = nil,
        votingModel: VotingModel? = nil
    ) {
        self.contextId = contextId
        self.decisionType = decisionType
        self.title = title
        self.description = description
        self.closesAt = closesAt
        self.payload = payload
        self.clientId = clientId
        self.votingModel = votingModel
    }
}

/// Input de `create_decision_option` — R.2Q.
public struct CreateDecisionOptionInput: Sendable, Equatable {
    public var decisionId: UUID
    public var optionKey: String
    public var title: String
    public var description: String?
    public var payload: JSONValue?
    public var sortOrder: Int?

    public init(
        decisionId: UUID,
        optionKey: String,
        title: String,
        description: String? = nil,
        payload: JSONValue? = nil,
        sortOrder: Int? = nil
    ) {
        self.decisionId = decisionId
        self.optionKey = optionKey
        self.title = title
        self.description = description
        self.payload = payload
        self.sortOrder = sortOrder
    }
}

/// Un renglón del split custom de `record_expense`.
public struct ExpenseSplit: Sendable, Equatable, Identifiable {
    public var actorId: UUID
    public var amount: Double

    public init(actorId: UUID, amount: Double) {
        self.actorId = actorId
        self.amount = amount
    }

    public var id: UUID { actorId }
}

/// Input de `record_expense`.
public struct RecordExpenseInput: Sendable, Equatable {
    public var contextId: UUID
    public var amount: Double
    public var currency: String
    public var description: String
    /// Participantes explícitos del split equal (nil = todos los miembros activos).
    public var splitWith: [UUID]?
    /// Actores excluidos del split.
    public var excludedActorIds: [UUID]?
    /// `equal` o `custom`.
    public var splitMethod: String
    /// Splits custom (deben sumar `amount`).
    public var splits: [ExpenseSplit]?
    public var eventId: UUID?
    public var paidByActorId: UUID?
    public var clientId: String?

    public init(
        contextId: UUID,
        amount: Double,
        currency: String,
        description: String,
        splitWith: [UUID]? = nil,
        excludedActorIds: [UUID]? = nil,
        splitMethod: String = "equal",
        splits: [ExpenseSplit]? = nil,
        eventId: UUID? = nil,
        paidByActorId: UUID? = nil,
        clientId: String? = nil
    ) {
        self.contextId = contextId
        self.amount = amount
        self.currency = currency
        self.description = description
        self.splitWith = splitWith
        self.excludedActorIds = excludedActorIds
        self.splitMethod = splitMethod
        self.splits = splits
        self.eventId = eventId
        self.paidByActorId = paidByActorId
        self.clientId = clientId
    }
}

/// Input de `create_action_obligation` (R.2R). `kind` ∈ action/approval/delivery/
/// attendance/document/reservation/custom. NO acepta `money` (eso va por record_*).
public struct CreateActionObligationInput: Sendable, Equatable {
    public var contextId: UUID
    public var debtorActorId: UUID
    public var title: String
    public var kind: String
    public var description: String?
    public var dueAt: Date?
    public var creditorActorId: UUID?
    public var sourceEventId: UUID?
    public var sourceReservationId: UUID?
    public var sourceDecisionId: UUID?
    public var metadata: JSONValue?
    public var clientId: String?

    public init(
        contextId: UUID,
        debtorActorId: UUID,
        title: String,
        kind: String = "action",
        description: String? = nil,
        dueAt: Date? = nil,
        creditorActorId: UUID? = nil,
        sourceEventId: UUID? = nil,
        sourceReservationId: UUID? = nil,
        sourceDecisionId: UUID? = nil,
        metadata: JSONValue? = nil,
        clientId: String? = nil
    ) {
        self.contextId = contextId
        self.debtorActorId = debtorActorId
        self.title = title
        self.kind = kind
        self.description = description
        self.dueAt = dueAt
        self.creditorActorId = creditorActorId
        self.sourceEventId = sourceEventId
        self.sourceReservationId = sourceReservationId
        self.sourceDecisionId = sourceDecisionId
        self.metadata = metadata
        self.clientId = clientId
    }
}

/// Input de `record_game_result`.
public struct RecordGameResultInput: Sendable, Equatable {
    public var contextId: UUID
    public var eventId: UUID?
    public var gameName: String
    public var winnerActorId: UUID
    public var loserActorId: UUID
    public var amount: Double
    public var currency: String
    public var clientId: String?

    public init(
        contextId: UUID,
        eventId: UUID? = nil,
        gameName: String,
        winnerActorId: UUID,
        loserActorId: UUID,
        amount: Double,
        currency: String = "MXN",
        clientId: String? = nil
    ) {
        self.contextId = contextId
        self.eventId = eventId
        self.gameName = gameName
        self.winnerActorId = winnerActorId
        self.loserActorId = loserActorId
        self.amount = amount
        self.currency = currency
        self.clientId = clientId
    }
}
