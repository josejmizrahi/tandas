import Foundation
import Supabase

/// Implementación live de `RuulRPCClient` contra el backend MVP 2.0.
/// Escrituras vía `client.rpc(...)`; lecturas de lista vía RPC cuando existe
/// o `client.from(...)` (PostgREST read-only por RLS). Todo error pasa por
/// `RPCErrorMapper`.
public struct SupabaseRuulRPCClient: RuulRPCClient {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Helpers

    private func call<Result: Decodable>(_ fn: String, params: some Encodable & Sendable) async throws -> Result {
        do {
            return try await client.rpc(fn, params: params).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    private func call<Result: Decodable>(_ fn: String) async throws -> Result {
        do {
            return try await client.rpc(fn).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    private func callVoid(_ fn: String, params: some Encodable & Sendable) async throws {
        do {
            _ = try await client.rpc(fn, params: params).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Identity

    public func ensurePersonActor() async throws -> CurrentActor {
        try await call("ensure_person_actor")
    }

    public func updateMyProfile(fullName: String?, preferredName: String?, avatarUrl: String?) async throws -> CurrentActor {
        struct Params: Encodable, Sendable {
            let pFullName: String?
            let pPreferredName: String?
            let pAvatarUrl: String?
            enum CodingKeys: String, CodingKey {
                case pFullName = "p_full_name"
                case pPreferredName = "p_preferred_name"
                case pAvatarUrl = "p_avatar_url"
            }
        }
        return try await call("update_my_profile", params: Params(
            pFullName: fullName, pPreferredName: preferredName, pAvatarUrl: avatarUrl
        ))
    }

    public func updateMyProfileMetadata(_ metadata: JSONValue) async throws -> CurrentActor {
        struct Params: Encodable, Sendable {
            let pMetadata: JSONValue
            enum CodingKeys: String, CodingKey { case pMetadata = "p_metadata" }
        }
        return try await call("update_my_profile", params: Params(pMetadata: metadata))
    }

    public func personalSettingsSummary() async throws -> PersonalSettings {
        try await call("personal_settings_summary")
    }

    public func contextSettingsSummary(contextId: UUID) async throws -> ContextSettings {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            enum CodingKeys: String, CodingKey { case pContextActorId = "p_context_actor_id" }
        }
        return try await call("context_settings_summary", params: Params(pContextActorId: contextId))
    }

    public func updateContext(_ input: UpdateContextInput) async throws -> ContextSettings {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDisplayName: String?
            let pDescription: String?
            let pVisibility: String?
            let pImageUrl: String?
            let pDecisionsConfig: JSONValue?
            let pMoneyConfig: JSONValue?
            let pReservationsConfig: JSONValue?
            let pInvitationsConfig: JSONValue?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDisplayName = "p_display_name"
                case pDescription = "p_description"
                case pVisibility = "p_visibility"
                case pImageUrl = "p_image_url"
                case pDecisionsConfig = "p_decisions_config"
                case pMoneyConfig = "p_money_config"
                case pReservationsConfig = "p_reservations_config"
                case pInvitationsConfig = "p_invitations_config"
            }
        }
        return try await call("update_context", params: Params(
            pContextActorId: input.contextId,
            pDisplayName: input.displayName,
            pDescription: input.description,
            pVisibility: input.visibility,
            pImageUrl: input.imageUrl,
            pDecisionsConfig: input.decisionsConfig,
            pMoneyConfig: input.moneyConfig,
            pReservationsConfig: input.reservationsConfig,
            pInvitationsConfig: input.invitationsConfig
        ))
    }

    public func resourceSettingsSummary(resourceId: UUID) async throws -> ResourceSettings {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        return try await call("resource_settings_summary", params: Params(pResourceId: resourceId))
    }

    // MARK: - Actor capabilities (R.2S.1)

    public func actorCapabilities(actorId: UUID) async throws -> ActorCapabilities {
        struct Params: Encodable, Sendable {
            let pActorId: UUID
            enum CodingKeys: String, CodingKey { case pActorId = "p_actor_id" }
        }
        return try await call("actor_capabilities", params: Params(pActorId: actorId))
    }

    public func actorCapabilitiesCatalog() async throws -> ActorCapabilitiesCatalog {
        try await call("actor_capabilities_catalog")
    }

    public func actorCan(actorId: UUID, capability: String) async throws -> Bool {
        struct Params: Encodable, Sendable {
            let pActorId: UUID
            let pCapability: String
            enum CodingKeys: String, CodingKey {
                case pActorId = "p_actor_id"
                case pCapability = "p_capability"
            }
        }
        return try await call("actor_can", params: Params(pActorId: actorId, pCapability: capability))
    }

    // MARK: - Contexts

    public func contextCandidates() async throws -> ContextCandidates {
        try await call("context_candidates")
    }

    public func contextSummary(contextId: UUID) async throws -> ContextSummary {
        try await call("context_summary", params: ContextIdParams(contextId: contextId))
    }

    public func myWorld() async throws -> MyWorld {
        try await call("my_world")
    }

    public func createContext(_ input: CreateContextInput) async throws -> CreatedContext {
        struct Params: Encodable, Sendable {
            let pDisplayName: String
            let pActorKind: String
            let pActorSubtype: String
            let pVisibility: String
            enum CodingKeys: String, CodingKey {
                case pDisplayName = "p_display_name"
                case pActorKind = "p_actor_kind"
                case pActorSubtype = "p_actor_subtype"
                case pVisibility = "p_visibility"
            }
        }
        return try await call("create_context", params: Params(
            pDisplayName: input.displayName,
            pActorKind: input.actorKind.rawValue,
            pActorSubtype: input.actorSubtype,
            pVisibility: input.visibility
        ))
    }

    // MARK: - Invites & membership

    public func createInvite(contextId: UUID, maxUses: Int?, expiresAt: Date?) async throws -> InviteCreated {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pMaxUses: Int?
            let pExpiresAt: Date?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pMaxUses = "p_max_uses"
                case pExpiresAt = "p_expires_at"
            }
        }
        return try await call("create_invite", params: Params(
            pContextActorId: contextId, pMaxUses: maxUses, pExpiresAt: expiresAt
        ))
    }

    public func revokeInvite(inviteId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pInviteId: UUID
            enum CodingKeys: String, CodingKey { case pInviteId = "p_invite_id" }
        }
        try await callVoid("revoke_invite", params: Params(pInviteId: inviteId))
    }

    public func joinByInviteCode(_ code: String) async throws -> JoinResult {
        struct Params: Encodable, Sendable {
            let pCode: String
            enum CodingKeys: String, CodingKey { case pCode = "p_code" }
        }
        return try await call("join_by_invite_code", params: Params(pCode: code))
    }

    public func removeMember(contextId: UUID, memberActorId: UUID, reason: String?) async throws {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pMemberActorId: UUID
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pMemberActorId = "p_member_actor_id"
                case pReason = "p_reason"
            }
        }
        try await callVoid("remove_member", params: Params(
            pContextActorId: contextId, pMemberActorId: memberActorId, pReason: reason
        ))
    }

    public func leaveContext(contextId: UUID) async throws {
        try await callVoid("leave_context", params: ContextIdParams(contextId: contextId))
    }

    public func assignRole(contextId: UUID, memberActorId: UUID, roleKey: String) async throws {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pMemberActorId: UUID
            let pRoleKey: String
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pMemberActorId = "p_member_actor_id"
                case pRoleKey = "p_role_key"
            }
        }
        try await callVoid("assign_role", params: Params(
            pContextActorId: contextId, pMemberActorId: memberActorId, pRoleKey: roleKey
        ))
    }

    // MARK: - Resources & rights

    public func createResource(_ input: CreateResourceInput) async throws -> Resource {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pResourceType: String
            let pDisplayName: String
            let pDescription: String?
            let pEstimatedValue: Double?
            let pCurrency: String?
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pResourceType = "p_resource_type"
                case pDisplayName = "p_display_name"
                case pDescription = "p_description"
                case pEstimatedValue = "p_estimated_value"
                case pCurrency = "p_currency"
                case pClientId = "p_client_id"
            }
        }
        let created: ResourceCreated = try await call("create_resource", params: Params(
            pContextActorId: input.contextId,
            pResourceType: input.resourceType.rawValue,
            pDisplayName: input.displayName,
            pDescription: input.description,
            pEstimatedValue: input.estimatedValue,
            pCurrency: input.currency,
            pClientId: input.clientId
        ))
        return created.resource
    }

    public func listContextResources(contextId: UUID) async throws -> [ContextResource] {
        try await call("list_context_resources", params: ContextIdParams(contextId: contextId))
    }

    public func resourceDetail(resourceId: UUID) async throws -> ResourceDetail {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        return try await call("resource_detail", params: Params(pResourceId: resourceId))
    }

    public func grantRight(_ input: GrantRightInput) async throws -> UUID {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pHolderActorId: UUID
            let pRightKind: String
            let pPercent: Double?
            let pScope: String?
            let pStartsAt: Date?
            let pEndsAt: Date?
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pHolderActorId = "p_holder_actor_id"
                case pRightKind = "p_right_kind"
                case pPercent = "p_percent"
                case pScope = "p_scope"
                case pStartsAt = "p_starts_at"
                case pEndsAt = "p_ends_at"
            }
        }
        struct Result: Decodable {
            let rightId: UUID
            enum CodingKeys: String, CodingKey { case rightId = "right_id" }
        }
        let result: Result = try await call("grant_right", params: Params(
            pResourceId: input.resourceId,
            pHolderActorId: input.holderActorId,
            pRightKind: input.rightKind.rawValue,
            pPercent: input.percent,
            pScope: input.scope,
            pStartsAt: input.startsAt,
            pEndsAt: input.endsAt
        ))
        return result.rightId
    }

    public func revokeRight(rightId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pRightId: UUID
            enum CodingKeys: String, CodingKey { case pRightId = "p_right_id" }
        }
        try await callVoid("revoke_right", params: Params(pRightId: rightId))
    }

    public func updateResource(_ input: UpdateResourceInput) async throws -> Resource {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pDisplayName: String?
            let pDescription: String?
            let pEstimatedValue: Double?
            let pCurrency: String?
            let pMetadata: JSONValue?
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pDisplayName = "p_display_name"
                case pDescription = "p_description"
                case pEstimatedValue = "p_estimated_value"
                case pCurrency = "p_currency"
                case pMetadata = "p_metadata"
            }
        }
        struct Updated: Decodable {
            let resource: Resource
        }
        let result: Updated = try await call("update_resource", params: Params(
            pResourceId: input.resourceId,
            pDisplayName: input.displayName,
            pDescription: input.description,
            pEstimatedValue: input.estimatedValue,
            pCurrency: input.currency,
            pMetadata: input.metadata
        ))
        return result.resource
    }

    public func transferResourceOwnership(resourceId: UUID, toActorId: UUID, reason: String?) async throws -> TransferOwnershipResult {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pToActorId: UUID
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pToActorId = "p_to_actor_id"
                case pReason = "p_reason"
            }
        }
        return try await call("transfer_resource_ownership", params: Params(
            pResourceId: resourceId, pToActorId: toActorId, pReason: reason
        ))
    }

    public func archiveResource(resourceId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        try await callVoid("archive_resource", params: Params(pResourceId: resourceId))
    }

    // MARK: - Events

    public func createCalendarEvent(_ input: CreateEventInput) async throws -> CalendarEvent {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pTitle: String
            let pEventType: String
            let pStartsAt: Date
            let pEndsAt: Date?
            let pDescription: String?
            let pLocationText: String?
            let pRecurrenceRule: String?
            let pHostActorId: UUID?
            let pInviteAllMembers: Bool
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pTitle = "p_title"
                case pEventType = "p_event_type"
                case pStartsAt = "p_starts_at"
                case pEndsAt = "p_ends_at"
                case pDescription = "p_description"
                case pLocationText = "p_location_text"
                case pRecurrenceRule = "p_recurrence_rule"
                case pHostActorId = "p_host_actor_id"
                case pInviteAllMembers = "p_invite_all_members"
                case pClientId = "p_client_id"
            }
        }
        let created: EventCreated = try await call("create_calendar_event", params: Params(
            pContextActorId: input.contextId,
            pTitle: input.title,
            pEventType: input.eventType.rawValue,
            pStartsAt: input.startsAt,
            pEndsAt: input.endsAt,
            pDescription: input.description,
            pLocationText: input.locationText,
            pRecurrenceRule: input.recurrenceRule,
            pHostActorId: input.hostActorId,
            pInviteAllMembers: input.inviteAllMembers,
            pClientId: input.clientId
        ))
        return created.event
    }

    public func listEvents(contextId: UUID) async throws -> [CalendarEvent] {
        do {
            return try await client
                .from("calendar_events")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("starts_at", ascending: false)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func getEvent(eventId: UUID) async throws -> CalendarEvent {
        do {
            let rows: [CalendarEvent] = try await client
                .from("calendar_events")
                .select()
                .eq("id", value: eventId.uuidString)
                .limit(1)
                .execute()
                .value
            guard let event = rows.first else {
                throw RuulError.unexpected(message: "Evento no encontrado")
            }
            return event
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listEventParticipants(eventId: UUID) async throws -> [EventParticipant] {
        do {
            return try await client
                .from("event_participants")
                .select()
                .eq("event_id", value: eventId.uuidString)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func rsvpEvent(eventId: UUID, status: RSVPStatus) async throws {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pStatus: String
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pStatus = "p_status"
            }
        }
        try await callVoid("rsvp_event", params: Params(pEventId: eventId, pStatus: status.rawValue))
    }

    public func checkInParticipant(eventId: UUID, participantActorId: UUID?) async throws -> CheckInResult {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pParticipantActorId: UUID?
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pParticipantActorId = "p_participant_actor_id"
            }
        }
        return try await call("check_in_participant", params: Params(
            pEventId: eventId, pParticipantActorId: participantActorId
        ))
    }

    public func cancelParticipation(eventId: UUID) async throws -> CancelParticipationResult {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
        }
        return try await call("cancel_participation", params: Params(pEventId: eventId))
    }

    public func closeEvent(eventId: UUID) async throws -> CloseEventResult {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
        }
        return try await call("close_event", params: Params(pEventId: eventId))
    }

    // MARK: - Rules

    public func createRule(_ input: CreateRuleInput) async throws -> Rule {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pTitle: String
            let pTriggerEventType: String?
            let pConditionTree: JSONValue?
            let pConsequences: JSONValue?
            let pBody: String?
            let pRuleType: String
            let pSeverity: Int
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pTitle = "p_title"
                case pTriggerEventType = "p_trigger_event_type"
                case pConditionTree = "p_condition_tree"
                case pConsequences = "p_consequences"
                case pBody = "p_body"
                case pRuleType = "p_rule_type"
                case pSeverity = "p_severity"
            }
        }
        let created: RuleCreated = try await call("create_rule", params: Params(
            pContextActorId: input.contextId,
            pTitle: input.title,
            pTriggerEventType: input.triggerEventType,
            pConditionTree: input.conditionTree,
            pConsequences: input.consequences,
            pBody: input.body,
            pRuleType: input.ruleType,
            pSeverity: input.severity
        ))
        return created.rule
    }

    public func listRules(contextId: UUID) async throws -> [Rule] {
        do {
            return try await client
                .from("rules")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Reservations

    public func requestReservation(_ input: RequestReservationInput) async throws -> ReservationRequestResult {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pContextActorId: UUID
            let pStartsAt: Date
            let pEndsAt: Date
            let pReservedForActorId: UUID?
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pContextActorId = "p_context_actor_id"
                case pStartsAt = "p_starts_at"
                case pEndsAt = "p_ends_at"
                case pReservedForActorId = "p_reserved_for_actor_id"
                case pClientId = "p_client_id"
            }
        }
        return try await call("request_resource_reservation", params: Params(
            pResourceId: input.resourceId,
            pContextActorId: input.contextId,
            pStartsAt: input.startsAt,
            pEndsAt: input.endsAt,
            pReservedForActorId: input.reservedForActorId,
            pClientId: input.clientId
        ))
    }

    public func listReservations(resourceId: UUID) async throws -> [Reservation] {
        do {
            return try await client
                .from("resource_reservations")
                .select()
                .eq("resource_id", value: resourceId.uuidString)
                .order("starts_at", ascending: true)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listContextReservations(contextId: UUID) async throws -> [Reservation] {
        do {
            return try await client
                .from("resource_reservations")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("starts_at", ascending: true)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listConflicts(resourceId: UUID) async throws -> [ReservationConflict] {
        do {
            return try await client
                .from("reservation_conflicts")
                .select()
                .eq("resource_id", value: resourceId.uuidString)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func reservationDetail(reservationId: UUID) async throws -> ReservationDetail {
        try await call("reservation_detail", params: ReservationIdParams(reservationId: reservationId))
    }

    public func approveReservation(reservationId: UUID) async throws {
        try await callVoid("approve_reservation", params: ReservationIdParams(reservationId: reservationId))
    }

    public func confirmReservation(reservationId: UUID) async throws {
        try await callVoid("confirm_reservation", params: ReservationIdParams(reservationId: reservationId))
    }

    public func cancelReservation(reservationId: UUID) async throws {
        try await callVoid("cancel_reservation", params: ReservationIdParams(reservationId: reservationId))
    }

    public func resolveReservationConflict(conflictId: UUID, winnerReservationId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pConflictId: UUID
            let pWinnerReservationId: UUID
            enum CodingKeys: String, CodingKey {
                case pConflictId = "p_conflict_id"
                case pWinnerReservationId = "p_winner_reservation_id"
            }
        }
        try await callVoid("resolve_reservation_conflict", params: Params(
            pConflictId: conflictId, pWinnerReservationId: winnerReservationId
        ))
    }

    // MARK: - Decisions

    public func createDecision(_ input: CreateDecisionInput) async throws -> Decision {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDecisionType: String
            let pTitle: String
            let pDescription: String?
            let pClosesAt: Date?
            let pPayload: JSONValue?
            let pClientId: String?
            let pVotingModel: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDecisionType = "p_decision_type"
                case pTitle = "p_title"
                case pDescription = "p_description"
                case pClosesAt = "p_closes_at"
                case pPayload = "p_payload"
                case pClientId = "p_client_id"
                case pVotingModel = "p_voting_model"
            }
        }
        let created: DecisionCreated = try await call("create_decision", params: Params(
            pContextActorId: input.contextId,
            pDecisionType: input.decisionType.rawValue,
            pTitle: input.title,
            pDescription: input.description,
            pClosesAt: input.closesAt,
            pPayload: input.payload,
            pClientId: input.clientId,
            pVotingModel: input.votingModel?.rawValue
        ))
        return created.decision
    }

    public func listDecisions(contextId: UUID) async throws -> [Decision] {
        do {
            return try await client
                .from("decisions")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listDecisionVotes(decisionId: UUID) async throws -> [DecisionVote] {
        do {
            return try await client
                .from("decision_votes")
                .select()
                .eq("decision_id", value: decisionId.uuidString)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func voteDecision(decisionId: UUID, vote: VoteChoice, option: String?) async throws -> VoteResult {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pVote: String
            let pOption: String?
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pVote = "p_vote"
                case pOption = "p_option"
            }
        }
        return try await call("vote_decision", params: Params(
            pDecisionId: decisionId, pVote: vote.rawValue, pOption: option
        ))
    }

    public func closeDecision(decisionId: UUID) async throws -> VoteResult {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
        }
        return try await call("close_decision", params: Params(pDecisionId: decisionId))
    }

    public func executeDecision(decisionId: UUID, result: JSONValue?) async throws {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pResult: JSONValue?
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pResult = "p_result"
            }
        }
        try await callVoid("execute_decision", params: Params(pDecisionId: decisionId, pResult: result))
    }

    public func decisionDetail(decisionId: UUID) async throws -> DecisionDetail {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
        }
        return try await call("decision_detail", params: Params(pDecisionId: decisionId))
    }

    public func listDecisionOptions(decisionId: UUID) async throws -> [DecisionOption] {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
        }
        return try await call("list_decision_options", params: Params(pDecisionId: decisionId))
    }

    public func voteForOption(decisionId: UUID, optionId: UUID) async throws -> VoteResult {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pOptionId: UUID
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pOptionId = "p_option_id"
            }
        }
        return try await call("vote_for_option", params: Params(pDecisionId: decisionId, pOptionId: optionId))
    }

    public func createDecisionOption(_ input: CreateDecisionOptionInput) async throws -> DecisionOption {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pOptionKey: String
            let pTitle: String
            let pDescription: String?
            let pPayload: JSONValue?
            let pSortOrder: Int?
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pOptionKey = "p_option_key"
                case pTitle = "p_title"
                case pDescription = "p_description"
                case pPayload = "p_payload"
                case pSortOrder = "p_sort_order"
            }
        }
        struct Response: Decodable {
            let option: DecisionOption
        }
        let response: Response = try await call("create_decision_option", params: Params(
            pDecisionId: input.decisionId,
            pOptionKey: input.optionKey,
            pTitle: input.title,
            pDescription: input.description,
            pPayload: input.payload,
            pSortOrder: input.sortOrder
        ))
        return response.option
    }

    // MARK: - Money

    public func recordExpense(_ input: RecordExpenseInput) async throws -> ExpenseResult {
        struct WireSplit: Encodable, Sendable {
            let actorId: UUID
            let amount: Double
            enum CodingKeys: String, CodingKey {
                case actorId = "actor_id"
                case amount
            }
        }
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pAmount: Double
            let pCurrency: String
            let pDescription: String
            let pSplitWith: [UUID]?
            let pExcludedActorIds: [UUID]?
            let pSplitMethod: String
            let pSplits: [WireSplit]?
            let pEventId: UUID?
            let pPaidByActorId: UUID?
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pAmount = "p_amount"
                case pCurrency = "p_currency"
                case pDescription = "p_description"
                case pSplitWith = "p_split_with"
                case pExcludedActorIds = "p_excluded_actor_ids"
                case pSplitMethod = "p_split_method"
                case pSplits = "p_splits"
                case pEventId = "p_event_id"
                case pPaidByActorId = "p_paid_by_actor_id"
                case pClientId = "p_client_id"
            }
        }
        return try await call("record_expense", params: Params(
            pContextActorId: input.contextId,
            pAmount: input.amount,
            pCurrency: input.currency,
            pDescription: input.description,
            pSplitWith: input.splitWith,
            pExcludedActorIds: input.excludedActorIds,
            pSplitMethod: input.splitMethod,
            pSplits: input.splits?.map { WireSplit(actorId: $0.actorId, amount: $0.amount) },
            pEventId: input.eventId,
            pPaidByActorId: input.paidByActorId,
            pClientId: input.clientId
        ))
    }

    public func recordFine(contextId: UUID, debtorActorId: UUID, amount: Double, currency: String, reason: String?) async throws -> UUID {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDebtorActorId: UUID
            let pAmount: Double
            let pCurrency: String
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDebtorActorId = "p_debtor_actor_id"
                case pAmount = "p_amount"
                case pCurrency = "p_currency"
                case pReason = "p_reason"
            }
        }
        struct Result: Decodable {
            let obligationId: UUID
            enum CodingKeys: String, CodingKey { case obligationId = "obligation_id" }
        }
        let result: Result = try await call("record_fine", params: Params(
            pContextActorId: contextId,
            pDebtorActorId: debtorActorId,
            pAmount: amount,
            pCurrency: currency,
            pReason: reason
        ))
        return result.obligationId
    }

    public func recordGameResult(_ input: RecordGameResultInput) async throws -> GameResultRecorded {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pEventId: UUID?
            let pGameName: String
            let pWinnerActorId: UUID
            let pLoserActorId: UUID
            let pAmount: Double
            let pCurrency: String
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pEventId = "p_event_id"
                case pGameName = "p_game_name"
                case pWinnerActorId = "p_winner_actor_id"
                case pLoserActorId = "p_loser_actor_id"
                case pAmount = "p_amount"
                case pCurrency = "p_currency"
                case pClientId = "p_client_id"
            }
        }
        return try await call("record_game_result", params: Params(
            pContextActorId: input.contextId,
            pEventId: input.eventId,
            pGameName: input.gameName,
            pWinnerActorId: input.winnerActorId,
            pLoserActorId: input.loserActorId,
            pAmount: input.amount,
            pCurrency: input.currency,
            pClientId: input.clientId
        ))
    }

    public func listObligations(contextId: UUID) async throws -> [Obligation] {
        do {
            return try await client
                .from("obligations")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - R.2R Obligations universales

    public func createActionObligation(_ input: CreateActionObligationInput) async throws -> ActionObligationCreated {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDebtorActorId: UUID
            let pTitle: String
            let pKind: String
            let pDescription: String?
            let pDueAt: Date?
            let pCreditorActorId: UUID?
            let pSourceEventId: UUID?
            let pSourceReservationId: UUID?
            let pSourceDecisionId: UUID?
            let pMetadata: JSONValue?
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDebtorActorId = "p_debtor_actor_id"
                case pTitle = "p_title"
                case pKind = "p_kind"
                case pDescription = "p_description"
                case pDueAt = "p_due_at"
                case pCreditorActorId = "p_creditor_actor_id"
                case pSourceEventId = "p_source_event_id"
                case pSourceReservationId = "p_source_reservation_id"
                case pSourceDecisionId = "p_source_decision_id"
                case pMetadata = "p_metadata"
                case pClientId = "p_client_id"
            }
        }
        return try await call("create_action_obligation", params: Params(
            pContextActorId: input.contextId,
            pDebtorActorId: input.debtorActorId,
            pTitle: input.title,
            pKind: input.kind,
            pDescription: input.description,
            pDueAt: input.dueAt,
            pCreditorActorId: input.creditorActorId,
            pSourceEventId: input.sourceEventId,
            pSourceReservationId: input.sourceReservationId,
            pSourceDecisionId: input.sourceDecisionId,
            pMetadata: input.metadata,
            pClientId: input.clientId
        ))
    }

    public func completeObligation(obligationId: UUID, completionNotes: String?, completionMetadata: JSONValue?) async throws -> ObligationCompletedResult {
        struct Params: Encodable, Sendable {
            let pObligationId: UUID
            let pCompletionNotes: String?
            let pCompletionMetadata: JSONValue?
            enum CodingKeys: String, CodingKey {
                case pObligationId = "p_obligation_id"
                case pCompletionNotes = "p_completion_notes"
                case pCompletionMetadata = "p_completion_metadata"
            }
        }
        return try await call("complete_obligation", params: Params(
            pObligationId: obligationId,
            pCompletionNotes: completionNotes,
            pCompletionMetadata: completionMetadata
        ))
    }

    public func obligationDetail(obligationId: UUID) async throws -> ObligationDetail {
        struct Params: Encodable, Sendable {
            let pObligationId: UUID
            enum CodingKeys: String, CodingKey { case pObligationId = "p_obligation_id" }
        }
        return try await call("obligation_detail", params: Params(pObligationId: obligationId))
    }

    // MARK: - Settlement

    public func generateSettlementBatch(contextId: UUID, currency: String) async throws -> SettlementBatchResult {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pCurrency: String
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pCurrency = "p_currency"
            }
        }
        return try await call("generate_settlement_batch", params: Params(
            pContextActorId: contextId, pCurrency: currency
        ))
    }

    public func listSettlementBatches(contextId: UUID) async throws -> [SettlementBatch] {
        do {
            return try await client
                .from("settlement_batches")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listSettlementItems(batchId: UUID) async throws -> [SettlementItem] {
        do {
            return try await client
                .from("settlement_items")
                .select()
                .eq("settlement_batch_id", value: batchId.uuidString)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func markSettlementPaid(itemId: UUID) async throws -> MarkPaidResult {
        struct Params: Encodable, Sendable {
            let pSettlementItemId: UUID
            enum CodingKeys: String, CodingKey { case pSettlementItemId = "p_settlement_item_id" }
        }
        return try await call("mark_settlement_paid", params: Params(pSettlementItemId: itemId))
    }

    // MARK: - Explanation engine (R.2S.10)

    public func whyCanViewResource(actorId: UUID, resourceId: UUID) async throws -> WhyCanViewResource {
        try await call("why_can_view_resource", params: ActorResourceParams(actorId: actorId, resourceId: resourceId))
    }

    public func whyCanReserve(actorId: UUID, resourceId: UUID) async throws -> WhyCanReserve {
        try await call("why_can_reserve", params: ActorResourceParams(actorId: actorId, resourceId: resourceId))
    }

    public func whyDecisionResult(decisionId: UUID) async throws -> WhyDecisionResult {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
        }
        return try await call("why_decision_result", params: Params(pDecisionId: decisionId))
    }

    public func whyReservationWon(conflictId: UUID) async throws -> WhyReservationWon {
        struct Params: Encodable, Sendable {
            let pConflictId: UUID
            enum CodingKeys: String, CodingKey { case pConflictId = "p_conflict_id" }
        }
        return try await call("why_reservation_won", params: Params(pConflictId: conflictId))
    }

    public func whyObligationExists(obligationId: UUID) async throws -> WhyObligationExists {
        struct Params: Encodable, Sendable {
            let pObligationId: UUID
            enum CodingKeys: String, CodingKey { case pObligationId = "p_obligation_id" }
        }
        return try await call("why_obligation_exists", params: Params(pObligationId: obligationId))
    }

    // MARK: - Activity

    public func listActivity(contextId: UUID, limit: Int, before: Date?) async throws -> [ActivityEvent] {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pLimit: Int
            let pBefore: Date?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pLimit = "p_limit"
                case pBefore = "p_before"
            }
        }
        let page: ActivityPage = try await call("list_activity", params: Params(
            pContextActorId: contextId, pLimit: limit, pBefore: before
        ))
        return page.activity
    }
}

// MARK: - Params compartidos

private struct ContextIdParams: Encodable, Sendable {
    let contextId: UUID
    enum CodingKeys: String, CodingKey { case contextId = "p_context_actor_id" }
}

private struct ActorResourceParams: Encodable, Sendable {
    let actorId: UUID
    let resourceId: UUID
    enum CodingKeys: String, CodingKey {
        case actorId = "p_actor_id"
        case resourceId = "p_resource_id"
    }
}

private struct ReservationIdParams: Encodable, Sendable {
    let reservationId: UUID
    enum CodingKeys: String, CodingKey { case reservationId = "p_reservation_id" }
}
