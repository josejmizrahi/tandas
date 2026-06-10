# MVP2 — Contrato Backend ↔ iOS

**Fecha:** 2026-06-03 · **Última actualización:** 2026-06-11 (ver §14 para todo lo
posterior a `r2k`) · **Fuente:** migrations `mvp2_000`…`r9_g` (la definición final de cada
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
| `resource_detail(p_resource_id)` | requiere right activo o membership del owner | `{resource: {row}, resource_type, capabilities: [text], available_actions: [{action_key, label, section, enabled, reason, required_rights, required_capabilities}], why_visible: [text], metadata, rights: [{right_id, holder_actor_id, holder_display_name, right_kind, percent, scope, starts_at, ends_at}]}` |
| `grant_right(p_resource_id, p_holder_actor_id, p_right_kind, p_percent?, p_scope?, p_starts_at?, p_ends_at?, p_metadata?)` | OWN/SELL/TRANSFER/LIEN exigen OWN o `resources.manage` del owner | `{right_id}` |
| `revoke_right(p_right_id)` | | `void` |
| `update_resource(p_resource_id, …)` | | `{resource}` |
| `archive_resource(p_resource_id)` | | `{archived, already_archived?}` |
| `resource_type_catalog()` | catálogo global (R.2M) | `[{type_key, display_name, description, icon, expected_metadata, capabilities: [text]}]` |
| `resource_capabilities(p_resource_id)` | visibilidad rights-based | `{resource_id, resource_type, capabilities: [text]}` |
| `resource_can(p_resource_id, p_capability)` | | `boolean` |
| `resource_available_actions(p_resource_id, p_actor_id)` | R.2S-FIX: actor-aware (capability ∩ rights). 1-arg delega con `current_actor_id()` | `[{action_key, label, section, enabled, reason, required_rights, required_capabilities}]` |

`right_kind` ∈ OWN, USE, MANAGE, VIEW, SELL, TRANSFER, GOVERN, BENEFICIARY, LIEN, LEASE, APPROVE, AUDIT

### Tipos y capabilities (R.2M)

`resource_type` ya no es un CHECK hardcodeado: vive en `resource_type_catalog` (FK). Tipos seed:
property, house, vehicle, bank_account, cash_pool, contract, document, reservation, trip_booking,
game, equipment, membership_asset, security, digital_asset, trust_asset, other. Nuevos tipos se
agregan por configuración (INSERT al catálogo), sin migración de schema.

### R.2M-3 — Universal Capability System (doctrina final)

El comportamiento NUNCA se deriva de `resource_type`. Se deriva de:
`resource_type` **clasifica** · `capability` **habilita** comportamiento · `right` **autoriza**
actores · `available_action` **gobierna** la UX (el frontend renderiza desde `available_actions`).

Capabilities (15): reservable, monetary, documentable, beneficiary_supported, ownership_trackable,
transferable, approval_required, auditable, **maintainable** + las legacy (shareable, governable,
expirable, depreciable, sellable, rentable). La matriz tipo→capability define qué soporta cada tipo
(p. ej. bank_account/security/property **NO** reservable; security **sí** transferable).

`resource_action_catalog` mapea cada acción a `{required_capability, required_rights[], ui_section}`.
`resource_available_actions(resource_id, actor_id)` (R.2S-FIX, actor-aware canónico; el overload de
1 arg delega con `current_actor_id()`) devuelve las acciones donde `resource_can(capability)` **Y** el
actor posee uno de los rights requeridos (directos, vía contexto que administra, o VIEW por membresía),
en la **forma canónica** `{action_key, label, section, enabled, reason, required_rights,
required_capabilities}`. Secciones de UI: reservations, money, beneficiaries, ownership, documents,
approvals, maintenance, audit, rights.

`capability` ∈ reservable, monetary, transferable, shareable, governable, beneficiary_supported,
approval_required, expirable, depreciable, documentable, sellable, rentable, auditable,
ownership_trackable.

**La UI renderiza por capabilities, no por tipo**: `reservable` → sección Reservaciones,
`monetary` → Money, `documentable` → Documentos, `beneficiary_supported` → Beneficiarios.
El metadata esperado por tipo (`expected_metadata`) es documental — no se valida rígidamente.

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
| `request_resource_reservation(p_resource_id, p_context_actor_id, p_starts_at, p_ends_at, p_reserved_for_actor_id?, p_metadata?, p_client_id?)` | requiere right USE/MANAGE/OWN + capability `reservable` del tipo (R.2M) | `{reservation_id, conflicts_detected, reservation: {row}}` |
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
| `generate_settlement_batch(p_context_actor_id, p_currency)` | requiere `money.settle`; neteo greedy min-cashflow de obligations abiertas | `{batch_id, items: [{item_id, from, to, amount}], obligations_netted, idempotent_replay?}` |
| `mark_settlement_paid(p_settlement_item_id)` | from_actor o `money.settle` | `{item_id, transaction_id, batch_finalized, obligations_closed, already_paid?}` |

**Semántica R.2N (neteo vivo por novación):** al generar/recalcular un batch draft, las
obligations abiertas se *novan*: quedan `settled` (metadata `netted_into_batch`) y se
reemplazan por obligations `iou` netas 1:1 con los `settlement_items`. Cada pago cierra su
iou al instante (balance en tiempo real). Un trigger en `obligations` recalcula el batch
draft automáticamente cuando entran deudas nuevas; los items reemplazados quedan
`cancelled` (el frontend los filtra).

Listas: lectura PostgREST de `obligations`, `settlement_batches`, `settlement_items`.
`obligation_type` ∈ iou, fine, sanction, expense_share, loan, contribution, dues, trip_share, game_debt, reservation_fee, other

## 9b. Obligations universales (R.2R)

`obligations` es una primitiva universal: representa compromisos **monetarios y de acción**
sin tabla `task`. El eje lo define `obligation_kind`:

`obligation_kind` ∈ money (default), action, approval, delivery, attendance, document, reservation, custom

- **money** → `amount`/`currency`, se liquida vía settlement (`status: open → settled`).
- **resto (acción)** → `title`/`description`/`due_at`, sin `amount`; se cumple con
  `complete_obligation` (`status: open → completed`). Quedan fuera del neteo por diseño
  (`amount`/`currency` null).

`status` ∈ open, accepted, in_progress, completed, expired, settled, cancelled, forgiven, disputed.
Campos de cumplimiento: `completed_at`, `completed_by_actor_id`, `completion_notes`, `completion_metadata`.

| RPC | Firma | Devuelve |
|---|---|---|
| `create_action_obligation(p_context_actor_id, p_debtor_actor_id, p_title, p_kind='action', p_description?, p_due_at?, p_creditor_actor_id?, p_source_event_id?, p_source_reservation_id?, p_source_decision_id?, p_metadata?, p_client_id?)` | miembro del contexto; asignar a otro requiere `members.manage` | `{obligation_id, kind, status}` |
| `complete_obligation(p_obligation_id, p_completion_notes?, p_completion_metadata?)` | responsable (debtor), acreedor/verificador (creditor) o `members.manage`. Las de dinero NO se completan | `{obligation_id, status, completed_by, completed_at, already_completed?}` |
| `obligation_detail(p_obligation_id)` | debtor, creditor o miembro del contexto | `{id, kind, obligation_type, status, title, description, amount, currency, due_at, debtor_actor_id, creditor_actor_id, completed_at, completed_by_actor_id, completion_notes, source_*, metadata, created_at}` |
| `why_obligation_exists(p_obligation_id)` | debtor, creditor o miembro del contexto | `{obligation_id, kind, source: rule\|decision\|event\|reservation\|manual, reason, source_rule_id, source_decision_id, source_event_id, source_reservation_id, rule_title, metadata}` |

Las **consecuencias de reglas** pueden crear obligations de acción además de multas:
`consequences: [{"type":"create_obligation", "kind":"action", "title":"Traer botella de vino", "description"?, "due_at"?}]`.
Sin `kind` (o `type:"fine"`) → multa monetaria (compat).

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
`permission_catalog`, `resources`, `resource_rights`, `resource_type_catalog`,
`resource_capabilities_catalog`, `resource_type_capabilities`,
`actor_capabilities_catalog`, `actor_type_capabilities`, `calendar_events`, `event_participants`,
`resource_reservations`, `reservation_conflicts`, `decisions`, `decision_votes`, `decision_options`, `rules`,
`rule_evaluations`, `obligations`, `money_transactions`, `money_splits`, `settlement_batches`,
`settlement_items`, `documents`, `activity_events`, `activity_event_catalog`, `context_invites`.

Visibilidad: miembro activo del contexto o actor referenciado directamente. Escritura: ninguna.
Los catálogos (`*_catalog`, `*_type_capabilities`) son globales, lectura para `authenticated`.

## 13. Universal Behavior Models (R.2S)

El frontend NO decide comportamiento por `resource_type` / `actor_subtype` / `decision_type` /
`obligation_kind` / `reservation_status`. Consume **capabilities**, **available_actions** y el
**explanation engine**. El backend calcula; el frontend renderiza.

### 13.1 Actor capabilities (R.2S.2)

Espejo de resource capabilities, keyed por `actor_subtype`. Catálogo (12): `can_have_members`,
`can_hold_assets`, `can_hold_money`, `can_issue_decisions`, `can_receive_contributions`,
`can_have_beneficiaries`, `can_have_shareholders`, `can_have_trustees`, `can_receive_obligations`,
`can_issue_obligations`, `can_govern_resources`, `can_own_resources`.

| RPC | Firma | Devuelve |
|---|---|---|
| `actor_can(p_actor_id, p_capability)` | authenticated | `boolean` (catálogo por subtype + overrides) |
| `actor_capabilities(p_actor_id)` | authenticated | `{actor_id, actor_kind, actor_subtype, capabilities: [text]}` |
| `actor_capabilities_catalog()` | authenticated | `{capabilities: [{capability_key, display_name, description}], subtypes: [{actor_subtype, capabilities: [text]}]}` |

Override explícito por actor: `actors.metadata.capability_overrides = {"can_have_shareholders": true}`
(habilita) o `false` (deshabilita) sin tocar el catálogo. Ej.: una person no tiene `can_have_shareholders`
salvo override; un trust sí tiene `can_have_beneficiaries`/`can_have_trustees`.

### 13.2 Available actions (R.2S.3 + R.2S.9 + R.2S-FIX)

**Forma canónica única** (7 campos, uniforme en todos los dominios):

```json
{"action_key": "reserve_resource", "label": "Reservar", "section": "reservations",
 "enabled": true, "reason": "El recurso soporta reservable y el actor tiene el derecho requerido",
 "required_rights": ["USE"], "required_capabilities": ["reservable"]}
```

**R.2S-FIX** reconcilia R.2M-3 (recursos) y R.2S.9 en un solo contrato: las acciones son **actor-aware**
(`resource_available_actions(resource_id, actor_id)`, con overload de 1 arg que delega a
`current_actor_id()`). Una acción **aparece** solo si la capability/estado la habilita **y** el actor tiene
los rights requeridos; `enabled` + `reason` mantienen la forma uniforme. Cubierto en: `resource_detail`,
`obligation_detail`, `decision_detail` (nuevo), `reservation_detail` (nuevo).

- **resource** (catálogo `resource_action_catalog`, R.2M-3): `view_reservations`/`reserve_resource`/
  `manage_reservations` (reservable), `view_transactions`/`record_expense`/`record_contribution`/
  `generate_settlement` (monetary), `view_beneficiaries`/`grant_beneficiary` (beneficiary_supported),
  `view_ownership`/`transfer_interest` (ownership_trackable/transferable), `view_document`/`review_document`
  (documentable), `approve_document` (approval_required), `view_maintenance`/`log_maintenance`
  (maintainable), `view_audit` (auditable), `grant_right` (universal).
- **obligation**: `pay` (money + activa + deudor), `mark_completed` (acción), `dispute`, `forgive`, `cancel`.
  No muestra `pay` en `settled`.
- **decision**: `vote`/`change_vote`, `close_decision`, `cancel_decision` (abiertas), `execute_decision`
  (cerrada). No muestra `vote` en ejecutada.
- **reservation**: `approve`/`reject` (requested), `confirm` (approved), `cancel`, `resolve_conflict`.

| RPC nuevo | Firma | Devuelve |
|---|---|---|
| `decision_detail(p_decision_id)` | miembro del contexto | `{id, decision_type, voting_model, title, status, payload, result, options: [{id, option_key, title, votes}], votes_count, available_actions, …}` |
| `reservation_detail(p_reservation_id)` | miembro del contexto o quien ve el recurso | `{id, resource_id, status, starts_at, ends_at, requested_by_actor_id, reserved_for_actor_id, available_actions, …}` |

### 13.3 Split models (R.2S.6)

`record_expense(..., p_split_method, p_splits, p_excluded_actor_ids)` —
`split_method` ∈ `equal`, `custom`, `custom_amount`, `percentage`, `shares`, `consumption`, (+ `excluded`).
`percentage` (`[{actor_id, percent}]`, suma 100) y `shares` (`[{actor_id, shares}]`) se normalizan a montos
exactos (el último participante absorbe el remanente de redondeo). Validaciones: suma = monto, sin actores
duplicados, currency consistente, el pagador no genera obligación contra sí mismo.

### 13.4 Rule targeting (R.2S.5)

`rules.target_scope` ∈ `context, event_type, event, resource_type, resource, decision, reservation,
membership, money_transaction, obligation, custom`; `rules.target_filter` jsonb `{key: value}` que debe
coincidir con el payload del trigger. La **misma infraestructura** soporta reglas de cualquier dominio.

| RPC | Firma | Notas |
|---|---|---|
| `create_rule(p_context_actor_id, p_title, p_trigger_event_type, p_condition_tree, p_consequences, p_target_scope, p_target_filter={}, p_body?, p_rule_type='automation', p_severity=1)` | `rules.manage` | overload con scope/filter |

Triggers cableados además de `event.*`: `record_expense` → `money.expense_recorded`
(`payload.amount/currency`); `cancel_reservation` → `reservation.cancelled`
(`payload.resource_id/hours_before`).

### 13.5 Reservation outcomes (R.2S.7)

`resolve_reservation_conflict(p_conflict_id, p_resolution_model, p_winner_reservation_id?, p_metadata?)` —
`resolution_model` ∈ `priority_based`, `admin_override`, `winner`, `lottery`, `waitlisted`, `split_dates`,
`partial_approval`, `requires_decision`. El overload de 2 args `(conflict, winner)` sigue vigente.
`requires_decision` abre una decisión `reservation_dispute`; la decision option ganadora resuelve el
conflicto al ejecutar (`execute_decision`). `status` de reservación añade `waitlisted`.

### 13.6 Activity catalog (R.2S.8)

`activity_event_catalog(event_type, domain, description, expected_subject_type, is_system_generated)`
cataloga la taxonomía canónica. `_emit_activity` marca `payload.uncatalogued=true` cualquier tipo fuera del
catálogo (salvo `custom.*`).

| RPC | Devuelve |
|---|---|
| `activity_event_catalog()` | `[{event_type, domain, description, expected_subject_type, is_system_generated}]` |

### 13.7 Explanation engine (R.2S.10)

| RPC | Devuelve |
|---|---|
| `why_can_view_resource(p_actor_id, p_resource_id)` | `{can_view, reasons: [text]}` |
| `why_can_reserve(p_actor_id, p_resource_id)` | `{can_reserve, required_capability, reasons: [text]}` |
| `why_reservation_won(p_conflict_id)` | `{winner_reservation_id, winner_actor_id, reasons: [text]}` |
| `why_decision_result(p_decision_id)` | `{status, voting_model, tally: {approve, reject, abstain}, option_tally, result, reasons: [text]}` |
| `why_obligation_exists(p_obligation_id)` | ver §9b |

## 14. Inventario post-r2k (R.3A → R.9) — actualizado 2026-06-11

Las secciones 1–13 documentan hasta `r2k`. Todo lo siguiente shipped después;
la fuente de verdad de cada shape es la migración indicada (la definición más
reciente gana). Esta sección es el índice para que ningún dev/agente vuelva a
generar código contra un contrato viejo.

### 14.1 Jerarquía de contextos (R.2U) y similitud (R.2V)
`create_child_context` · `link_child_context` · `unlink_child_context` ·
`context_tree` · `context_children` · `context_parents` · `context_ancestors` ·
`context_descendants` (`r2u_1_mutations`) · `context_similarity` ·
`resource_similarity` · `duplicate_candidates` · merge RPCs (`r2v_*`).

### 14.2 Relaciones, suscripciones y trust (R.3A)
`subscriptions` + catálogo, `trust_edges`, `activity_feed` personal
(`r3a_2`…`r3a_4`). Lectura: `MyActivityFeedView` (tab Actividad).

### 14.3 Descriptores y dispatcher (R.5A)
`resource_detail_descriptor(p_resource_id)` (`r5a_b6`, enriquecido `r5a_b6_1`) ·
`context_detail_descriptor(p_context_actor_id)` (`r5a_b7`, enriquecido `r5a_b7_1`) ·
`list_resource_actions` / `execute_resource_action` (`r5a_b8`). Catálogos de
clases/subtipos/secciones/widgets/forms en `r5a_b0`…`r5a_b5b`.

### 14.4 Notificaciones (R.4D), ledger (R.4C), templates de decisión (R.4B)
- `notifications` + `notification_deliveries` + RPCs inbox (`r4d`).
- `ledger_entries` (sombra doble-entrada; mapeos completos desde `r9_d`) +
  `actor_money_balances`.
- `decision_templates` + dispatch polimórfico en `execute_decision` (`r4b`).

### 14.5 Gobernanza (R.5 + R.7)
`governance_action_catalog` (acciones canónicas + aliases) · `governance_actions` ·
`governance_policies` · `request_governance_action` · `execute_governance_action`
(`r7_a`…`r7_c`) · `member_available_actions` con governance mode (`r7_d`) ·
attention de gobernanza en inbox (`r7_g`). RPCs governance-aware:
`set_membership_state` (`r7_x_1`) · `transfer_resource_ownership` (`r7_x_2`) ·
`archive_rule` (`r7_x_3`) · `forgive_obligation` (`r7_x_4`).

### 14.6 Rule engine 2.0 (R.6)
Idempotencia + `rule_attention_items` sink (`r6_a`) · auto-dispatch desde
activity (`r6_b`) · detectores pg_cron (`r6_c`) · validador DSL de gramática
cerrada (`r6_d`). Desde `r9_e`: las consecuencias fine/obligation se saltan
para sujetos sin membership activa.

### 14.7 Placeholders (R.5W)
`create_placeholder_person` · `find_placeholder_matches_for_me` ·
`claim_placeholder_actor` (emite `membership.placeholder_claimed` con counts
de reasignación desde `r9_a`).

### 14.8 Eventos — roster, +N, invitados, host confirm (R.5Z)
`add_event_participants` · `remove_event_participants` ·
`set_event_participant_plus_one` · `set_event_participant_plus_count`
(`20260610170000/180000`) · `add_event_guest` · `remove_event_guest` ·
`list_event_guests` (`20260610190000`) · `host_confirm_participant`
(`20260610200000`). Todos emiten activity desde `r9_a`.

### 14.9 Settlement handshake + apelación (R.5Z)
`mark_settlement_paid` (deudor → `pending_confirmation`) ·
`confirm_settlement_paid` / `reject_settlement_paid` (acreedor) ·
`appeal_settlement_paid` (`20260610220000/230000`). `dismiss_attention_item`
(`20260609220000`). Estados de `settlement_items`: pending →
pending_confirmation → paid | cancelled | disputed.

### 14.10 Money R.9 (idempotencia + split ponderado server-side)
- `record_fine(..., p_client_id)` y `record_game_result(..., p_client_id)`
  idempotentes; ahora anclan `money_transaction` (`r9_b`).
- `record_expense(..., p_source_event_id, p_split_basis)` con basis
  `'equal'|'explicit'|'event_weights'`; con `event_weights` el backend calcula
  pesos (1 + plus_count + count_share de guests del participante) — iOS ya NO
  calcula pesos (`r9_c`).
- `preview_event_split(p_event_id, p_amount, p_currency)` →
  `{event_id, amount, currency, total_weight, splits:[{actor_id, weight, amount}]}`.
- Gate `expense.large`: solo con policy explícita `large_expense_requires_vote`
  del contexto (threshold de catálogo o 5000).

### 14.11 Pools (R.8 completo)
- `pool_accounts` + `pool_basis_entries`; pool = actor collective
  subtype='pool' del contexto padre (`r8_a`).
- `create_pool` · `contribute_to_pool` · `list_context_pools` ·
  `pool_account_detail` (`r8_b`).
- `preview_pool_resolution(p_pool_account_id)` ·
  `resolve_pool(p_pool_account_id, p_resolution, p_client_id)` (`r8_c`):
  `winner_takes_all` (payout pool→ganador; stakes cristalizan) y
  `equity_target` (shares proporcionales en metadata). Gobernanza:
  `pool.resolve` en catálogo (PULL gate). Activity: `pool.resolved`/`pool.payout`.
- Obligations `pending_pool` quedan fuera del neteo de settlement.

### 14.12 Shell / atención (F.NAV)
`attention_inbox()` — única lectura agregadora (votos, conflictos,
invitaciones, rule_attention_items del caller, governance pending) ·
`list_recent_contexts` · `mark_context_visited` · preferencias de contexto
(`f_nav_0`). `remove_member(..., p_force)` bloquea con
`member_has_open_obligations` si el miembro tiene deudas abiertas (`r9_e`).
