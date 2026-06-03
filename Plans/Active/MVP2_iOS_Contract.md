# MVP2 — Contrato Backend ↔ iOS

**Fecha:** 2026-06-03 · **Fuente:** migrations `mvp2_000`…`r2k` (la definición final de cada
función gana — varias se redefinen en migrations posteriores).
**Consumidor:** `ios/Packages/RuulCore/Sources/RuulCore/API/`.

Reglas generales:

- Todos los RPCs son `SECURITY DEFINER`, ejecutables solo por `authenticated`. `anon` no ejecuta nada.
- Mapping auth↔actor: `current_actor_id()` (NULL si el user no tiene person actor → llamar `ensure_person_actor()` primero).
- Escrituras **solo** vía RPC. PostgREST queda read-only (RLS por membership/derecho).
- Idempotencia por `p_client_id` en: `create_resource`, `create_calendar_event`, `create_decision`,
  `record_expense`, `request_resource_reservation`, `record_game_result`.
- Errores: `raise exception` con mensajes en inglés (`unauthenticated`, `not a member of context %`,
  `missing permission %`, `amount must be positive`, …) → `RPCErrorMapper` los traduce.
- Timestamps en jsonb: ISO8601 **con microsegundos** (`2026-06-03T18:15:30.123456+00:00`).

## 1. Identity

| RPC | Firma | Devuelve |
|---|---|---|
| `current_actor_id()` | — | `uuid` (o null) |
| `ensure_person_actor()` | — | `{actor_id, actor: {…}, profile: {…}}` |
| `update_my_profile(p_full_name?, p_preferred_name?, p_avatar_url?, p_metadata?)` | todos opcionales | `{actor, profile}` |

## 2. Contexts

| RPC | Firma | Devuelve |
|---|---|---|
| `create_context(p_display_name, p_actor_kind='collective', p_actor_subtype='friend_group', p_visibility='private', p_metadata={})` | kind ∈ collective\|legal_entity | `{context_actor_id, context: {actor row}}` |
| `context_candidates()` | — | `{personal_context: {actor row}, contexts: [{context_actor_id, display_name, actor_kind, actor_subtype, visibility, membership_type, member_count, roles: [text]}]}` |
| `context_summary(p_context_actor_id)` | — | `{context, as_of, members_count, resources_count, pending_decisions, open_obligations, members: [{actor_id, display_name, membership_type, joined_at, roles}], my_permissions: [text], resources: [{resource_id, display_name, resource_type, estimated_value, currency}], upcoming_events: [{event_id, title, event_type, starts_at, host_actor_id, status}], open_decisions: [{decision_id, title, decision_type, payload, created_at}], money: {open_obligations: [{obligation_id, debtor_actor_id, creditor_actor_id, obligation_type, amount, currency}], my_balance}, active_rules: [{rule_id, title, trigger_event_type}], recent_activity: [{event_type, actor_id, payload, occurred_at}]}` |
| `my_world()` | — | `{actor_id, contexts: [{context_actor_id, display_name, actor_kind, actor_subtype, membership_type}], resources: [{resource_id, display_name, resource_type, reasons: [text]}], open_obligations: [{obligation_id, context_actor_id, context_name, role: debtor\|creditor, obligation_type, amount, currency}]}` |

## 3. Invites & Membership

| RPC | Firma | Devuelve |
|---|---|---|
| `create_invite(p_context_actor_id, p_max_uses?, p_expires_at?)` | requiere `context.invite` | `{invite_id, code}` |
| `revoke_invite(p_invite_id)` | | `void` |
| `join_by_invite_code(p_code)` | case-insensitive | `{context_actor_id, membership_id, context}` |
| `invite_member(p_context_actor_id, p_member_actor_id, p_membership_type='member')` | requiere `context.invite` | `{membership_id, status}` |
| `accept_invitation(p_context_actor_id)` | | `{membership_id, status, already_member?}` |
| `remove_member(p_context_actor_id, p_member_actor_id, p_reason?)` | requiere `members.manage` | `{removed: true}` |
| `leave_context(p_context_actor_id)` | self-service | `{left: bool, message?}` |
| `assign_role(p_context_actor_id, p_member_actor_id, p_role_key)` | requiere `members.manage` | `{assigned, role_key}` |

## 4. Resources & Rights

| RPC | Firma | Devuelve |
|---|---|---|
| `create_resource(p_context_actor_id, p_resource_type, p_display_name, p_description?, p_estimated_value?, p_currency?, p_metadata?, p_client_id?)` | requiere `resources.create`; trigger auto-OWN 100% al contexto | `{resource_id, resource: {row}}` |
| `list_context_resources(p_context_actor_id)` | filtra por visibilidad rights-based del caller | `[{resource_id, resource_type, display_name, status, estimated_value, currency, canonical_owner_actor_id, rights: [{right_id, holder_actor_id, right_kind, percent}]}]` |
| `resource_detail(p_resource_id)` | requiere right activo o membership del owner | `{resource: {row}, rights: [{right_id, holder_actor_id, holder_display_name, right_kind, percent, scope, starts_at, ends_at}]}` |
| `grant_right(p_resource_id, p_holder_actor_id, p_right_kind, p_percent?, p_scope?, p_starts_at?, p_ends_at?, p_metadata?)` | OWN/SELL/TRANSFER/LIEN exigen OWN o `resources.manage` del owner | `{right_id}` |
| `revoke_right(p_right_id)` | | `void` |
| `update_resource(p_resource_id, …)` | | `{resource}` |
| `archive_resource(p_resource_id)` | | `{archived, already_archived?}` |

`right_kind` ∈ OWN, USE, MANAGE, VIEW, SELL, TRANSFER, GOVERN, BENEFICIARY, LIEN, LEASE, APPROVE, AUDIT
`resource_type` ∈ property, house, vehicle, bank_account, cash_pool, contract, document, reservation, trip_booking, game, equipment, other

## 5. Calendar & Events

| RPC | Firma | Devuelve |
|---|---|---|
| `create_calendar_event(p_context_actor_id, p_title, p_event_type, p_starts_at, p_ends_at?, p_description?, p_timezone='America/Mexico_City', p_location_text?, p_recurrence_rule?, p_host_actor_id?, p_invite_all_members=true, p_metadata?, p_client_id?)` | requiere `events.create` | `{event_id, event: {row}, participants: n}` |
| `rsvp_event(p_event_id, p_status)` | status ∈ going\|maybe\|declined | `{participant_id, status}` |
| `check_in_participant(p_event_id, p_participant_actor_id?, p_checked_in_at?)` | self o `events.manage`; >15 min tarde → `late` + evalúa rules | `{participant_id, status, checked_in_at, minutes_late, rules?, already_checked_in?}` |
| `cancel_participation(p_event_id, p_participant_actor_id?, p_cancelled_at?)` | detecta same-day + evalúa rules | `{participant_id, status, cancelled_at, same_day_cancellation, rules?, already_cancelled?}` |
| `close_event(p_event_id)` | requiere `events.manage`; marca no-shows; si `recurrence_rule='weekly'` crea la siguiente instancia con host rotado | `{event_id, status, no_shows, next_event_id, next_host_actor_id, already_closed?}` |

Listas de eventos/participantes: lectura PostgREST directa (`calendar_events`, `event_participants`).
`event_type` ∈ dinner, meeting, trip, game_night, community_event, deadline, other
`participant.status` ∈ invited, going, maybe, declined, cancelled, attended, late, no_show

## 6. Rules

| RPC | Firma | Devuelve |
|---|---|---|
| `create_rule(p_context_actor_id, p_title, p_trigger_event_type?, p_condition_tree?, p_consequences?, p_body?, p_rule_type='automation', p_severity=1)` | requiere `rules.manage` | `{rule_id, rule: {row}}` |
| `evaluate_rules_for_event(p_context_actor_id, p_trigger_event_type, p_subject_actor_id, p_payload, p_source_event_id?)` | invocado automáticamente por check-in/cancel | `{rules_matched, obligations_created: [{obligation_id, rule_id, amount, already_existed}]}` |

`condition_tree`: `{"op": ">", "field": "minutes_late", "value": 15}` o `{"op": "and"|"or", "conditions": [...]}` o null (siempre match).
`consequences`: `[{"type": "fine", "amount": 100, "currency": "MXN"}]`.
Triggers conocidos: `event.checked_in` (payload trae `minutes_late`), `event.participation_cancelled` (payload trae `same_day_cancellation`).
Lista: lectura PostgREST de `rules`.

## 7. Reservations

| RPC | Firma | Devuelve |
|---|---|---|
| `request_resource_reservation(p_resource_id, p_context_actor_id, p_starts_at, p_ends_at, p_reserved_for_actor_id?, p_metadata?, p_client_id?)` | requiere `reservations.request` | `{reservation_id, conflicts_detected, reservation: {row}}` |
| `approve_reservation(p_reservation_id)` | requiere `reservations.manage`; EXCLUDE constraint si traslapa | `{reservation_id, status, no_op?}` |
| `confirm_reservation(p_reservation_id)` | | `{reservation_id, status, already_confirmed?}` |
| `cancel_reservation(p_reservation_id)` | requester o manage | `{reservation_id, status, no_op?}` |
| `detect_reservation_conflicts(p_resource_id)` | | `setof reservation_conflicts` |
| `resolve_reservation_conflict(p_conflict_id, p_winner_reservation_id)` | rechaza al perdedor, aprueba al ganador | `{conflict_id, winner, loser, no_op?}` |

Listas: lectura PostgREST de `resource_reservations` + `reservation_conflicts`.
`reservation.status` ∈ requested, approved, confirmed, rejected, cancelled, completed

## 8. Decisions

| RPC | Firma | Devuelve |
|---|---|---|
| `create_decision(p_context_actor_id, p_decision_type, p_title, p_description?, p_closes_at?, p_payload?, p_client_id?)` | requiere `decisions.create` | `{decision_id, decision: {row}}` |
| `vote_decision(p_decision_id, p_vote, p_option?)` | vote ∈ approve\|reject\|abstain; auto-finaliza con mayoría | `{decision_id, my_vote, my_option, status, tally: {approve, reject, members, option_tally?}}` |
| `close_decision(p_decision_id)` | cierre manual | `{decision_id, status, winning_option?, tally?, already_closed?}` |
| `execute_decision(p_decision_id, p_result?)` | requiere `decisions.execute`; status debe ser approved | `{decision_id, status, effects?, already_executed?}` |

Listas/votos: lectura PostgREST de `decisions` + `decision_votes`.
`decision_type` ∈ expense_approval, rule_change, member_admission, resource_purchase, reservation_dispute, generic

## 9. Money & Settlement

| RPC | Firma | Devuelve |
|---|---|---|
| `record_expense(p_context_actor_id, p_amount, p_currency, p_description, p_split_with?, p_event_id?, p_metadata?, p_client_id?, p_paid_by_actor_id?, p_split_method='equal', p_splits?, p_excluded_actor_ids?)` | requiere `money.record` (+ `money.record_for_others` si paga otro). Custom: `p_splits=[{actor_id, amount}]` debe sumar el total | `{transaction_id, share_per_person, split_method, obligations: [{obligation_id, debtor, amount}], idempotent_replay?}` |
| `record_fine(p_context_actor_id, p_debtor_actor_id, p_amount, p_currency, p_reason?)` | self: `money.record`; otros: + `members.manage` | `{obligation_id}` |
| `record_game_result(p_context_actor_id, p_event_id, p_game_name, p_winner_actor_id, p_loser_actor_id, p_amount, p_currency='MXN', p_client_id?)` | requiere `money.record` | `{transaction_id, obligation_id, idempotent_replay?}` |
| `generate_settlement_batch(p_context_actor_id, p_currency)` | requiere `money.settle`; neteo greedy min-cashflow de obligations abiertas | `{batch_id, items: [{from, to, amount}], obligations_netted}` · si todo netea a cero: `{batch_id: null, items: [], message, obligations_settled}` |
| `mark_settlement_paid(p_settlement_item_id)` | from_actor o `money.settle` | `{item_id, transaction_id, batch_finalized, obligations_closed, already_paid?}` |

Listas: lectura PostgREST de `obligations`, `settlement_batches`, `settlement_items`.
`obligation_type` ∈ iou, fine, sanction, expense_share, loan, contribution, dues, trip_share, game_debt, reservation_fee, other

## 10. Activity

| RPC | Firma | Devuelve |
|---|---|---|
| `list_activity(p_context_actor_id, p_limit=50, p_before?)` | miembro activo; cap 100 | `{context_actor_id, limit, activity: [{id, event_type, actor_id, subject_type, subject_id, payload, resource_id, decision_id, obligation_id, occurred_at}]}` |

Taxonomía `event_type`: `context.*`, `membership.*`, `invite.*`, `resource.*`, `right.*`,
`event.*`, `reservation.*`, `decision.*`, `rule.*`, `obligation.*`, `fine.*`, `expense.*`,
`split.*`, `game_result.*`, `settlement.*`, `document.*`. Eventos automáticos llevan
`payload.system = true`.

## 11. Permisos (catálogo)

`context.view/manage/invite`, `members.view/manage`, `resources.view/create/manage`,
`events.view/create/manage`, `reservations.view/request/manage`, `rules.view/manage`,
`decisions.view/create/vote/execute`, `money.view/record/settle` (+ `money.record_for_others`),
`documents.view/manage`.

Roles seed por contexto: `admin` (todo) y `member` (view de todo + `reservations.request`,
`decisions.create/vote`, `money.record`, `events.create`).

La UI gatea con `context_summary(...).my_permissions` — el backend re-valida siempre.

## 12. Tablas con lectura PostgREST directa (RLS)

`actors`, `actor_memberships`, `roles`, `role_assignments`, `role_permissions`,
`permission_catalog`, `resources`, `resource_rights`, `calendar_events`, `event_participants`,
`resource_reservations`, `reservation_conflicts`, `decisions`, `decision_votes`, `rules`,
`rule_evaluations`, `obligations`, `money_transactions`, `money_splits`, `settlement_batches`,
`settlement_items`, `documents`, `activity_events`, `context_invites`.

Visibilidad: miembro activo del contexto o actor referenciado directamente. Escritura: ninguna.
