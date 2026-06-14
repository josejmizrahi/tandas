# Frontend ↔ Backend Contract Map — Ruul iOS

**Fecha:** 2026-06-11 (revisión 2026-06-14)
**Fuentes:** `RuulCore/API/RuulRPCClient.swift` (protocolo, 167 métodos),
`SupabaseRuulRPCClient.swift` (live), `Plans/Active/MVP2_iOS_Contract.md`,
migrations `supabase/migrations/2026*`.

**Estado del contrato: COMPLETO Y COHERENTE.** 167/167 métodos iOS mapean 1:1 a RPCs
del backend o a lecturas PostgREST legítimas. Cero drift de protocolo. Idempotencia
(`p_client_id`) consistente en los 11 RPCs que la soportan.

**Drift detectado en la capa de consumo** (no en el contrato): el centro de
notificaciones y el AttentionInbox consumen tablas distintas (`notifications` R.4D vs
`attention_inbox()` RPC) sin unificación en la UI; el tap de `NotificationCenterView`
no usa el `AttentionDispatcher` que sí enruta correctamente desde HomeView/Context.
Ver `FrontendMissingFeatures.md` §Deltas D2.

---

## 1. Mapa pantalla → store → RPC → modelo → tabla

### Shell / navegación

| Pantalla | Store | RPC / lectura | Modelo Swift |
|---|---|---|---|
| RuulAppShell (gates) | SessionStore, CurrentActorStore | Supabase Auth + `ensure_person_actor` | AppSession, CurrentActor |
| MainTabShell (accessory) | AttentionInboxStore | `attention_inbox`, `dismiss_attention_item` | [AttentionItem] |
| HomeView | AttentionInboxStore, ContextPreferencesStore, ActivityFeedStore | `attention_inbox`, `list_recent_contexts`, `activity_feed` | AttentionItem, ContextPreference, ActivityFeed |
| ContextsListView | ContextStore, ContextPreferencesStore, InvitationsStore | `context_candidates`, `list_context_favorites`, `list_recent_contexts`, `mark_context_visited/favorite` | ContextCandidates, ContextPreference, PendingInvitation |
| CreateIntentSheet | ActorCapabilitiesStore | `actor_capabilities`, `actor_capabilities_catalog` | ActorCapabilities |
| ClaimPlaceholdersGate | (container) | `find_placeholder_matches_for_me`, `claim_placeholder_actor` | PlaceholderMatchesResult |

### Auth / perfil

| Pantalla | Store | RPC / lectura | Modelo Swift |
|---|---|---|---|
| SignedOutView | SessionStore (vía AuthService) | Supabase Auth: signInWithIdToken (Apple), signInWithOTP, verifyOTP | AppSession |
| EditProfileView | CurrentActorStore | `update_my_profile` | CurrentActor |
| PersonalSettingsView | PersonalSettingsStore | `personal_settings_summary`, `update_my_profile(p_metadata)` | PersonalSettings |
| MeView + My* (9 vistas) | fan-out por contexto | `my_world`, `list_obligations`*, `list_decisions`*, `list_rules`*, `list_context_documents`, reservations*, `list_my_subscriptions`, `list_trust_network` | MyWorld, Obligation, Decision, Rule, Document, Reservation, SubscriptionList, TrustNetwork |

(* = lectura PostgREST, ver §4)

### Contextos / membresía

| Pantalla | Store | RPC / lectura | Modelo Swift |
|---|---|---|---|
| CreateContextView | ContextStore | `create_context`, `context_creation_candidates` | CreatedContext |
| CreateChildContextSheet | ContextHierarchyStore | `create_child_context` | CreatedChildContext |
| ContextDetailViewV2 (7 tabs) | ContextDescriptorStore | `context_detail_descriptor` | ContextDetailDescriptor (sections+widgets+actions+previews) |
| ContextSettingsView | ContextSettingsStore, GovernanceStore | `context_settings_summary`, `update_context`, `list_governance_policies`, `create_governance_policy`, `delegate_vote`, `revoke_vote_delegation` | ContextSettings, GovernancePolicy, VoteDelegation |
| MembersListView / MemberDetailView | MembersStore | `context_summary`, `assign_role`, `remove_member`, `leave_context`, `member_available_actions`, `request_governance_action` | ContextSummary, ContextMember, AvailableAction |
| InviteMembersView | MembersStore | `create_invite`, `invite_member`, `create_placeholder_person` (`revoke_invite` sin UI) | InviteCreated, InviteMemberResult, PlaceholderPersonResult |
| JoinByCodeView | ContextStore | `join_by_invite_code` | JoinResult |
| PendingInvitationsView | InvitationsStore | PostgREST `actor_memberships` (status='invited') + `accept_invitation` | PendingInvitation, AcceptInvitationResult |

### Recursos / reservas / documentos

| Pantalla | Store | RPC / lectura | Modelo Swift |
|---|---|---|---|
| CreateResourceFlow | ResourcesStore | `list_resource_classes`, `list_resource_subtypes`, `resource_creation_candidates`, `create_resource` | ResourceClass, ResourceSubtype, Resource |
| ResourcesListView | ResourcesStore | `list_context_resources` / `my_world` (personal) | ContextResource |
| ResourceDetailViewV2 | ResourceDescriptorStore | `resource_detail_descriptor`, `execute_resource_action`, `grant_right`, `revoke_right`, `archive_resource`, `transfer_resource_ownership` (vía governance), `list_resource_conflicts`, `why_can_view_resource` | ResourceDetailDescriptor, ResourceRight, ResourceConflictList |
| EditResourceView | — | `update_resource` | Resource |
| ResourceActionFormView | — | `execute_resource_action(p_payload, p_client_id)` | ExecuteResourceActionResult |
| RequestReservationView | ReservationsStore | `request_resource_reservation`, `why_can_reserve` | ReservationRequestResult |
| Reservations List/Calendar/Context | ReservationsStore | PostgREST `resource_reservations` (3 filtros), `reservation_detail`, `approve/confirm/cancel_reservation` | Reservation, ReservationDetail |
| ReservationConflictView | ReservationsStore | PostgREST `reservation_conflicts`, `resolve_reservation_conflict(p_resolution_model)`, `why_reservation_won` | ReservationConflict, ResolveConflictResult |
| AttachDocumentView / DocumentDetailView | DocumentsStore | Storage upload + `register_document`, `list_context_documents`, `archive_document`, signed URL | Document, DocumentRegistered |

### Eventos

| Pantalla | Store | RPC / lectura | Modelo Swift |
|---|---|---|---|
| CreateEventView / EditEventView | EventsStore | `create_calendar_event` / `update_calendar_event` (recurrence count/until, location modes) | CalendarEvent |
| EventsListView / calendarios | EventsStore | PostgREST `calendar_events`, `event_participants` | CalendarEvent, EventParticipant |
| EventDetailView | EventDetailStore | `event_detail`, `rsvp_event`, `check_in_participant`, `cancel_participation`, `close_event`, `add/remove_event_participants`, `set_event_participant_plus_count`, `add/remove_event_guest`, `list_event_guests`, `host_confirm_participant`, `preview_next_host`, `set_next_host`, `set_host_rotation_order`, `listReservationsByEvent` (PostgREST por source_event_id) | EventDetail, CheckInResult, CloseEventResult, NextHostPreview, EventGuest |

### Money / settlement / pools

| Pantalla | Store | RPC / lectura | Modelo Swift |
|---|---|---|---|
| MoneyHomeView | MoneyStore | PostgREST `obligations`, `context_summary`, `list_activity` (filtrada money) | Obligation, ActivityEvent |
| RecordExpenseView | MoneyStore | `record_expense(p_split_basis, p_source_event_id, p_client_id)`, `preview_event_split` | ExpenseResult, EventSplitPreview |
| RecordGameResultView / Fine | MoneyStore | `record_game_result(p_client_id)`, `record_fine` | GameResultRecorded |
| CreateObligationView / Edit | MoneyStore | `create_action_obligation(p_client_id)`, `update_obligation` | ActionObligationCreated, Obligation |
| ObligationDetailView | — | `obligation_detail`, `complete_obligation`, `forgive_obligation` (directo o `request_governance_action`), `why_obligation_exists` | ObligationDetail, WhyObligationExists |
| SettlementView | SettlementStore | `generate_settlement_batch`, PostgREST `settlement_batches`/`settlement_items`, `mark/confirm/reject/appeal_settlement_paid` | SettlementBatchResult, SettlementItem, MarkPaidResult |
| PoolsListView / CreatePoolSheet / PoolDetailView | PoolsStore, PoolDetailStore | `list_context_pools`, `create_pool`, `pool_account_detail`, `contribute_to_pool`, `preview_pool_resolution`, `resolve_pool` (todas con p_client_id) | PoolAccount, PoolAccountDetail, PoolResolutionPreview/Result |

### Reglas / decisiones / governance / actividad

| Pantalla | Store | RPC / lectura | Modelo Swift |
|---|---|---|---|
| RulesListView / CreateRuleWizard / RuleDetail / EditRule | RulesStore | PostgREST `rules`, `create_rule`, `update_rule`, `archive_rule` (vía `request_governance_action("rule.archive")`) | Rule, RuleArchivedResult |
| DecisionsListView / CreateDecisionView | DecisionsStore | PostgREST `decisions`, `create_decision(p_voting_model, p_client_id)`, `create_decision_option` | Decision, DecisionOption |
| DecisionDetailView | DecisionDetailStore | `decision_detail`, `vote_decision`, `vote_for_option`, `unvote_option`, `close_decision`, `execute_decision`, `why_decision_result`, PostgREST `decision_votes` | DecisionDetail, VoteResult |
| ActivityFeedView | ActivityStore | `list_activity(p_include_descendants, p_before)` | [ActivityEvent] |
| MyActivityFeedView | ActivityFeedStore | `activity_feed(p_actor_id)` | ActivityFeed |
| Attention (Home/accessory/context) | AttentionInboxStore | `attention_inbox`, `dismiss_attention_item` | [AttentionItem] |
| Conflictos de contexto | — | `list_context_conflicts`, `detect_context_conflicts`, `resolve_resource_conflict` | ContextConflictList |
| Similarity guards (create context/resource) | SimilarityStore | `context_creation_candidates`, `resource_creation_candidates`, `dismiss_suggestion` | *CreationCandidate |
| Subscribe button | SubscriptionsStore | `subscribe`, `unsubscribe`, `mark_as_stakeholder`, `list_my_subscriptions` | Subscription |
| MyTrustNetworkView | — | `list_trust_network`, `add_trust`, `remove_trust` | TrustNetwork |

---

## 2. Cobertura por dominio (protocolo vs backend)

| Dominio | Métodos iOS | Cobertura |
|---|---|---|
| Identity / Capabilities | 10 | 100% |
| Contexts + Hierarchy | 21 | 100% |
| Invites & Membership | 11 | 100% |
| Resources & Rights | 15 | 100% |
| Events | 20 | 100% |
| Rules | 4 | 100% |
| Reservations + Conflicts (R.2S/R.5B) | 17 | 100% |
| Decisions | 12 | 100% |
| Money | 10 | 100% |
| Pools (R.8) | 6 | 100% |
| Settlement | 7 | 100% |
| Documents | 6 | 100% |
| Explanations (R.2S.10) | 5 | 100% |
| Activity / Similarity / Subscriptions & Trust | 19 | 100% |
| Navigation (F.NAV) | 6 | 100% |
| Governance (R.5/R.7) | 7 | 100% |
| **Total** | **167** | **100%** |

## 3. RPCs backend SIN método iOS (28) — clasificados

**Accionables (= candidatos de FrontendMissingFeatures):**
- `mark_notification_read` / `mark_notification_archived` / `mark_all_notifications_read`
  — R.4D listo en backend; falta centro de notificaciones (P1.1).
- `void_transaction` — AUDIT.1; falta UI admin (P1.9).
- `set_membership_state` — suspensión directa; falta UI (P1.5).
- `set_resource_relation` / `remove_resource_relation` / `list_resource_relations` —
  R.0D; el descriptor ya muestra relaciones read-only (P2.9).
- `set_resource_capability_override` — admin tooling, post-MVP.
- `activity_event_catalog` — metadatos para humanizar payloads (útil para P1.18).

**No accionables (correcto que iOS no los llame):**
- Nested en descriptors: `context/decision/event/obligation/reservation_available_actions`,
  `resource_can`, `resource_capabilities`, `effective_resource_capabilities`.
- Deprecados: `request_governed_action`, `set_event_participant_plus_one`, `decision_results`.
- Internos/sistema: `execute_governance_action` (dispatch del backend tras aprobar la
  decisión), `emit_notification`, `current_actor_id`, `current_person_actor_id`,
  `system_actor_id`, `update_governance_policy` (iOS usa create como upsert).

## 4. Lecturas PostgREST directas (RLS read-only) — 13 tablas

| Tabla | Métodos iOS | Filtro | Soft-delete |
|---|---|---|---|
| `actor_memberships` | listMyPendingInvitations | member_actor_id + status='invited' | — |
| `calendar_events` | listEvents, getEvent | context_actor_id | — |
| `event_participants` | listEventParticipants | event_id | — |
| `decisions` | listDecisions | context_actor_id | — |
| `decision_votes` | listDecisionVotes | decision_id | — |
| `rules` | listRules | context_actor_id | — |
| `obligations` | listObligations | context_actor_id | — |
| `resource_reservations` | listReservations / listContextReservations / listReservationsByEvent | resource_id / context_actor_id / source_event_id | — |
| `reservation_conflicts` | listConflicts | resource_id | — |
| `settlement_batches` | listSettlementBatches | context_actor_id | — |
| `settlement_items` | listSettlementItems | settlement_batch_id | — |
| `documents` | listResourceDocuments | resource_id + archived_at IS NULL | ✓ |
| `vote_delegations` | listVoteDelegations | context_actor_id + revoked_at IS NULL | ✓ |

## 5. Parámetros especiales verificados (sin discrepancias)

- **Idempotencia `p_client_id`** (11 RPCs): create_resource, create_calendar_event,
  create_decision, record_expense, request_resource_reservation, record_game_result,
  request_governance_action, create_action_obligation, create_pool, contribute_to_pool,
  resolve_pool — todos enviados desde iOS vía `clientId` en los Inputs. ✓
- **`p_split_basis`** ∈ {equal, explicit, event_weights} (R.9.C) ✓
- **`p_subtype_key`** en create_resource (R.5A.B.0) ✓
- **`p_recurrence_count` / `p_recurrence_until`** (F.EVENT.9) ✓
- **`p_location_text`** con semántica nil=skip / ""=clear (F.RESOURCE.4) ✓
- **`p_include_descendants`** en list_activity (R.2U.2) ✓

## 6. Discrepancias conocidas

### 6.1 — Descriptor obligation (drift backend)
El descriptor de obligaciones (`obligation_detail.available_actions`) **anuncia**
`pay`, `dispute` y `cancel` pero no existen RPCs correspondientes; iOS las filtra con
una whitelist (`ObligationDetailView.swift:37-45`). Es drift del lado backend
(descriptor promete más de lo que el contrato ofrece). Resolver según P0.4 de
`FrontendMissingFeatures.md`.

### 6.2 — Consumo de obligaciones no doctrinario (re-audit 2026-06-14)
`MoneyHomeView` consume `obligations` vía PostgREST sin filtrar por
`paired_obligation_id`, violando la doctrina R.8.A Option C firmada 2026-06-10. El
contrato (columna + RPCs) está completo; el drift está en cómo iOS lo consume.
Ver `FrontendMissingFeatures.md` §Deltas D1.

### 6.3 — Bifurcación notifications ↔ attention_inbox (re-audit 2026-06-14)
Dos fuentes paralelas: `RuulNotification` (tabla `notifications` R.4D, consumida por
`NotificationCenterView`) y `AttentionItem` (RPC `attention_inbox`, consumida por
HomeView/Context/AttentionBottomAccessory). El contrato soporta ambas, pero la UI
no unifica el modelo de "qué me requiere atención". Ver `FrontendMissingFeatures.md`
§Deltas D2.
