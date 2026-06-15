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
    /// `update_context(p_context_actor_id, display_name?, description?, visibility?, image_url?, decisions_config?, money_config?, reservations_config?, invitations_config?)` — F.1A polish.
    /// Devuelve el `ContextSettings` actualizado para refresh inmediato.
    func updateContext(_ input: UpdateContextInput) async throws -> ContextSettings
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
    /// `context_detail_descriptor(p_context_actor_id)` — R.5A.B.7. Descriptor
    /// consolidado (context+membership+my_permissions+roles+sections+widgets+
    /// actions+metrics+8 previews). ContextDetailView v2 (tabs).
    func contextDetailDescriptor(contextId: UUID) async throws -> ContextDetailDescriptor
    /// `my_world()`
    func myWorld() async throws -> MyWorld
    /// `create_context(...)`
    func createContext(_ input: CreateContextInput) async throws -> CreatedContext
    /// `archive_context(p_context_actor_id)` — FE.7. Soft archive vía
    /// `actors.archived_at`. Permiso: `members.manage`. PULL gate doctrine
    /// R.7: si policy `context_archive_requires_vote` está unset o `true`,
    /// raise `governance_required` (42501); el caller debe pasar primero por
    /// `request_governance_action('context.archive', target=context_actor_id)`.
    /// Idempotente: si ya estaba archivado retorna `already_archived=true`.
    func archiveContext(contextActorId: UUID) async throws -> ContextArchivedResult

    // MARK: - Context hierarchy (R.2U)

    /// `context_children(p_context_actor_id)` — hijos directos activos.
    func contextChildren(contextId: UUID) async throws -> [ContextHierarchyNode]
    /// `context_parents(p_context_actor_id)` — padres directos activos.
    func contextParents(contextId: UUID) async throws -> [ContextHierarchyNode]
    /// `context_tree(p_root_context_actor_id)` — árbol completo descendente.
    /// Subárboles donde el caller no es miembro vienen con `restricted = true`.
    func contextTree(rootContextId: UUID) async throws -> ContextTreeNode
    /// `context_ancestors(p_context_actor_id)` — padre → abuelo → … con `depth`.
    func contextAncestors(contextId: UUID) async throws -> [ContextHierarchyNode]
    /// `context_descendants(p_context_actor_id)` — todos los descendientes plano.
    func contextDescendants(contextId: UUID) async throws -> [ContextHierarchyNode]
    /// `create_child_context(...)` — crea contexto hijo. Caller deviene
    /// founder/admin del child. Requiere `context.children.create` en el padre.
    func createChildContext(_ input: CreateChildContextInput) async throws -> CreatedChildContext
    /// `link_child_context(p_parent, p_child)` — vincula contexto existente.
    /// Requiere `context.children.link` en padre + `context.manage` en child.
    func linkChildContext(parentId: UUID, childId: UUID) async throws -> LinkChildContextResult
    /// `unlink_child_context(p_parent, p_child)` — soft-end. Requiere
    /// `context.children.unlink` en padre. Idempotente.
    func unlinkChildContext(parentId: UUID, childId: UUID) async throws -> UnlinkChildContextResult

    // MARK: - Invites & membership

    /// `create_invite(...)`
    func createInvite(contextId: UUID, maxUses: Int?, expiresAt: Date?) async throws -> InviteCreated
    /// `revoke_invite(p_invite_id)`
    func revokeInvite(inviteId: UUID) async throws
    /// `join_by_invite_code(p_code)`
    func joinByInviteCode(_ code: String) async throws -> JoinResult
    /// `invite_member(p_context_actor_id, p_member_actor_id, p_membership_type)` —
    /// invitación directa actor→actor (status='invited' hasta accept).
    func inviteMember(contextId: UUID, memberActorId: UUID, membershipType: String) async throws -> InviteMemberResult
    /// R.5W — `create_placeholder_person(...)` — crea un actor placeholder
    /// (persona sin app) con membership activa. Caso Splitwise: agregar a la
    /// abuela / tío / vecino para que aparezcan en splits y obligaciones
    /// aunque nunca se registren. Slice 4 agregará claim/merge cuando se
    /// registren con teléfono/email match.
    func createPlaceholderPerson(
        contextId: UUID,
        displayName: String,
        phone: String?,
        email: String?,
        membershipType: String
    ) async throws -> PlaceholderPersonResult
    /// R.5W Slice 4 — `find_placeholder_matches_for_me()`. Caller recién
    /// registrado consulta si hay placeholders con su phone/email match.
    func findPlaceholderMatchesForMe() async throws -> PlaceholderMatchesResult
    /// R.5W Slice 4 — `claim_placeholder_actor(p_placeholder_actor_id)`.
    /// Backend reasigna toda la historia del placeholder → caller.
    func claimPlaceholderActor(placeholderActorId: UUID) async throws -> ClaimPlaceholderResult
    /// `accept_invitation(p_context_actor_id)` — el caller acepta una invitación
    /// pendiente y queda como miembro activo. Idempotente: `already_member=true`
    /// si ya era miembro.
    func acceptInvitation(contextId: UUID) async throws -> AcceptInvitationResult
    /// `decline_invitation(p_context_actor_id)` — el caller rechaza una invitación
    /// pendiente (invited → declined). Idempotente. FE.1 (P0.1).
    func declineInvitation(contextId: UUID) async throws
    /// `delete_my_account()` — FE.3 (V.1, App Store 5.1.1(v) + ARCO). Pseudonimiza
    /// la identidad, sale de los contextos y borra las credenciales; los átomos
    /// del grupo se conservan no identificables. El cliente debe hacer signOut()
    /// inmediatamente después.
    func deleteMyAccount() async throws

    /// P1.5 — `set_membership_state(p_context, p_member, p_target_state, p_reason)`.
    /// target ∈ active/paused/banned. El backend se auto-gatea: si la policy del
    /// contexto exige voto, lanza `governance_required` (42501) y la UI enruta
    /// a request_governance_action.
    func setMembershipState(contextId: UUID, memberActorId: UUID, targetState: String, reason: String?) async throws

    /// P1.8 — lectura PostgREST del catálogo R.7 (`governance_action_catalog`,
    /// RLS read-all authenticated): qué acciones requieren decisión por default.
    func listGovernanceActionCatalog() async throws -> [GovernanceCatalogEntry]

    /// P1.2 — sube el avatar a Storage (`avatars/{actorId}/...`, bucket público)
    /// y devuelve la URL pública para guardarla vía `update_my_profile`.
    func uploadAvatar(actorId: UUID, data: Data, contentType: String) async throws -> URL

    // MARK: - Notificaciones (R.4D, P1.1)

    /// Lectura PostgREST: `notifications` del caller (RLS recipient-only),
    /// sin archivadas, `created_at DESC`.
    func listMyNotifications(limit: Int) async throws -> [RuulNotification]
    /// `mark_notification_read(p_notification_id)`
    func markNotificationRead(notificationId: UUID) async throws
    /// `mark_notification_archived(p_notification_id)`
    func markNotificationArchived(notificationId: UUID) async throws
    /// `mark_all_notifications_read(p_context_actor_id default null)`
    func markAllNotificationsRead(contextId: UUID?) async throws
    /// Lectura PostgREST: invitaciones pendientes del actor (`actor_memberships`
    /// con `member_actor_id = actor AND membership_status = 'invited'`, embebido
    /// con `actors` para el nombre del contexto).
    func listMyPendingInvitations(actorId: UUID) async throws -> [PendingInvitation]
    /// `remove_member(...)`
    func removeMember(contextId: UUID, memberActorId: UUID, reason: String?) async throws
    /// `leave_context(p_context_actor_id)`
    func leaveContext(contextId: UUID) async throws
    /// `assign_role(...)`
    func assignRole(contextId: UUID, memberActorId: UUID, roleKey: String) async throws

    // MARK: - Resources & rights

    /// `create_resource(...)`
    func createResource(_ input: CreateResourceInput) async throws -> Resource
    /// `resource_type_catalog()` — catálogo global de tipos (labels, iconos,
    /// capabilities, metadata esperada). El frontend NO hardcodea: el catálogo
    /// es la fuente de verdad para qué tipos existen y cómo presentarlos.
    func resourceTypeCatalog() async throws -> ResourceTypeCatalog
    /// R.5A.B.0 — 17 classes top-level de la taxonomía de recursos.
    func listResourceClasses() async throws -> [ResourceClass]
    /// R.5A.B.0 — Subtypes filtrados por class (o todos si classKey=nil). 42 seeded.
    func listResourceSubtypes(classKey: String?) async throws -> [ResourceSubtype]
    /// `resource_available_actions(resource, actor)` — refresca solo las
    /// available_actions sin pedir el `resource_detail` completo (útil tras
    /// `grant_right` / `revoke_right` para actualizar botones).
    func resourceAvailableActions(resourceId: UUID, actorId: UUID) async throws -> [AvailableAction]
    /// `list_context_resources(p_context_actor_id)`
    func listContextResources(contextId: UUID) async throws -> [ContextResource]
    /// `resource_detail(p_resource_id)`
    func resourceDetail(resourceId: UUID) async throws -> ResourceDetail
    /// `resource_detail_descriptor(p_resource_id)` — R.5A.B.6. Descriptor consolidado
    /// (class+subtype+effective_capabilities+rights+sections+widgets+actions+action_forms+
    /// state+metrics+relations+linked_documents+activity_preview). ResourceDetailView v2.
    func resourceDetailDescriptor(resourceId: UUID) async throws -> ResourceDetailDescriptor
    /// `list_resource_actions(p_resource_id)` — R.5A.B.8. Subset standalone del
    /// descriptor.actions[] para refresh barato post-execute.
    func listResourceActions(resourceId: UUID) async throws -> [ResourceDescriptorAction]
    /// `execute_resource_action(p_resource_id, p_action_key, p_payload, p_client_id?)`
    /// — R.5A.B.8. Dispatcher canónico: gate via available_actions, branch
    /// execute vs request_decision, delegate a RPC vivo, emit activity_event.
    func executeResourceAction(
        resourceId: UUID,
        actionKey: String,
        payload: JSONValue,
        clientId: UUID?
    ) async throws -> ExecuteResourceActionResult
    /// `grant_right(...)` → right id
    func grantRight(_ input: GrantRightInput) async throws -> UUID
    /// `revoke_right(p_right_id)`
    func revokeRight(rightId: UUID) async throws
    /// `archive_resource(p_resource_id)`
    func archiveResource(resourceId: UUID) async throws
    /// `transfer_resource_ownership(p_resource_id, p_to_actor_id, p_reason?)` — F.1A polish.
    /// Atómico: revoca todos los OWN del caller y otorga uno equivalente al recipient.
    func transferResourceOwnership(resourceId: UUID, toActorId: UUID, reason: String?) async throws -> TransferOwnershipResult
    /// `update_resource(p_resource_id, p_display_name?, p_description?, p_estimated_value?, p_currency?, p_metadata?)`
    /// — F.1A polish: editor general + metadata (policies). Devuelve el recurso actualizado.
    func updateResource(_ input: UpdateResourceInput) async throws -> Resource

    // MARK: - Events

    /// `create_calendar_event(...)`
    func createCalendarEvent(_ input: CreateEventInput) async throws -> CalendarEvent
    /// `update_calendar_event(...)` — F.EVENT.7. Host del evento o `events.manage`.
    /// Sólo eventos no terminales. NULL = no cambiar. Devuelve el evento actualizado.
    func updateCalendarEvent(_ input: UpdateEventInput) async throws -> CalendarEvent
    /// Lectura PostgREST: `calendar_events` del contexto (más recientes primero).
    func listEvents(contextId: UUID) async throws -> [CalendarEvent]
    /// Lectura PostgREST: un evento por id.
    func getEvent(eventId: UUID) async throws -> CalendarEvent
    /// Lectura PostgREST: `event_participants` del evento.
    func listEventParticipants(eventId: UUID) async throws -> [EventParticipant]
    /// `event_detail(p_event_id)` — F.2X.0 wrapper canónico.
    /// Devuelve event + participants[] + available_actions[] + capabilities[]
    /// + why_visible[]. Misma forma que resource/decision/reservation/obligation.
    func eventDetail(eventId: UUID) async throws -> EventDetail
    /// `rsvp_event(p_event_id, p_status)`
    func rsvpEvent(eventId: UUID, status: RSVPStatus) async throws
    /// `check_in_participant(p_event_id, p_participant_actor_id?)`
    func checkInParticipant(eventId: UUID, participantActorId: UUID?) async throws -> CheckInResult
    /// `cancel_participation(p_event_id)`
    func cancelParticipation(eventId: UUID) async throws -> CancelParticipationResult
    /// `close_event(p_event_id)`
    func closeEvent(eventId: UUID) async throws -> CloseEventResult
    /// `add_event_participants(p_event_id, p_actor_ids[])` — R.5Z.fix.EVENT.PARTICIPANTS.
    /// Host o `events.manage`. Idempotent: ignora actors ya participants.
    /// Solo agrega members activos del contexto del evento.
    func addEventParticipants(eventId: UUID, actorIds: [UUID]) async throws
    /// `remove_event_participants(p_event_id, p_actor_ids[])` — R.5Z.fix.EVENT.PARTICIPANTS.
    /// Host o `events.manage`. Soft remove (status='cancelled' + cancelled_at).
    func removeEventParticipants(eventId: UUID, actorIds: [UUID]) async throws
    /// `set_event_participant_plus_count(p_event_id, p_actor_id, p_count)` —
    /// R.5Z.fix.EVENT.PLUS_N. El propio participant, host o admin.
    /// Guarda en `event_participants.metadata.plus_count`. Cuenta como N
    /// unidades adicionales en el split del gasto (0..20).
    func setEventParticipantPlusCount(eventId: UUID, actorId: UUID, count: Int) async throws
    /// `add_event_guest(p_event_id, p_display_name, p_count_share?, p_linked_actor_id?, p_source?)` —
    /// R.5Z.fix.EVENT.GUESTS MVP1. Cualquier participant del evento o host/admin.
    /// MVP1 solo soporta source='manual' (display name escrito). Phase 2:
    /// source='actor' (linked_actor_id) + cross-context picker.
    func addEventGuest(eventId: UUID, displayName: String, countShare: Int, linkedActorId: UUID?, source: String) async throws -> EventGuestAdded
    /// `remove_event_guest(p_guest_id)` — R.5Z.fix.EVENT.GUESTS.
    /// El invitante, host o events.manage. Soft delete.
    func removeEventGuest(guestId: UUID) async throws
    /// `list_event_guests(p_event_id)` — R.5Z.fix.EVENT.GUESTS.
    /// Members del contexto del evento.
    func listEventGuests(eventId: UUID) async throws -> [EventGuest]
    /// `host_confirm_participant(p_event_id, p_actor_id)` — R.5Z.fix.EVENT.HOST_CONFIRM.
    /// Host o `events.manage` puede setear status='going' a un participant
    /// en su nombre. Emite attention al participant para que confirme/cambie.
    func hostConfirmParticipant(eventId: UUID, actorId: UUID) async throws

    /// F.EVENT.8 — `preview_next_host(p_event_id)`. Devuelve quién será el
    /// próximo anfitrión sin mutar nada. Para eventos no recurrentes los
    /// campos quedan nil.
    func previewNextHost(eventId: UUID) async throws -> NextHostPreview

    /// F.EVENT.8 — `set_next_host(p_event_id, p_actor_id)`. Override de un
    /// solo uso: al cerrar el evento se aplica y luego se limpia. Requiere
    /// permiso `events.manage`.
    func setNextHost(eventId: UUID, actorId: UUID) async throws -> NextHostPreview

    /// F.EVENT.10 — `set_host_rotation_order(p_event_id, p_actor_ids)`.
    /// Configura el ciclo de rotación de host para esta serie. La lista se
    /// recorre cíclicamente al cerrar cada evento weekly. `nil` limpia el
    /// orden y vuelve a la rotación natural (joined_at). Requiere
    /// `events.manage`.
    func setHostRotationOrder(eventId: UUID, actorIds: [UUID]?) async throws

    // MARK: - Rules

    /// `create_rule(...)`
    func createRule(_ input: CreateRuleInput) async throws -> Rule
    /// `update_rule(p_rule_id, p_title?, p_body?, p_trigger_event_type?, p_condition_tree?, p_consequences?, p_target_scope?, p_target_filter?, p_severity?, p_status?)` — F.RULE.2.
    /// Permiso: `rules.manage`. Sólo reglas no archivadas. NULL = no cambiar.
    func updateRule(_ input: UpdateRuleInput) async throws -> Rule
    /// `archive_rule(p_rule_id, p_reason?)` — R.7.x.
    /// Status pasa a `archived`. Permiso: `rules.manage`. PULL gate doctrine R.7:
    /// si policy `rule_change_requires_vote` o catalog default exigen votación,
    /// raise `governance_required` (42501). Caller debe primero invocar
    /// `request_governance_action('rule.archive', target=rule_id)`.
    func archiveRule(ruleId: UUID, reason: String?) async throws -> RuleArchivedResult
    /// Lectura PostgREST: `rules` activas/pausadas del contexto.
    func listRules(contextId: UUID) async throws -> [Rule]

    // MARK: - Reservations

    /// `request_resource_reservation(...)`
    func requestReservation(_ input: RequestReservationInput) async throws -> ReservationRequestResult
    /// Lectura PostgREST: reservaciones de un recurso.
    func listReservations(resourceId: UUID) async throws -> [Reservation]
    /// Lectura PostgREST: reservaciones de un contexto.
    func listContextReservations(contextId: UUID) async throws -> [Reservation]
    /// R.2T — Lectura PostgREST: reservaciones linkeadas a un evento vía
    /// `source_event_id`. Usado para surfacear "Recurso reservado" en
    /// EventDetailView (caso Mundial: 5 partidos → Palco).
    func listReservationsByEvent(eventId: UUID) async throws -> [Reservation]
    /// Lectura PostgREST: conflictos abiertos de un recurso.
    func listConflicts(resourceId: UUID) async throws -> [ReservationConflict]
    /// `detect_reservation_conflicts(resource)` — equivalente RPC al list pero
    /// invocado server-side (puede detectar conflictos no persistidos).
    func detectReservationConflicts(resourceId: UUID) async throws -> [ReservationConflict]

    // MARK: - R.5B Resource Conflicts

    /// `list_resource_conflicts(p_resource_id, p_include_resolved)` — R.5B.3.
    /// Lista dedupe'd con items enriquecidos. Mismo shape que `descriptor.conflicts`.
    func listResourceConflicts(resourceId: UUID, includeResolved: Bool) async throws -> ResourceConflictList
    /// `list_context_conflicts(p_context_actor_id, p_include_resolved)` — R.5B.3.
    /// Lista enriquecida con `resource_display_name`.
    func listContextConflicts(contextActorId: UUID, includeResolved: Bool) async throws -> ContextConflictList
    /// `resolve_resource_conflict(p_conflict_id, p_resolution_kind, p_winner_actor_id?, p_payload?)` — R.5B.3.
    /// Kinds: `manualResolution`, `escalate`, `dismiss`. Escalate crea decision vía
    /// template auto-seleccionada por conflict_type.
    func resolveResourceConflict(
        conflictId: UUID,
        kind: ResolveResourceConflictKind,
        winnerActorId: UUID?,
        payload: JSONValue
    ) async throws -> ResolveResourceConflictResult
    /// `detect_resource_conflicts(p_resource_id)` — R.5B.1. Idempotente.
    func detectResourceConflicts(resourceId: UUID) async throws -> DetectResourceConflictsResult
    /// `detect_context_conflicts(p_context_actor_id)` — R.5B.1. Fanout sobre
    /// resources con reservations en el contexto.
    func detectContextConflicts(contextActorId: UUID) async throws -> DetectContextConflictsResult
    /// `reservation_detail(p_reservation_id)` — R.2S: detalle + `available_actions` canónicos.
    func reservationDetail(reservationId: UUID) async throws -> ReservationDetail
    /// `approve_reservation(p_reservation_id)`
    func approveReservation(reservationId: UUID) async throws
    /// `confirm_reservation(p_reservation_id)`
    func confirmReservation(reservationId: UUID) async throws
    /// `cancel_reservation(p_reservation_id)`
    func cancelReservation(reservationId: UUID) async throws
    /// `resolve_reservation_conflict(p_conflict_id, p_winner_reservation_id)` —
    /// overload de 2 args (atajo equivalente a `resolutionModel=.winner`).
    func resolveReservationConflict(conflictId: UUID, winnerReservationId: UUID) async throws
    /// R.2S.7 — `resolve_reservation_conflict(p_conflict_id, p_resolution_model,
    /// p_winner_reservation_id?, p_metadata?)`. Modelos: winner / priority_based /
    /// admin_override / lottery / waitlisted / split_dates / partial_approval /
    /// requires_decision. Devuelve la forma resuelta (winner/loser/split_at/decision_id).
    func resolveReservationConflictWith(
        conflictId: UUID,
        resolutionModel: ResolutionModel,
        winnerReservationId: UUID?,
        metadata: JSONValue?
    ) async throws -> ResolveConflictResult

    // MARK: - Decisions

    /// `create_decision(...)`
    func createDecision(_ input: CreateDecisionInput) async throws -> Decision
    /// `update_decision(p_decision_id, p_title?, p_description?, p_closes_at?)` — F.DECISION.5.
    /// Permiso: autor o `decisions.execute`. Sólo decisiones `open`. NULL = no cambiar.
    func updateDecision(_ input: UpdateDecisionInput) async throws -> Decision
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
    /// `unvote_option(p_decision_id, p_option_id)` — R.2Q-6 (multiple_choice toggle-off).
    /// Returns `{removed: bool}` — idempotente.
    func unvoteOption(decisionId: UUID, optionId: UUID) async throws -> UnvoteResult
    /// `create_decision_option(...)` — R.2Q.
    func createDecisionOption(_ input: CreateDecisionOptionInput) async throws -> DecisionOption
    /// R.4B — lectura PostgREST: catálogo de plantillas de decisión
    /// (`decision_templates_catalog`, RLS `select` a `authenticated`).
    func listDecisionTemplates() async throws -> [DecisionTemplate]

    // MARK: - Money

    /// `record_expense(...)`
    func recordExpense(_ input: RecordExpenseInput) async throws -> ExpenseResult
    /// `preview_event_split(p_event_id, p_amount, p_currency)` — R.9.C.
    /// Split ponderado calculado por el BACKEND (1 + plus_count + guest shares,
    /// redondeo determinista idéntico a `record_expense(split_basis='event_weights')`).
    /// Read-only: iOS solo presenta el desglose.
    func previewEventSplit(eventId: UUID, amount: Double, currency: String) async throws -> EventSplitPreview
    /// `record_fine(...)` → obligation id
    func recordFine(contextId: UUID, debtorActorId: UUID, amount: Double, currency: String, reason: String?) async throws -> UUID
    /// `record_game_result(...)`
    func recordGameResult(_ input: RecordGameResultInput) async throws -> GameResultRecorded
    /// Lectura PostgREST: `obligations` del contexto.
    func listObligations(contextId: UUID) async throws -> [Obligation]
    /// Lectura PostgREST: `money_transactions` del contexto (ledger). RLS:
    /// creador, partes from/to o miembros del contexto. Orden `occurred_at desc`.
    func listContextTransactions(contextId: UUID) async throws -> [MoneyTransaction]
    /// `void_transaction(p_transaction_id, p_reason?)` — audit_9. Anula una
    /// transacción `posted` (revierte ledger + cancela obligaciones abiertas
    /// ligadas). Autoridad: creador o `money.settle`. Las settlement se rechazan.
    func voidTransaction(transactionId: UUID, reason: String?) async throws -> TransactionVoided
    /// `create_action_obligation(...)` — R.2R obligaciones de acción (no money).
    func createActionObligation(_ input: CreateActionObligationInput) async throws -> ActionObligationCreated
    /// `complete_obligation(p_obligation_id, p_completion_notes?, p_completion_metadata?)` — R.2R.
    func completeObligation(obligationId: UUID, completionNotes: String?, completionMetadata: JSONValue?) async throws -> ObligationCompletedResult
    /// `obligation_detail(p_obligation_id)` — R.2R: detalle + `available_actions`.
    func obligationDetail(obligationId: UUID) async throws -> ObligationDetail
    /// `update_obligation(p_obligation_id, p_title?, p_description?, p_due_at?, p_amount?, p_currency?)` — F.MONEY.4.
    /// Permiso: acreedor o `money.settle`. Sólo obligaciones activas. NULL = no cambiar.
    /// amount/currency sólo aplican a obligaciones kind='money'.
    func updateObligation(_ input: UpdateObligationInput) async throws -> Obligation
    /// `forgive_obligation(p_obligation_id, p_reason?)` — R.7.x.
    /// Status pasa a `forgiven` (no contamina ledger). Permiso: creditor o `money.settle`.
    /// PULL gate doctrine R.7: si policy o catalog default exigen votación, raise
    /// `governance_required` (42501) — el caller debe primero conseguir aprobación vía
    /// `request_governance_action('obligation.forgive', target_id=obligation)`.
    func forgiveObligation(obligationId: UUID, reason: String?) async throws -> ObligationForgivenResult

    // MARK: - Pools (R.8)

    /// `create_pool(...)` — R.8.B. Crea pool actor (collective/pool) +
    /// `pool_accounts` row. Permission: `money.record`.
    func createPool(_ input: CreatePoolInput) async throws -> PoolCreated
    /// `contribute_to_pool(...)` — R.8.B. `cash` crea money_transaction +
    /// obligation `pending_pool`; `pending_stake` solo obligation; `asset`/
    /// `service` solo basis entry.
    func contributeToPool(_ input: ContributeToPoolInput) async throws -> PoolContributionResult
    /// `list_context_pools(p_parent_context_actor_id)` — R.8.B. Pools del
    /// contexto con `totals` (basis_total + my_basis + contributor_count).
    func listContextPools(contextId: UUID) async throws -> [PoolAccount]
    /// `pool_account_detail(p_pool_account_id)` — R.8.B. Pool + basis ledger +
    /// totals + 4 `available_actions` canónicos.
    func poolAccountDetail(poolAccountId: UUID) async throws -> PoolAccountDetail
    /// `preview_pool_resolution(p_pool_account_id)` — R.8.C. Read-only, no muta.
    func previewPoolResolution(poolAccountId: UUID) async throws -> PoolResolutionPreview
    /// `resolve_pool(p_pool_account_id, p_resolution, p_client_id)` — R.8.C.
    /// winner_takes_all requiere `resolution = {"winner_actor_id": uuid}`.
    /// Permission: `money.settle`. Governance PULL: puede lanzar
    /// `governance_required` (la UI lo muestra vía `UserFacingError`).
    func resolvePool(poolAccountId: UUID, resolution: JSONValue?, clientId: String?) async throws -> PoolResolutionResult

    // MARK: - Settlement

    /// `generate_settlement_batch(p_context_actor_id, p_currency)`
    func generateSettlementBatch(contextId: UUID, currency: String) async throws -> SettlementBatchResult
    /// Lectura PostgREST: `settlement_batches` del contexto.
    func listSettlementBatches(contextId: UUID) async throws -> [SettlementBatch]
    /// Lectura PostgREST: `settlement_items` de un batch.
    func listSettlementItems(batchId: UUID) async throws -> [SettlementItem]
    /// `mark_settlement_paid(p_settlement_item_id)` — R.5Z.fix.SETTLEMENT.HANDSHAKE.
    /// Cuando lo llama el debtor → status='pending_confirmation' + emite
    /// attention al creditor. Cuando lo llama el creditor o admin → paid directo.
    func markSettlementPaid(itemId: UUID) async throws -> MarkPaidResult
    /// `confirm_settlement_paid(p_settlement_item_id)` — R.5Z.fix.SETTLEMENT.HANDSHAKE.
    /// Solo creditor o admin. Aplica side effects (transaction + obligation close
    /// + batch finalize + activity).
    func confirmSettlementPaid(itemId: UUID) async throws -> MarkPaidResult
    /// `reject_settlement_paid(p_settlement_item_id, p_reason?)` — R.5Z.fix.SETTLEMENT.HANDSHAKE.
    /// Solo creditor o admin. Vuelve a status='pending' + emite attention al debtor.
    func rejectSettlementPaid(itemId: UUID, reason: String?) async throws
    /// `appeal_settlement_paid(p_settlement_item_id, p_reason?)` — R.5Z.fix.SETTLEMENT.APPEAL.
    /// Solo el debtor. Status pasa a 'disputed' + emite attention a admins
    /// (money.settle) y al creditor. Admin resuelve via `confirm_settlement_paid`
    /// o `reject_settlement_paid`.
    func appealSettlementPaid(itemId: UUID, reason: String?) async throws

    // MARK: - Documents

    /// `register_document(...)` — registra metadata; el binario se sube antes
    /// con `uploadDocumentFile`. Devuelve `{document_id}`.
    func registerDocument(_ input: RegisterDocumentInput) async throws -> DocumentRegistered
    /// Lectura PostgREST: `documents` asociados a un recurso.
    func listResourceDocuments(resourceId: UUID) async throws -> [Document]
    /// Documents V2 (D.1) — `list_context_documents(p_context_actor_id, p_include_archived)`.
    /// RPC SECURITY DEFINER con gate `documents.view`. Devuelve docs con joins enriquecidos
    /// (owner_display_name + resource_display_name).
    func listContextDocuments(contextId: UUID, includeArchived: Bool) async throws -> [Document]
    /// Documents V2 (D.0) — `archive_document(p_document_id)` SECURITY DEFINER.
    /// Soft delete (sets `archived_at`). Gate: owner OR `documents.manage`. Idempotente.
    func archiveDocument(documentId: UUID) async throws
    /// Sube el binario al bucket `documents` de Supabase Storage. iOS NO calcula
    /// el path — el caller decide la convención (ver `DocumentsStore.makeStoragePath`).
    /// El mock guarda el blob in-memory.
    func uploadDocumentFile(path: String, data: Data, contentType: String) async throws
    /// Devuelve una URL firmada para descargar/visualizar el archivo. `expiresIn`
    /// en segundos. El mock devuelve un placeholder.
    func documentSignedURL(path: String, expiresIn: Int) async throws -> URL

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

    /// `list_activity(p_context_actor_id, p_limit, p_before, p_include_descendants)` — R.2U.2
    /// agregó `p_include_descendants`; cuando `true` une eventos de subcontextos
    /// (vía `actor_relationships.contains` + filtro `is_context_member`).
    func listActivity(contextId: UUID, limit: Int, before: Date?, includeDescendants: Bool) async throws -> [ActivityEvent]

    // MARK: - Similarity & duplicates (R.2V)

    /// `context_similarity(p_context_id)` — top 20 contextos similares al dado.
    func contextSimilarity(contextId: UUID) async throws -> [ContextSimilarityCandidate]
    /// `resource_similarity(p_resource_id)` — top 20 recursos similares al dado.
    func resourceSimilarity(resourceId: UUID) async throws -> [ResourceSimilarityCandidate]
    /// `duplicate_candidates(p_min_score?, p_max_pairs?)` — pares deduped de
    /// contextos/recursos del caller con score >= threshold (default 0.50).
    func duplicateCandidates(minScore: Double?, maxPairs: Int?) async throws -> DuplicateCandidates
    /// `merge_candidates()` — wrapper de duplicate_candidates con threshold 0.85.
    func mergeCandidates() async throws -> DuplicateCandidates
    /// `relationship_suggestions(p_actor_id?)` — pares cross-context con name trgm >= 0.40
    /// y sin contains activo. Default actor = caller.
    func relationshipSuggestions(actorId: UUID?) async throws -> [RelationshipSuggestion]
    /// `merge_contexts(p_source, p_target)` — soft merge. Marca `metadata.r2v`.
    /// Requiere `context.manage` en source.
    func mergeContexts(sourceId: UUID, targetId: UUID) async throws -> MergeContextResult
    /// `unmerge_context(p_source)` — revierte el soft merge. Idempotente.
    func unmergeContext(sourceId: UUID) async throws -> UnmergeContextResult
    /// `context_creation_candidates(p_display_name)` — creation guard: top 10
    /// contextos del caller con similarity(name) >= 0.60.
    func contextCreationCandidates(displayName: String) async throws -> [ContextCreationCandidate]
    /// `resource_creation_candidates(p_display_name, p_context_id)` — creation
    /// guard para recursos dentro del contexto (requiere is_context_member).
    func resourceCreationCandidates(displayName: String, contextId: UUID) async throws -> [ResourceCreationCandidate]
    /// `dismiss_suggestion(p_subject_a, p_subject_b, p_suggestion_type)` — emite
    /// `suggestion.dismissed` para que la UI filtre la sugerencia.
    func dismissSuggestion(subjectA: UUID, subjectB: UUID, suggestionType: SuggestionType) async throws -> DismissSuggestionResult

    // MARK: - Subscriptions & Trust (R.3A)

    /// `subscribe(p_target_type, p_target_id, p_subscription_type, p_notes?)` —
    /// idempotente (reactiva si existía soft-removed). Devuelve `subscription_id`.
    func subscribe(targetType: SubscriptionTargetType, targetId: UUID, subscriptionType: SubscriptionType, notes: String?) async throws -> UUID
    /// `unsubscribe(p_subscription_id)` — soft remove. Idempotente.
    func unsubscribe(subscriptionId: UUID) async throws -> Bool
    /// `mark_as_stakeholder(p_target_type, p_target_id, p_actor_id?)` — atajo
    /// para `subscribe(..., stakeholder)`. Sólo el caller puede marcarse a sí mismo.
    func markAsStakeholder(targetType: SubscriptionTargetType, targetId: UUID) async throws -> UUID
    /// `list_my_subscriptions()` — todas las subs activas del caller.
    func listMySubscriptions() async throws -> SubscriptionList
    /// `activity_feed(p_actor_id?, p_limit?)` — feed personalizado del caller.
    func activityFeed(actorId: UUID?, limit: Int, offset: Int) async throws -> ActivityFeed
    /// `add_trust(p_target_actor_id, p_trust_level, p_trust_type, p_notes?)` —
    /// idempotente por (caller, target, type).
    func addTrust(targetActorId: UUID, trustLevel: Int, trustType: TrustType, notes: String?) async throws -> UUID
    /// `remove_trust(p_trust_edge_id)` — soft remove. Idempotente.
    func removeTrust(trustEdgeId: UUID) async throws -> Bool
    /// `list_trust_network(p_actor_id?)` — outgoing/incoming del caller (RLS gatea).
    func listTrustNetwork(actorId: UUID?) async throws -> TrustNetwork

    // MARK: - Navigation shell (F.NAV.0)

    /// `attention_inbox()` — items cross-context que requieren acción del caller
    /// (conflictos / votos / pagos / invitaciones). Max 5, sort desc.
    func attentionInbox() async throws -> [AttentionItem]
    /// `dismiss_attention_item(p_attention_item_id)` — R.5Z.fix.CC.2.3.
    /// Marca un `rule_attention_item` como descartado (status='dismissed').
    /// Solo dismissable para items en la tabla `rule_attention_items`
    /// (rule_violation, rule_recommendation, policy_violation). Otros kinds
    /// (obligation_pay/decision_vote/settlement_open/etc.) son derivados y
    /// se cierran cuando la acción subyacente se completa.
    /// Auth: el subject del item o un admin del contexto.
    func dismissAttentionItem(itemId: UUID) async throws
    /// `mark_context_favorite(ctx, fav)` — toggle favorito (member-only).
    func markContextFavorite(contextActorId: UUID, isFavorite: Bool) async throws
    /// `mark_context_visited(ctx)` — registra visita para "Continuar" en Home.
    func markContextVisited(contextActorId: UUID) async throws
    /// `list_context_favorites()` — favoritos del caller.
    func listContextFavorites() async throws -> [ContextPreference]
    /// `list_recent_contexts(limit)` — contextos visitados recientemente.
    func listRecentContexts(limit: Int) async throws -> [ContextPreference]
    /// `home_overview()` — R.11.E. Métricas vivas por contexto del caller en
    /// un solo round-trip: member_count, pending_count (obligations open +
    /// decisions sin votar), next_event_at/title, my_balance + currency.
    /// Alimenta Home "Hoy en tus espacios" + Contextos lista densa.
    func homeOverview() async throws -> [ContextOverview]

    // MARK: - Governance (R.5 + R.7)

    /// R.7.D — `member_available_actions(p_context_actor_id, p_member_actor_id, p_actor_id)`.
    /// Devuelve hasta 3 actions (`member.remove`, `member.pause`, `member.promote`) con
    /// `mode` decorado por `_aa_apply_governance_mode`. Reglas: `member.remove` no aparece
    /// si target == caller; `member.promote` no aparece si target ya es admin/founder/owner.
    func memberAvailableActions(
        contextId: UUID,
        memberActorId: UUID,
        actorId: UUID
    ) async throws -> [AvailableAction]

    /// R.7.B — `request_governance_action(...)`. Entrypoint canónico R.7. Resuelve
    /// aliases, calcula `idempotency_key` sha1 si `clientId` no es nil, advisory lock
    /// race-safe, delega a `request_governed_action()` con canonical key. Si el catálogo
    /// + policy dictan `requires_decision=true`, devuelve `decisionId` para que iOS
    /// pushee `DecisionDetailView`.
    func requestGovernanceAction(_ input: RequestGovernanceActionInput) async throws -> RequestGovernanceActionResult

    /// `list_governance_policies(p_context_actor_id)` — políticas del contexto.
    /// Member-only en backend.
    func listGovernancePolicies(contextActorId: UUID) async throws -> [GovernancePolicy]
    /// `create_governance_policy(p_context_actor_id, p_policy_key, p_policy_value)` —
    /// upsert (también funciona como update). Requiere `decisions.execute` en backend.
    /// Si `policyValue` es `.null`, el backend elimina la política.
    func setGovernancePolicy(contextActorId: UUID, policyKey: String, policyValue: JSONValue) async throws
    /// PostgREST read sobre `vote_delegations` filtrado por contexto + activas
    /// (`revoked_at is null`). Member-only por RLS.
    func listVoteDelegations(contextActorId: UUID) async throws -> [VoteDelegation]
    /// `delegate_vote(p_context_actor_id, p_delegate_actor_id, p_ends_at?)` —
    /// el caller delega su voto. Auto-revoca delegación previa.
    func delegateVote(contextActorId: UUID, delegateActorId: UUID, endsAt: Date?) async throws
    /// `revoke_vote_delegation(p_context_actor_id)` — revoca la delegación activa
    /// del caller en ese contexto. Idempotente.
    func revokeVoteDelegation(contextActorId: UUID) async throws
}

extension RuulRPCClient {
    /// Back-compat: por default no agrega eventos de subcontextos.
    public func listActivity(contextId: UUID, limit: Int, before: Date?) async throws -> [ActivityEvent] {
        try await listActivity(contextId: contextId, limit: limit, before: before, includeDescendants: false)
    }
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
    /// type_key del catálogo legacy R.2M (`resource_type_catalog`).
    /// **Founder firma 2026-06-07**: usar `subtypeKey` cuando sea posible —
    /// backend deriva el resource_type del subtype.
    public var resourceType: String
    /// R.5A.B.0 — subtype_key explícito de `resource_subtypes` (42 subtypes).
    /// Si se pasa, el backend ignora `resourceType` y deriva del subtype.
    public var subtypeKey: String?
    public var displayName: String
    public var description: String?
    public var estimatedValue: Double?
    public var currency: String?
    /// F.RESOURCE.4 — ubicación opcional.
    public var locationText: String?
    public var clientId: String?
    /// R.12.D — metadata jsonb que persiste los campos específicos del
    /// subtype (FormFieldSpec values: license_plate, vin, address, etc.).
    /// nil → no se envía `p_metadata` y backend usa default `{}`.
    public var metadata: JSONValue?

    /// Init con type_key arbitrario (preferido para usar el catálogo dinámico).
    public init(
        contextId: UUID,
        resourceTypeKey: String,
        displayName: String,
        description: String? = nil,
        estimatedValue: Double? = nil,
        currency: String? = nil,
        locationText: String? = nil,
        clientId: String? = nil,
        subtypeKey: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.contextId = contextId
        self.resourceType = resourceTypeKey
        self.subtypeKey = subtypeKey
        self.displayName = displayName
        self.description = description
        self.estimatedValue = estimatedValue
        self.locationText = locationText
        self.currency = currency
        self.clientId = clientId
        self.metadata = metadata
    }

    /// Init con `ResourceType` enum — conveniencia para call sites legacy.
    public init(
        contextId: UUID,
        resourceType: ResourceType,
        displayName: String,
        description: String? = nil,
        estimatedValue: Double? = nil,
        currency: String? = nil,
        clientId: String? = nil
    ) {
        self.init(
            contextId: contextId,
            resourceTypeKey: resourceType.rawValue,
            displayName: displayName,
            description: description,
            estimatedValue: estimatedValue,
            currency: currency,
            clientId: clientId
        )
    }
}

/// Input de `update_context` (F.1A polish). Todos los campos son opcionales —
/// solo se aplica lo que llegue distinto de nil. Los configs son jsonb que se
/// fusionan con la versión existente en backend (deep merge por slot).
public struct UpdateContextInput: Sendable, Equatable {
    public var contextId: UUID
    public var displayName: String?
    public var description: String?
    /// `private` | `members` | `public`.
    public var visibility: String?
    public var imageUrl: String?
    public var decisionsConfig: JSONValue?
    public var moneyConfig: JSONValue?
    public var reservationsConfig: JSONValue?
    public var invitationsConfig: JSONValue?

    public init(
        contextId: UUID,
        displayName: String? = nil,
        description: String? = nil,
        visibility: String? = nil,
        imageUrl: String? = nil,
        decisionsConfig: JSONValue? = nil,
        moneyConfig: JSONValue? = nil,
        reservationsConfig: JSONValue? = nil,
        invitationsConfig: JSONValue? = nil
    ) {
        self.contextId = contextId
        self.displayName = displayName
        self.description = description
        self.visibility = visibility
        self.imageUrl = imageUrl
        self.decisionsConfig = decisionsConfig
        self.moneyConfig = moneyConfig
        self.reservationsConfig = reservationsConfig
        self.invitationsConfig = invitationsConfig
    }
}

/// Resultado de `transfer_resource_ownership`.
public struct TransferOwnershipResult: Decodable, Sendable, Equatable {
    public let resourceId: UUID
    public let fromActorId: UUID
    public let toActorId: UUID
    public let newRightId: UUID?
    public let rightsRevoked: Int
    public let percentTotal: Double?
    public let canonicalOwnerChanged: Bool
    /// R.7.x — `true` cuando la ejecución corrió porque una decisión la aprobó.
    /// Default `false` por backward-compat con backend pre-R.7.
    public let viaGovernance: Bool

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case fromActorId = "from_actor_id"
        case toActorId = "to_actor_id"
        case newRightId = "new_right_id"
        case rightsRevoked = "rights_revoked"
        case percentTotal = "percent_total"
        case canonicalOwnerChanged = "canonical_owner_changed"
        case viaGovernance = "via_governance"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resourceId = try c.decode(UUID.self, forKey: .resourceId)
        self.fromActorId = try c.decode(UUID.self, forKey: .fromActorId)
        self.toActorId = try c.decode(UUID.self, forKey: .toActorId)
        self.newRightId = try c.decodeIfPresent(UUID.self, forKey: .newRightId)
        self.rightsRevoked = try c.decodeIfPresent(Int.self, forKey: .rightsRevoked) ?? 0
        self.percentTotal = try c.decodeIfPresent(Double.self, forKey: .percentTotal)
        self.canonicalOwnerChanged = try c.decodeIfPresent(Bool.self, forKey: .canonicalOwnerChanged) ?? false
        self.viaGovernance = try c.decodeIfPresent(Bool.self, forKey: .viaGovernance) ?? false
    }

    public init(
        resourceId: UUID,
        fromActorId: UUID,
        toActorId: UUID,
        newRightId: UUID? = nil,
        rightsRevoked: Int = 0,
        percentTotal: Double? = nil,
        canonicalOwnerChanged: Bool = false,
        viaGovernance: Bool = false
    ) {
        self.resourceId = resourceId
        self.fromActorId = fromActorId
        self.toActorId = toActorId
        self.newRightId = newRightId
        self.rightsRevoked = rightsRevoked
        self.percentTotal = percentTotal
        self.canonicalOwnerChanged = canonicalOwnerChanged
        self.viaGovernance = viaGovernance
    }
}

/// Input de `update_resource`. Todos los campos son opcionales — solo se aplica
/// lo que llegue distinto de nil. `metadata` es jsonb (incluye policies por capability).
/// F.RESOURCE.4: `locationText` semántica especial — `nil` = no cambiar;
/// `""` = limpiar; otro = setear.
public struct UpdateResourceInput: Sendable, Equatable {
    public var resourceId: UUID
    public var displayName: String?
    public var description: String?
    public var estimatedValue: Double?
    public var currency: String?
    public var metadata: JSONValue?
    public var locationText: String?

    public init(
        resourceId: UUID,
        displayName: String? = nil,
        description: String? = nil,
        estimatedValue: Double? = nil,
        currency: String? = nil,
        metadata: JSONValue? = nil,
        locationText: String? = nil
    ) {
        self.resourceId = resourceId
        self.displayName = displayName
        self.description = description
        self.estimatedValue = estimatedValue
        self.currency = currency
        self.metadata = metadata
        self.locationText = locationText
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
    /// F.EVENT.5 — `true` para eventos sin ubicación física (Zoom, Meet…).
    /// Si `false`, el backend exige `locationText` no vacío.
    public var isVirtual: Bool
    /// `weekly` para cenas recurrentes con host rotativo.
    public var recurrenceRule: String?
    /// F.EVENT.9 — acota la serie por número total de ocurrencias.
    public var recurrenceCount: Int?
    /// F.EVENT.9 — acota la serie por fecha tope (la última ocurrencia
    /// debe iniciar antes o en este timestamp).
    public var recurrenceUntil: Date?
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
        isVirtual: Bool = false,
        recurrenceRule: String? = nil,
        recurrenceCount: Int? = nil,
        recurrenceUntil: Date? = nil,
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
        self.isVirtual = isVirtual
        self.recurrenceRule = recurrenceRule
        self.recurrenceCount = recurrenceCount
        self.recurrenceUntil = recurrenceUntil
        self.hostActorId = hostActorId
        self.inviteAllMembers = inviteAllMembers
        self.clientId = clientId
    }
}

/// Input de `update_calendar_event` (F.EVENT.7). Todos los campos opcionales —
/// solo se aplica lo que llegue distinto de nil. `clear*` flags permiten limpiar
/// campos opcionales explícitamente (descripción / recurrencia).
public struct UpdateEventInput: Sendable, Equatable {
    public var eventId: UUID
    public var title: String?
    public var description: String?
    public var startsAt: Date?
    public var endsAt: Date?
    public var locationText: String?
    public var isVirtual: Bool?
    public var recurrenceRule: String?

    public init(
        eventId: UUID,
        title: String? = nil,
        description: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        locationText: String? = nil,
        isVirtual: Bool? = nil,
        recurrenceRule: String? = nil
    ) {
        self.eventId = eventId
        self.title = title
        self.description = description
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.locationText = locationText
        self.isVirtual = isVirtual
        self.recurrenceRule = recurrenceRule
    }
}

/// Input de `create_rule`. R.2S.5 añade `targetScope` + `targetFilter`
/// para reglas universales (más allá de eventos de calendario).
public struct CreateRuleInput: Sendable, Equatable {
    public var contextId: UUID
    public var title: String
    public var triggerEventType: String?
    public var conditionTree: JSONValue?
    public var consequences: JSONValue?
    public var body: String?
    public var ruleType: String
    public var severity: Int
    /// Scope del dominio donde aplica (default 'context' = legacy global).
    public var targetScope: String?
    /// Filtro jsonb sobre el payload del trigger (default `{}` = matchea todos).
    public var targetFilter: JSONValue?

    public init(
        contextId: UUID,
        title: String,
        triggerEventType: String? = nil,
        conditionTree: JSONValue? = nil,
        consequences: JSONValue? = nil,
        body: String? = nil,
        ruleType: String = "automation",
        severity: Int = 1,
        targetScope: String? = nil,
        targetFilter: JSONValue? = nil
    ) {
        self.contextId = contextId
        self.title = title
        self.triggerEventType = triggerEventType
        self.conditionTree = conditionTree
        self.consequences = consequences
        self.body = body
        self.ruleType = ruleType
        self.severity = severity
        self.targetScope = targetScope
        self.targetFilter = targetFilter
    }
}

/// Input de `update_rule` (F.RULE.2). NULL = no cambiar.
public struct UpdateRuleInput: Sendable, Equatable {
    public var ruleId: UUID
    public var title: String?
    public var body: String?
    public var triggerEventType: String?
    public var conditionTree: JSONValue?
    public var consequences: JSONValue?
    public var targetScope: String?
    public var targetFilter: JSONValue?
    public var severity: Int?
    public var status: String?

    public init(
        ruleId: UUID,
        title: String? = nil,
        body: String? = nil,
        triggerEventType: String? = nil,
        conditionTree: JSONValue? = nil,
        consequences: JSONValue? = nil,
        targetScope: String? = nil,
        targetFilter: JSONValue? = nil,
        severity: Int? = nil,
        status: String? = nil
    ) {
        self.ruleId = ruleId
        self.title = title
        self.body = body
        self.triggerEventType = triggerEventType
        self.conditionTree = conditionTree
        self.consequences = consequences
        self.targetScope = targetScope
        self.targetFilter = targetFilter
        self.severity = severity
        self.status = status
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
    /// R.2T — link opcional al evento que motiva la reservación (doctrina
    /// `doctrine_r2t_reservation_vs_event`). Reservation NO requiere Event.
    public var sourceEventId: UUID?

    public init(
        resourceId: UUID,
        contextId: UUID,
        startsAt: Date,
        endsAt: Date,
        reservedForActorId: UUID? = nil,
        clientId: String? = nil,
        sourceEventId: UUID? = nil
    ) {
        self.resourceId = resourceId
        self.contextId = contextId
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.reservedForActorId = reservedForActorId
        self.clientId = clientId
        self.sourceEventId = sourceEventId
    }
}

/// Input de `update_decision` (F.DECISION.5). NULL = no cambiar.
public struct UpdateDecisionInput: Sendable, Equatable {
    public var decisionId: UUID
    public var title: String?
    public var description: String?
    public var closesAt: Date?

    public init(
        decisionId: UUID,
        title: String? = nil,
        description: String? = nil,
        closesAt: Date? = nil
    ) {
        self.decisionId = decisionId
        self.title = title
        self.description = description
        self.closesAt = closesAt
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
    /// R.2Q — override del voting_model. Si es nil, el backend autodetecta
    /// (o hereda el `default_voting_model` de la plantilla cuando hay `templateKey`).
    public var votingModel: VotingModel?
    /// R.4B — plantilla (`p_template_key`). El backend hereda voting model y
    /// despacha el efecto al ejecutar según `execution_kind`.
    public var templateKey: String?
    /// R.4B — `decision_type` crudo del catálogo (`governance`/`money`/…), que no
    /// mapea 1:1 al enum `DecisionType`. Si está presente, manda este en el wire.
    public var decisionTypeRaw: String?

    /// `decision_type` efectivo enviado al backend.
    public var decisionTypeWire: String { decisionTypeRaw ?? decisionType.rawValue }

    public init(
        contextId: UUID,
        decisionType: DecisionType,
        title: String,
        description: String? = nil,
        closesAt: Date? = nil,
        payload: JSONValue? = nil,
        clientId: String? = nil,
        votingModel: VotingModel? = nil,
        templateKey: String? = nil,
        decisionTypeRaw: String? = nil
    ) {
        self.contextId = contextId
        self.decisionType = decisionType
        self.title = title
        self.description = description
        self.closesAt = closesAt
        self.payload = payload
        self.clientId = clientId
        self.votingModel = votingModel
        self.templateKey = templateKey
        self.decisionTypeRaw = decisionTypeRaw
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
    /// R.9.C — evento fuente para `splitBasis = "event_weights"` (el backend
    /// computa los splits desde `_event_split_weights`).
    public var sourceEventId: UUID?
    /// R.9.C — `equal` | `explicit` | `event_weights`. `nil` = flujo legacy.
    public var splitBasis: String?

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
        clientId: String? = nil,
        sourceEventId: UUID? = nil,
        splitBasis: String? = nil
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
        self.sourceEventId = sourceEventId
        self.splitBasis = splitBasis
    }
}

/// Input de `create_pool` (R.8.B).
public struct CreatePoolInput: Sendable, Equatable {
    public var contextId: UUID
    public var displayName: String
    /// `winner_takes_all` | `equity_target` (políticas MVP con UI).
    public var policyKey: String
    public var policyConfig: JSONValue?
    public var currency: String?
    /// Requerido (> 0) por el backend cuando `policyKey == "equity_target"`.
    public var targetAmount: Double?
    public var description: String?
    public var clientId: String?

    public init(
        contextId: UUID,
        displayName: String,
        policyKey: String,
        policyConfig: JSONValue? = nil,
        currency: String? = nil,
        targetAmount: Double? = nil,
        description: String? = nil,
        clientId: String? = nil
    ) {
        self.contextId = contextId
        self.displayName = displayName
        self.policyKey = policyKey
        self.policyConfig = policyConfig
        self.currency = currency
        self.targetAmount = targetAmount
        self.description = description
        self.clientId = clientId
    }
}

/// Input de `contribute_to_pool` (R.8.B).
public struct ContributeToPoolInput: Sendable, Equatable {
    public var poolAccountId: UUID
    /// `cash` | `asset` | `service` | `pending_stake`. UI MVP: `cash`.
    public var basisKind: String
    public var amount: Double
    /// Requerida por el backend para `cash` / `pending_stake`.
    public var currency: String?
    public var assetResourceId: UUID?
    public var valuationMethod: String?
    public var valuationNotes: String?
    public var clientId: String?

    public init(
        poolAccountId: UUID,
        basisKind: String = "cash",
        amount: Double,
        currency: String? = nil,
        assetResourceId: UUID? = nil,
        valuationMethod: String? = nil,
        valuationNotes: String? = nil,
        clientId: String? = nil
    ) {
        self.poolAccountId = poolAccountId
        self.basisKind = basisKind
        self.amount = amount
        self.currency = currency
        self.assetResourceId = assetResourceId
        self.valuationMethod = valuationMethod
        self.valuationNotes = valuationNotes
        self.clientId = clientId
    }
}

/// Input de `create_action_obligation` (R.2R). `kind` ∈ action/approval/delivery/
/// attendance/document/reservation/custom. NO acepta `money` (eso va por record_*).
/// Input de `update_obligation` (F.MONEY.4). NULL = no cambiar.
/// `amount` y `currency` sólo aplican a obligaciones kind='money' (backend valida).
public struct UpdateObligationInput: Sendable, Equatable {
    public var obligationId: UUID
    public var title: String?
    public var description: String?
    public var dueAt: Date?
    public var amount: Double?
    public var currency: String?

    public init(
        obligationId: UUID,
        title: String? = nil,
        description: String? = nil,
        dueAt: Date? = nil,
        amount: Double? = nil,
        currency: String? = nil
    ) {
        self.obligationId = obligationId
        self.title = title
        self.description = description
        self.dueAt = dueAt
        self.amount = amount
        self.currency = currency
    }
}

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

// MARK: - R.7 Governance Orchestration inputs/results

/// Input de `request_governance_action` (R.7.B).
/// `clientId` opcional: si se provee, el backend calcula `idempotency_key` sha1
/// para que retry desde iOS no duplique decisions.
public struct RequestGovernanceActionInput: Sendable, Equatable {
    public var contextActorId: UUID
    public var actionKey: String
    public var targetType: String?
    public var targetId: UUID?
    public var payload: JSONValue
    public var title: String?
    public var closesAt: Date?
    public var clientId: String?

    public init(
        contextActorId: UUID,
        actionKey: String,
        targetType: String? = nil,
        targetId: UUID? = nil,
        payload: JSONValue = .object([:]),
        title: String? = nil,
        closesAt: Date? = nil,
        clientId: String? = nil
    ) {
        self.contextActorId = contextActorId
        self.actionKey = actionKey
        self.targetType = targetType
        self.targetId = targetId
        self.payload = payload
        self.title = title
        self.closesAt = closesAt
        self.clientId = clientId
    }
}

/// Resultado de `request_governance_action` (R.7.B).
public struct RequestGovernanceActionResult: Decodable, Sendable, Equatable {
    public let governanceActionId: UUID
    public let decisionId: UUID?
    public let actionKey: String
    public let requiresDecision: Bool
    /// R.7.B — `true` si el backend devolvió un row pre-existente por idempotency
    /// (mismo `clientId` + `actionKey` + `targetId` + `contextActorId`).
    public let idempotentReplay: Bool

    enum CodingKeys: String, CodingKey {
        case governanceActionId = "governance_action_id"
        case decisionId = "decision_id"
        case actionKey = "action_key"
        case requiresDecision = "requires_decision"
        case idempotentReplay = "idempotent_replay"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.governanceActionId = try c.decode(UUID.self, forKey: .governanceActionId)
        self.decisionId = try c.decodeIfPresent(UUID.self, forKey: .decisionId)
        self.actionKey = try c.decode(String.self, forKey: .actionKey)
        self.requiresDecision = try c.decodeIfPresent(Bool.self, forKey: .requiresDecision) ?? false
        self.idempotentReplay = try c.decodeIfPresent(Bool.self, forKey: .idempotentReplay) ?? false
    }

    public init(
        governanceActionId: UUID,
        decisionId: UUID? = nil,
        actionKey: String,
        requiresDecision: Bool = false,
        idempotentReplay: Bool = false
    ) {
        self.governanceActionId = governanceActionId
        self.decisionId = decisionId
        self.actionKey = actionKey
        self.requiresDecision = requiresDecision
        self.idempotentReplay = idempotentReplay
    }
}
