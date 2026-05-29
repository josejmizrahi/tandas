# PrimitivesArchitecture — Especificación técnica canónica

> Documento técnico implementable. Fuente única para el contrato
> de conexiones entre primitivas de Ruul. NO sustituye
> `GroupPrimitives.md` (doctrina), sino que lo traduce a SQL/RPC/iOS.
>
> Estado backend al 2026-05-29: 338+ migrations, `v1.0.0-rc` cortado,
> **V2-G3 EPIC CERRADO COMPLETO** (G3.1→G3.5 + polish `6bb56c78`).
> 6 migs G3 (`060000..060500` + `20260529000000`). 427/427 tests
> RuulCore verdes. **Catálogo: 20 atoms vivos** (8 triggers + 6
> conditions + 6 consequences). 7 callsites cableados. **Puente
> engine→votos vivo** vía `consequence.start_vote` (frontera doctrinal:
> cambiar autoridad = voto; aplicar autoridad existente = engine).
> Restante V2: G8 (banner + "¿por qué pasó esto?" sheet) + G4
> (sanction ↔ money deep).
>
> Naming conventions duras:
> - Tablas dominio = `group_*` (multi-tenant) excepto `profiles`.
> - Tablas atom = nombre directo (`ledger_entries`, `vote_casts`,
>   `rsvp_actions`, `bookings`, `check_in_actions`, `system_events`).
> - RPCs canónicas = verbo + objeto (`record_expense`, `issue_sanction`,
>   `publish_rule_version`).
> - Reads helper = `group_<plural>(p_group_id)` SECURITY DEFINER.
> - Events = `<noun>.<verb>` (`expense.recorded`, `rule.published`).

---

# FASE 1 — AUDITORÍA DE `GroupPrimitives.md`

## 1.1 Inventario primitivas declaradas (25)

| # | Primitiva (doctrina) | Mapping canónico actual | Estado backend |
|---|---|---|---|
| 1 | Miembros | `profiles` + `group_memberships` | ✅ live |
| 2 | Membresía/Límite | `group_memberships.state` + `group_invites` + `group_membership_boundary` view | ✅ live |
| 3 | Propósito | `group_purposes (kind, body)` | ✅ live |
| 4 | Reglas/Normas | `group_rules` + `group_rule_versions` + `rule_shapes_catalog` | 🟡 schema live, engine sync hook off |
| 5 | Roles | `group_roles` + jsonb `groups.roles` | ✅ live |
| 6 | Poder/Autoridad | `group_permissions` (direct) + `group_mandates` + `group_role_permissions` | ✅ live |
| 7 | Comunicación | — | ❌ deferred (post-V2) |
| 8 | Recursos | `group_resources` + subtipos (`group_funds`, `group_assets`, `group_spaces`, `group_documents`) | ✅ envelope + 4 subtipos |
| 9 | Contribuciones | `ledger_entries (kind='contribution')` + `group_contributions` view | ✅ live |
| 10 | Incentivos | — | ❌ deferred (no entity) |
| 11 | Sanciones | `group_sanctions` + `ledger_entries (kind='sanction_*')` | ✅ live |
| 12 | Confianza/Reputación | `group_reputation_events` (append-only) | ✅ live (sin score) |
| 13 | Memoria/Registro | `system_events` + `group_events` (proyección) | ✅ live |
| 14 | Conflictos | `group_disputes` + `group_dispute_events` | ✅ live |
| 15 | Entrada/Salida | `group_invites` + `accept_invite` + `leave_group` + `set_membership_state` | ✅ live |
| 16 | Decisiones | `group_decisions` + `group_votes` + `vote_casts` (atom) + `group_decision_rules` | ✅ live (8 methods + 11 types) |
| 17 | Permisos | `group_permissions` + `group_role_permissions` + `assert_permission()` | ✅ live |
| 18 | Propiedad | `group_resources.owner_member_id` + `group_resource_ownership_events` | ✅ live |
| 19 | Contabilidad | `ledger_entries` (atom) + `member_balance_in_group` view + `fund_balance_view` | ✅ live |
| 20 | Cultura | `group_cultural_norms` | ✅ live |
| 21 | Ritual | `group_rituals` | ✅ live |
| 22 | Legitimidad | `group_decisions.legitimacy_source` enum (10 sources) | ✅ live |
| 23 | Representación | `group_mandates` + `mandate_id` en money RPCs | ✅ live |
| 24 | Cuidado/Mantenimiento | — | ❌ deferred (señal, no entidad) |
| 25 | Disolución | `group_dissolutions` + `propose_dissolution` + `finalize_dissolution` | ✅ live |

## 1.2 Diagnóstico por punto (1-16 del brief)

### (1) Primitivas ya definidas
22/25 con entidad propia. 3 sin entidad (Comunicación, Incentivos, Cuidado) — son señales emergentes, no objetos. Decisión: NO crear tabla para ellas. Comunicación se materializa por `notifications_outbox` + canal externo. Incentivos derivan de Reputación + Sanciones. Cuidado deriva de `group_events.actor_id` agregado.

### (2) Relaciones ya existentes
Todas las FKs declaradas usan `group_id` como tenant + `member_id`/`actor_id` como autor. Las relaciones polimórficas (votos, sanciones, decisiones) van vía `reference_kind + reference_id` jsonb-tagged o columnas discriminantes. Catálogo polimórfico ya estabilizado en `group_decisions.decision_type` + `vote_casts.vote_id` + `group_sanctions.target_kind`.

### (3) Inconsistencias detectadas
- **`group_rule_versions.body` (text) vs `shape` (jsonb)** coexisten pero el catálogo `rule_shapes_catalog` y `RuleShape.swift` ya empujan a la versión estructurada. Body queda como display, shape como ejecutable.
- **`rules` (legacy 00001) vs `group_rules` (canonical)** — la tabla `rules` todavía existe por compatibilidad con primer engine. Decisión: deprecar `rules` post-V2-G3. No escribir más en ella.
- **`fines` vs `group_sanctions`** — `fines` (00001) sigue viva pero `group_sanctions` la suplantó. Same deprecation path.
- **`events` (00001) vs `group_events`** — `events` es legacy de calendario; `group_events` es event sourcing canónico. Renombrar `events` → `group_events_legacy_calendar` post-mig.

### (4) Duplicados
- `group_decisions` + `group_votes` parecen duplicar concepto. NO lo son: `group_decisions` es el *proposal envelope* (puede o no requerir voto). `group_votes` es el *vote instance* (1:1 con decision si la decision requiere voto). Mantener separados.
- `group_contributions` view + `ledger_entries(kind='contribution')` — view es proyección, atom es la fuente. OK.

### (5) Primitivas huérfanas
- **Cuidado (#24)** sin entidad. Diferir.
- **Comunicación (#7)** sin entidad propia más allá de outbox. Diferir.
- **Incentivos (#10)** sin entidad. Diferir; emergerá como projection sobre Reputación.

### (6) Primitivas sobrecargadas
- **`group_rules`** acumula: rule text, rule engine version, rule shape, rule status, scope. ✅ ya separado en `group_rules` (header mutable) + `group_rule_versions` (snapshots inmutables) + `rule_shapes_catalog` (vocabulary).
- **`group_resources`** es polimórfica (envelope-only). Subtipos en tablas dedicadas. Diseño correcto.
- **`group_decisions`** carga 11 `decision_type` + 8 `vote_method` + 10 `legitimacy_source`. Bordes ya separados via handler-per-type. Mantener.

### (7) ¿Qué ya implementado vs conceptual?
Implementado (live en dev `wyvkqveienzixinonhum`):
- Identity, Membership, Boundary, Purpose, Rules (text+shape), Roles, Permissions, Mandates, Resources (envelope+4 subtipos), Money (Ledger + Funds + Pool + Settlements), Sanctions (issue/pay/void/appeal), Reputation, Cultural Norms, Rituals, Decisions+Votes+Casts, Disputes, Dissolution, Mempria (`system_events` + `group_events`), Notifications outbox.

Conceptual (sin código):
- Comunicación (#7), Incentivos (#10), Cuidado (#24).
- Workflows multi-step (futuro).
- AI agents (futuro).
- Subgrupos / federation.

🟡 Schema sí, comportamiento parcial:
- Rule engine SYNC hook (V2-G3.2 pendiente).
- Dispatcher real de consecuencias (V2-G3.4 pendiente).
- Rule evaluations replay (V2-G3.3 parcial).

### (8) Naming inconsistencies
- `actor_id` vs `created_by` vs `acted_by_member_id` — usado intercambiable. **Doctrina**: `actor_id = auth.uid()` (el user autenticado), `member_id = group_memberships.id` (el party del grupo). En money: `recorded_by_member_id` (RBAC) ≠ `paid_by_member_id` (factual) ≠ `to_member_id` (receptor). Auditar y normalizar.
- `kind` vs `type` — predominante `kind`. **Doctrina forward**: `kind` para discriminadores polimórficos (`ledger_entries.kind`, `group_sanctions.kind`), `type` solo cuando hay precedente externo (e.g. `event_type` en streams).
- `event_type` vs `event_kind` — `event_type` en eventos serializados (system_events, group_events, payloads), `event_kind` no se usa. OK.
- `is_active` vs `active` vs `status` — coexisten. **Doctrina forward**: `status` enum > boolean. Migrar `is_active` boolean → `status text` en V3 cleanup.
- `created_by` vs `recorded_by` — para writes que registran un hecho ajeno, usar `recorded_by`. Para writes propios, `created_by`. Money ya lo cumple.

### (9) Dependencias circulares peligrosas
- **Rule → Sanction → Ledger → Rule** (potencial loop si una sanción dispara una regla que dispara otra sanción). Mitigado: recursion guard `ruul.rule_eval_depth` MAX 5 (V2-G3.3).
- **Vote → Decision → Rule (rule_change handler) → Rule version → ...** — finalize_vote llama outcome handler que muta rule; nuevo `rule.published` no debería re-disparar vote. Mitigado por: outcome handlers son sync inline pero no emiten eventos que disparen vote engine (vote engine NO escucha `rule.*` events).
- **Mandate → Money RPC → Mandate validation** — `record_expense` con `p_mandate_id` valida mandate scope; mandate no se muta. No circular.

### (10) Problemas de escalabilidad
- `system_events` append-only sin particionado. Riesgo si > 100M rows. **Acción V3**: particionar por `(group_id, created_at_month)`.
- `ledger_entries` igual. Particionar por `(group_id, created_at_month)`.
- `rule_evaluations` puede explotar (N rules × M events). Limitar retención: > 90 días → archivar. **Mitigation**: índice `(group_id, evaluated_at DESC)` + soft archive después de N días.
- `notifications_outbox` ya tiene cron de drain. OK si TTL configurado.

### (11) Problemas RLS/authority
- **`assert_permission(p_group_id, p_permission, p_actor, p_mandate)`** centraliza autoridad. Riesgo: ALGUNAS RPCs todavía hacen permission check inline (no via assert). Auditar lista en V2-G3.0.
- **Mandate precedence** — `mandate_id != null` SIEMPRE wins. Si mandate inválido → error, NUNCA fallback a `direct_permission`. Esto está locked.
- **`SECURITY DEFINER` functions** — todas escriben con `set_config('request.jwt.claims', ...)` para que RLS interno funcione. Auditar no haya leak de bypass.
- **`profiles` RLS** — debe permitir SELF read/update + `group_members_of_my_groups` JOIN. Verificar policy para no exponer phone/email cross-tenant.
- **Append-only atoms** — todos tienen BEFORE UPDATE/DELETE trigger que raise EXCEPTION (excepto `system_events.processed_at` actualizado por cron). OK.

### (12) Entidades append-only requeridas
Ya son append-only (atoms con guard):
- `system_events` (partial: `processed_at` only)
- `ledger_entries`
- `rsvp_actions`
- `check_in_actions`
- `vote_casts`
- `bookings`
- `user_actions` (partial)
- `group_rule_versions` (lifecycle: status mutable)
- `group_dispute_events`
- `group_reputation_events`

Faltan guards (decisión pendiente):
- `group_rule_evaluations` — debe ser append-only. ALTER añadir guard en V2-G3.3.
- `notifications_outbox` — `dispatched_at` mutable (cron); resto inmutable. Añadir partial guard.
- `group_decisions` — debe ser append-only post-finalization. Guard: si `status = 'closed'` → no UPDATE.

### (13) Entidades que requieren versionado
- `group_rules` → `group_rule_versions` ✅ ya
- `groups` (governance jsonb cambia) → `group_governance_versions` ❌ falta. **Riesgo**: cambia quórum sin audit. **Acción V3**: append `group_governance_versions(group_id, snapshot, effective_from, created_by)`.
- `group_roles` (permission set cambia) → no versionado. **Acción V3**: append `group_role_versions`.
- `templates.config` — versionado por nombre (`'dinner_recurring_v1'`) en mig. OK.

### (14) Entidades immutable
- Subset de append-only que NO permite mutar ningún campo: `vote_casts`, `ledger_entries`, `rsvp_actions`, `check_in_actions`, `bookings`, `group_reputation_events`, `group_dispute_events`.
- `system_events.processed_at` mutable solo por cron (`null → ts`).

### (15) Entidades que deberían separarse
- **`groups.governance` (jsonb)** acumula quórum + thresholds + voting defaults + emergency flags. Considerar extraer a `group_governance_settings(group_id PK, ...)` versionada. **Riesgo bajo** hasta que governance crezca > 20 keys. Mantener jsonb por ahora; documentar shape.
- **`groups.roles` (jsonb)** ya migrado a `group_roles` table en mig 00063. ✅
- **`group_decisions.payload` (jsonb)** carga 11 decision_type variants. Separar en `group_decision_payloads_<type>` no escala. **Mantener** jsonb con shape validation por type.

### (16) Entidades sobre-acopladas a separar
- **`group_resources` + subtipos** ya separados correctamente (envelope-only + 4 subtype tables).
- **`ledger_entries.metadata` (jsonb)** carga `mandate_id, source_resource_id, paid_by_member_id, sanction_id, settlement_pair_id, ...`. Considerar promover a columnas: `mandate_id`, `source_resource_id`, `paid_by_member_id` ya son columnas. Resto jsonb. ✅

## 1.3 Veredicto auditoría

| Categoría | Status |
|---|---|
| Primitivas faltantes (críticas) | 0 — todas las 22 con entidad están vivas. |
| Primitivas faltantes (deferred) | 3 — Comunicación, Incentivos, Cuidado. OK diferir. |
| Mal separadas | 0 — `group_decisions` vs `group_votes` está correcto. |
| Deben fusionarse | 2 deprecaciones: `rules` → `group_rules`, `fines` → `group_sanctions`, `events` → `group_events`. |
| Sobrecargadas | 0 críticas; `groups.governance jsonb` vigilar growth. |
| Deben dividirse | 0 críticas. |
| NO implementar todavía | Comunicación, Incentivos, Cuidado, Workflows multi-step, AI agents, Subgrupos. |
| Críticas para core | Identity, Membership, Rules+Versions+Shapes, Ledger, Sanctions, Decisions+Votes, System Events, Mandates, Permissions. |

**Decisión global**: el modelo está en buena forma. La deuda principal es **rule engine activation** (V2-G3) + **deprecación de tablas 00001 legacy** + **3 partial atom guards faltantes**.

---

# A) ARQUITECTURA POR CAPAS

Doce capas. Cada primitiva del doctrina vive en exactamente UNA capa primaria; muchas tienen referencias cross-layer.

## A.1 Identity Layer

**Propósito**: representar personas globales independientes de grupos.

| Item | Detalle |
|---|---|
| Tablas | `auth.users` (Supabase native), `profiles` |
| RPCs | `my_profile()`, `update_my_profile(...)` |
| Triggers | `on_auth_user_created` → mirror to `profiles`, `on_auth_user_phone_sync` → update `profiles.phone` |
| Ownership | self (`auth.uid() = profiles.id`) |
| Invariantes | `profiles.id = auth.users.id`. Phone único cuando no null. |
| Boundaries | NO tiene `group_id`. Cross-tenant. |
| Modifica | `profiles.display_name`, `avatar_url`, `phone` (via auth sync), `bio`. |
| NO modifica | `id`, `created_at`, ningún campo de otra capa. |
| Riesgos | RLS leak de phone/email a usuarios no-mismo-grupo. Mitigación: policy `profiles_select_self_or_group_member`. |

Doctrina: **ONE identity, MANY contexts**. Profile NO carga rol ni reputación; eso vive en Group layer.

## A.2 Group Layer

**Propósito**: representar la comunidad tenant-root.

| Item | Detalle |
|---|---|
| Tablas | `groups`, `group_invites`, `templates` |
| RPCs | `create_group(...)`, `create_group_with_admin`, `list_my_groups()`, `group_summary(p_group_id)` |
| Ownership | `groups.created_by`, primer admin via `group_memberships`. |
| Invariantes | `slug` único global. `dissolved_at` set → no writes a tablas group-scoped. |
| Append-only? | NO. Mutable. |
| Versionado? | `groups.governance` debería versionarse (V3). |
| Modifica | `name`, `description`, `governance jsonb`, `active_modules text[]`, `base_template`. |
| NO modifica | `id`, `slug` (post-creation), `created_by`. |
| Riesgos | Cambio de governance retroactivo sobre votes en curso. Mitigación: snapshot quorum en `group_decisions` al crearla. |

## A.3 Membership Layer

**Propósito**: representar pertenencia + boundary + lifecycle.

| Item | Detalle |
|---|---|
| Tablas | `group_memberships`, `group_invites`, `group_membership_states_log` (proyección) |
| Views | `group_membership_boundary` (UNION memberships + pending invites) |
| RPCs | `invite_member(...)`, `accept_invite(...)`, `request_membership(...)`, `set_membership_state(...)`, `leave_group(...)`, `remove_member(...)` |
| Estados | `pending|provisional|active|suspended|inactive|expelled|left` |
| Ownership | `group_memberships.user_id = profiles.id`; `group_memberships.id` = `member_id` (party identity dentro del grupo). |
| Invariantes | Un `(group_id, user_id)` activo a la vez. State transitions append a `group_membership_states_log`. |
| Append-only? | No (lifecycle), pero transitions log SÍ. |
| Modifica | `state`, `provisional_until`, `roles` (denorm). |
| NO modifica | `group_id`, `user_id`, `joined_at`. |
| Riesgos | Member sale → balance pendiente. Mitigación: `leave_group` bloquea si `member_balance_in_group != 0` o emite `obligation_pending` para reconciliación post-exit. |

## A.4 Authority Layer

**Propósito**: poder + permisos + delegación.

| Item | Detalle |
|---|---|
| Tablas | `group_roles`, `group_role_permissions`, `group_permissions` (per-member direct grants), `group_mandates` |
| Catálogo | `permissions_catalog` (text PK, immutable seed) |
| RPCs | `assert_permission(p_group, p_perm, p_actor, p_mandate)`, `has_permission(...)`, `grant_role(...)`, `revoke_role(...)`, `grant_permission(...)`, `create_mandate(...)`, `revoke_mandate(...)` |
| Authority precedence | `mandate > self_party > direct_permission` (locked) |
| Invariantes | `assert_permission` raises canonical error con regex `permission_denied:<perm>`. Mandate scope NO se infiere; debe ser explícito (`scope_permission_keys text[]`). |
| Append-only? | `group_mandates` lifecycle (status) + `group_role_grants_log`. |
| Modifica | `group_roles.permission_keys`, `group_mandates.status`. |
| NO modifica | `group_mandates.granter_id`, `granted_to_member_id`, `scope_permission_keys`, `created_at`. |
| Riesgos | Mandate expirado usado en RPC → silencioso bypass. Mitigación: `assert_permission` valida `revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())`. |

## A.5 Rules Layer

**Propósito**: vocabulary + rule headers + rule snapshots + evaluations.

| Item | Detalle |
|---|---|
| Tablas | `rule_shapes_catalog` (vocab), `group_rules` (header mutable), `group_rule_versions` (snapshot append-only), `group_rule_evaluations` (audit append-only), `group_cultural_norms` (proposed-norm → rule promotion path) |
| RPCs | `list_rule_shapes()`, `validate_rule_shape(p_shape)`, `create_text_rule(...)`, `create_engine_rule(...)`, `publish_rule_version(...)`, `archive_rule(...)`, `promote_norm_to_rule(...)`, `evaluate_rules_for_event(p_event_id, p_mode)`, `simulate_rule_eval(p_version_id, p_fake_event)` |
| Atoms | `group_rule_versions`, `group_rule_evaluations`. |
| Versionado | YES — nueva row por publish. UNIQUE active version per rule. |
| Invariantes | `group_rule_versions.shape` valida contra `rule_shapes_catalog`. `evaluation.idempotency_key` UNIQUE para retry-safety. |
| Modifica | `group_rules.status`, `group_rule_versions.status` (active|superseded), `group_rule_versions.effective_until`. |
| NO modifica | `body`, `shape`, `compiled`, `created_by`, `created_at`. |
| Riesgos | Loop de evaluaciones (rule A → rule B → rule A). Mitigación: `rule_eval_depth` max 5 + cycle detection (mismo rule_version_id en path). |

## A.6 Event Layer (event sourcing)

**Propósito**: stream append-only de hechos del grupo.

| Item | Detalle |
|---|---|
| Tablas | `system_events` (atom, technical), `group_events` (proyección semantic), atoms específicos por flow (`rsvp_actions`, `check_in_actions`, `bookings`, `vote_casts`, `ledger_entries`) |
| RPCs | `record_system_event(p_group, p_event_type, p_payload, p_actor, p_idempotency_key)` SECURITY DEFINER |
| Atoms | TODOS los anteriores. |
| Invariantes | `idempotency_key` UNIQUE per `(group_id, event_type)`. `processed_at` solo mutable null→ts por cron rule engine. |
| Modifica | Solo `processed_at`. |
| NO modifica | `event_type`, `payload`, `actor_id`, `group_id`, `created_at`. |
| Riesgos | Cron pierde batch → eventos no procesan reglas. Mitigación: idempotency_key + retry seguro. |

## A.7 Money Layer

**Propósito**: contabilidad shared-pool con projections.

| Item | Detalle |
|---|---|
| Tablas | `ledger_entries` (atom), `group_funds` (subtype resource), `group_settlements`, `group_pool_charges`, `group_obligations` |
| Views | `member_balance_in_group`, `member_obligation_summary`, `fund_balance_view`, `group_money_dashboard` |
| RPCs | `record_expense(...)`, `record_contribution(...)`, `verify_contribution(...)`, `record_settlement(...)`, `record_pool_charge(...)`, `record_payout(...)`, `reverse_transaction(...)`, `record_asset_valuation(...)`, `pay_sanction(...)` |
| Atoms | `ledger_entries`. |
| Invariantes | Ledger doctrine: TRI-ROLE (`recorded_by_member_id`, `paid_by_member_id`, `to_member_id`). Idempotency key obligatorio. Reverse = nuevo entry opuesto, NUNCA mutación. |
| Append-only? | YES, ledger guarded. |
| Modifica | NADA en `ledger_entries`. `group_settlements.status` lifecycle. |
| NO modifica | Todo en `ledger_entries`. |
| Riesgos | Doble pago si retry sin idempotency_key. Mitigación: `(group_id, idempotency_key)` UNIQUE en `ledger_entries`. |

## A.8 Resource Layer

**Propósito**: cosas gobernables del grupo.

| Item | Detalle |
|---|---|
| Tablas | `group_resources` (envelope), `group_funds`, `group_assets`, `group_spaces`, `group_documents` (subtypes) |
| RPCs | `create_group_resource(...)`, `archive_resource(...)`, `transfer_ownership(...)`, `record_asset_valuation(...)` |
| Ownership | `group_resources.owner_kind ∈ {group, member, role}`, `owner_member_id` cuando individual. |
| Invariantes | Subtype row obligatoria para envelope. Archived → no writes en subtype. |
| Modifica | `owner_*`, `archived_at`. |
| NO modifica | `id`, `group_id`, `resource_type`, `created_by`. |
| Riesgos | Transfer sin pago/aprobación. Mitigación: `transfer_ownership` evalúa reglas SYNC pre-commit (V2-G3.2). |

## A.9 Governance Layer

**Propósito**: decisiones colectivas + voting + legitimacy.

| Item | Detalle |
|---|---|
| Tablas | `group_decisions` (proposal envelope), `group_votes`, `vote_casts` (atom), `group_decision_rules` (per-group method+legitimacy config) |
| RPCs | `propose_decision(...)`, `start_vote(...)`, `cast_vote(...)`, `finalize_vote(...)`, `record_consent_objection(...)`, outcome handlers per `decision_type` |
| Atoms | `vote_casts`. |
| Invariantes | Quórum + threshold snapshot al `start_vote`, NO se recalculan si governance cambia mid-vote. Ranked-choice = N casts por member (1 per rank). |
| Modifica | `group_decisions.status`, `group_votes.status`, `result_payload`. |
| NO modifica | `vote_casts.*` post-insert. |
| Riesgos | Vote rigging via mandate. Mitigación: mandate NO puede llevar `vote.cast` permission (catálogo restringido). |

## A.10 Conflict Layer

**Propósito**: disputas + apelaciones + consequencias.

| Item | Detalle |
|---|---|
| Tablas | `group_disputes`, `group_dispute_events` (atom), `group_dispute_appeals` |
| RPCs | `open_dispute(...)`, `add_dispute_event(...)`, `escalate_dispute(...)`, `resolve_dispute(...)`, `appeal_sanction(...)` |
| Atoms | `group_dispute_events`. |
| Invariantes | Lifecycle locked: `open|under_review|resolved|escalated|withdrawn`. Resolution → consequencia opcional (reverse sanction, issue new sanction, restore membership). |
| Modifica | `group_disputes.status`, `resolution_payload`, `closed_at`. |
| Riesgos | Conflicto entre `appeal` y `pay_sanction` (sanción pagada con apelación abierta). Mitigación: `pay_sanction` valida `appeal.status NOT IN ('open','under_review')` o requiere `force=true`. |

## A.11 Memory Layer

**Propósito**: histórico completo replayable.

| Item | Detalle |
|---|---|
| Tablas | `system_events`, `group_events`, `group_history_entries` (proyección amigable), `group_reputation_events` |
| Views | `group_history_feed` (UNION desde múltiples atoms con polymorphic display) |
| RPCs | `record_system_event(...)`, `record_reputation_event(...)`, `group_history_feed(p_group, p_filters)` |
| Atoms | `system_events`, `group_reputation_events`. |
| Invariantes | NUNCA delete. Correlation via `parent_event_id`, `idempotency_key`, `causation_chain` (futuro). |
| Riesgos | Tablas crecen sin bound. Mitigación: particionado mensual + archive en V3. |

## A.12 Automation / Notification Layer

**Propósito**: side effects async + delivery.

| Item | Detalle |
|---|---|
| Tablas | `notifications_outbox`, `notification_preferences` (futuro), `push_tokens` |
| RPCs | `enqueue_notification(...)` SECURITY DEFINER. Cron edge function `dispatch-notifications-every-minute`. |
| Invariantes | Idempotency via `(group_id, kind, target_member_id, source_event_id)` UNIQUE. Dispatch retries con backoff. |
| Modifica | `dispatched_at`, `delivery_status`. |
| NO modifica | `payload`, `target_*`, `source_*`. |
| Riesgos | APNs token revocado → silent failure. Mitigación: log + retry + cleanup token. |

## A.13 Matriz de clasificación

| Layer | Foundation? | Dependents | Append-only atoms | Versionado | Immutable | Soft-delete |
|---|---|---|---|---|---|---|
| Identity | ✅ core | Membership, all writes via `actor_id` | — | — | `id` | NO |
| Group | ✅ core | Todo group-scoped | — | governance (V3) | `id`, `slug` | `dissolved_at` |
| Membership | ✅ core | Authority, Money, Votes | `group_membership_states_log` | — | `joined_at` | state=`left` |
| Authority | ✅ core | Toda RPC con permission check | `group_mandate_lifecycle` (V3) | role permissions (V3) | mandate scope | mandate `revoked_at` |
| Rules | ✅ core | Rule eval (todo) | `rule_versions`, `rule_evaluations` | YES versions | versions immutable | rule `status=archived` |
| Event | ✅ core | Toda audit + rule engine | `system_events`, atoms específicos | — | TODO `system_events` (excepto `processed_at`) | NUNCA |
| Money | high | Sanctions, Disputes, Settlements | `ledger_entries` | — | TODO ledger | NUNCA |
| Resource | high | Money (funds), Governance (decisions sobre resources) | `bookings` | — | resource immutable post-create excepto ownership | `archived_at` |
| Governance | high | Rules (rule_change), Money (budget), Membership | `vote_casts` | — | casts | decision `status=cancelled` |
| Conflict | medium | Sanctions, Membership | `dispute_events` | — | events | dispute `withdrawn` |
| Memory | ✅ core | Lectura cross-layer | `system_events`, `reputation_events` | — | TODO | NUNCA |
| Automation | low | Cross-layer outbound | — | — | payload | dispatched |

---

# B) DEPENDENCY GRAPH REAL

Notación: `↓` = depende de (FK directa o lookup), `→` = alimenta a (escribe / emite evento que consume).

```
profiles                       (atomic identity)
   ↓
groups                         (tenant root)
   ↓
group_memberships              ← group_invites
   ↓
   ├→ group_roles, group_role_permissions, group_permissions
   ├→ group_mandates
   ├→ group_reputation_events  (append-only)
   ├→ ledger_entries           (member_id columns: recorded_by, paid_by, to_member)
   ├→ vote_casts               (member_id)
   ├→ rsvp_actions, check_in_actions, bookings
   ├→ group_sanctions          (target_member_id, issued_by_member_id)
   ├→ group_disputes           (opener_member_id, respondent_member_id)
   ├→ group_resources          (owner_member_id when owner_kind='member')
   └→ group_dissolutions       (proposed_by_member_id)

group_resources                ← group_memberships (owner)
   ↓
   ├→ group_funds              (subtype)
   ├→ group_assets             (subtype)
   ├→ group_spaces             (subtype)
   ├→ group_documents          (subtype)
   ├→ ledger_entries           (source_resource_id)
   ├→ group_resource_ownership_events
   └→ bookings                 (resource_id when subtype=space)

rule_shapes_catalog            (vocabulary, group-independent)
   ↓
group_rules                    ← group_cultural_norms (promote_norm_to_rule)
   ↓
group_rule_versions            (snapshot of compiled rule, append-only)
   ↓
group_rule_evaluations         (per evaluation, append-only)
   ↑
   └─ trigger: system_events / atomic events

system_events                  (root event log, append-only)
   ↓ (cron / sync hook)
   ├→ group_rule_evaluations
   ├→ group_events             (semantic projection)
   ├→ notifications_outbox     (per outcome)
   └→ group_history_entries    (display projection)

group_decisions                ← group_memberships (proposed_by)
   ↓
group_votes
   ↓
vote_casts                     (atom, append-only)
   ↓ (finalize_vote)
   ├→ outcome handler dispatcher
   │    ├→ rule_change handler → publish_rule_version → group_rule_versions
   │    ├→ membership handler  → set_membership_state
   │    ├→ mandate handler     → create_mandate / revoke_mandate
   │    ├→ sanction_appeal handler → group_sanctions (status update)
   │    ├→ budget handler      → record_pool_charge
   │    ├→ resource handler    → create_group_resource / transfer_ownership / archive
   │    └→ dissolution handler → finalize_dissolution
   └→ system_events            (vote.finalized)

group_sanctions                ← group_rules (rule_version_id), group_disputes, group_decisions
   ↓
   ├→ ledger_entries           (kind='sanction_assessed')
   ├→ group_dispute_events     (when appealed)
   └→ system_events            (sanction.issued, sanction.paid, sanction.voided)

ledger_entries                 (the money atom)
   ↑
   ├ record_expense
   ├ record_contribution
   ├ record_settlement
   ├ record_pool_charge
   ├ record_payout
   ├ pay_sanction
   └ reverse_transaction
   ↓
   ├→ member_balance_in_group  (view)
   ├→ fund_balance_view        (view)
   └→ system_events            (expense.recorded, settlement.completed, etc.)

group_disputes                 ← group_sanctions, group_decisions
   ↓
   ├→ group_dispute_events     (atom)
   ├→ group_dispute_appeals
   └→ system_events            (dispute.opened, dispute.resolved)

group_mandates                 ← group_memberships
   ↓
   └→ used as parameter in money RPCs, sanction RPCs, governance RPCs

notifications_outbox           ← system_events (and direct enqueue from RPCs)
   ↓
   └→ APNs (via cron edge function)
```

## B.1 Reglas duras del grafo

1. **Toda escritura group-scoped** carga `group_id` + `actor_id` (auth.uid) + opcionalmente `mandate_id`.
2. **Toda RPC de dominio que muta canónico** termina con un `record_system_event` SECURITY DEFINER que persiste el atom.
3. **`evaluate_rules_for_event(p_event_id, 'sync')`** se llama EN LA MISMA TRANSACCIÓN, post-insert del atom + system_event, pre-commit.
4. **Outcome handlers de votos** son SYNC inline; no via cron.
5. **`notifications_outbox` writes** son ASYNC (no bloquean commit del dominio); cron drena.

---

# C) MATRIZ DE CONEXIONES (todas las primitivas)

Columnas: **Primitiva | Depende de | Alimenta a | Eventos emitidos | Eventos escuchados | Permisos clave | Tablas | RPCs | Riesgos | Edge cases**

> Para mantener legibilidad: una fila por primitiva canónica.

### C.1 Members (#1) / Identity
- Depende de: `auth.users`
- Alimenta a: TODO con actor/member.
- Emite: `member.profile_updated`
- Escucha: ninguno.
- Permisos clave: ninguno (self-service).
- Tablas: `profiles`.
- RPCs: `my_profile()`, `update_my_profile(...)`.
- Riesgos: PII leak. Edge case: phone change requiere re-verify OTP.

### C.2 Memberships / Boundary (#2, #15)
- Depende de: Identity, Groups.
- Alimenta a: Authority, Money, Votes, Sanctions, Disputes, Reputation.
- Emite: `member.invited`, `member.joined`, `member.state_changed`, `member.left`, `member.expelled`.
- Escucha: `decision.finalized (decision_type='membership')` → mutar estado.
- Permisos clave: `member.invite`, `member.remove`, `membership.suspend`, `membership.activate`.
- Tablas: `group_memberships`, `group_invites`, `group_membership_states_log`.
- RPCs: `invite_member`, `accept_invite`, `request_membership`, `set_membership_state`, `leave_group`, `remove_member`.
- Riesgos: Balance pendiente al salir.
- Edge cases: Provisional → active automático en `provisional_until` reached; reinvite a un `expelled` requiere `member.invite_expelled` permission separado.

### C.3 Purpose (#3)
- Depende de: Groups.
- Alimenta a: lectura iOS UI.
- Emite: `purpose.set`, `purpose.changed`.
- Escucha: ninguno.
- Permisos: `purpose.set`.
- Tablas: `group_purposes`.
- RPCs: `set_group_purpose(p_group_id, p_kind, p_body)`.
- Riesgos: Purpose change sin proceso de voto. Mitigación opcional: forzar via `decision_type='purpose_change'`.
- Edge cases: múltiples kinds simultáneos (declared+operative+emotional).

### C.4 Rules (#4)
- Depende de: Groups, `rule_shapes_catalog`, `group_cultural_norms` (opcional).
- Alimenta a: Rule engine (eval), Sanctions, Notifications.
- Emite: `rule.created`, `rule.published`, `rule.archived`, `rule.evaluated`.
- Escucha: `cultural_norm.endorsed` (≥ N) → opcional promote.
- Permisos: `rule.create`, `rule.publish`, `rule.archive`.
- Tablas: `group_rules`, `group_rule_versions`, `group_rule_evaluations`, `rule_shapes_catalog`.
- RPCs: `create_text_rule`, `create_engine_rule`, `publish_rule_version`, `validate_rule_shape`, `archive_rule`, `promote_norm_to_rule`, `evaluate_rules_for_event`, `simulate_rule_eval`.
- Riesgos: Loop eval. Shape inválido pasa validator pero falla en dispatcher.
- Edge cases: rule con `effective_from` futuro; rule archived mid-evaluation (debe terminar el batch en curso).

### C.5 Roles (#5)
- Depende de: Groups, Memberships.
- Alimenta a: Permissions (rol → perms set).
- Emite: `role.created`, `role.granted`, `role.revoked`, `role.updated`.
- Escucha: ninguno.
- Permisos: `role.create`, `role.grant`, `role.revoke`, `role.edit`.
- Tablas: `group_roles`, `group_role_permissions`, `group_membership_roles` (join).
- RPCs: `create_role`, `grant_role`, `revoke_role`, `update_role_permissions`.
- Riesgos: Lock-out (revocar único admin).
- Edge cases: Mitigation: `revoke_role` falla si target=último admin del grupo.

### C.6 Power / Authority (#6)
- Combinación de Roles + Permissions + Mandates.
- Ver C.5, C.7, C.20.

### C.7 Permissions (#17)
- Depende de: Roles, Memberships, Catálogo `permissions_catalog`.
- Alimenta a: TODO RPC con `assert_permission`.
- Emite: `permission.granted`, `permission.revoked`.
- Escucha: ninguno.
- Permisos: `permission.grant`, `permission.revoke`.
- Tablas: `group_permissions`, `group_role_permissions`, `permissions_catalog`.
- RPCs: `grant_permission`, `revoke_permission`, `assert_permission` (helper), `has_permission` (read).
- Riesgos: Permission catalog drift entre seed y código.
- Edge cases: Direct grant override de role denial (allowlist > rolelist).

### C.8 Resources (#8)
- Depende de: Groups, Memberships.
- Alimenta a: Money (funds), Governance (decisions sobre resources), Bookings (spaces).
- Emite: `resource.created`, `resource.archived`, `resource.ownership_transferred`.
- Escucha: `decision.finalized (decision_type='resource_change')`.
- Permisos: `resource.create`, `resource.archive`, `resource.transfer`.
- Tablas: `group_resources`, `group_funds`, `group_assets`, `group_spaces`, `group_documents`, `group_resource_ownership_events`.
- RPCs: `create_group_resource`, `archive_resource`, `transfer_ownership`.
- Riesgos: Subtype write sin envelope, ownership stale.
- Edge cases: archive fund con balance > 0; transfer asset con valuation pendiente.

### C.9 Contributions (#9)
- Depende de: Memberships, Money (ledger).
- Alimenta a: Reputation (signal), Member balance.
- Emite: `contribution.recorded`, `contribution.verified`.
- Escucha: ninguno.
- Permisos: ninguno para self-record; `contribution.verify` para verify-by-other.
- Tablas: `ledger_entries (kind='contribution')`, view `group_contributions`.
- RPCs: `record_contribution`, `verify_contribution`.
- Riesgos: Double-count si retry.
- Edge cases: in-kind contribution (no monto), valoración subjetiva.

### C.10 Sanctions (#11)
- Depende de: Rules (rule_version_id), Memberships (target), Money (ledger).
- Alimenta a: Disputes (appeal), Money (ledger assess/pay), Reputation.
- Emite: `sanction.issued`, `sanction.paid`, `sanction.voided`, `sanction.appealed`.
- Escucha: `rule.evaluated` con consequence `issue_sanction` → auto-issue.
- Permisos: `sanction.issue`, `sanction.void`, `sanction.review`.
- Tablas: `group_sanctions`, `ledger_entries (kind='sanction_assessed'|'sanction_paid')`.
- RPCs: `issue_sanction`, `issue_manual_fine`, `pay_sanction`, `void_sanction`, `start_appeal`, `finalize_fine_reviews`.
- Riesgos: Sanción duplicada si misma rule_evaluation re-evaluada.
- Edge cases: Sanction con partial payment (V2-G4), payment plan, auto-pay from fund.

### C.11 Reputation (#12)
- Depende de: Memberships.
- Alimenta a: UI (display), futuro Incentivos.
- Emite: `reputation.event_recorded`.
- Escucha: `sanction.issued`, `contribution.verified`, `vote.cast` (opcional positive signals).
- Permisos: `reputation.record`.
- Tablas: `group_reputation_events` (append-only, no score column).
- RPCs: `record_reputation_event`.
- Riesgos: Score implícito mal calculado client-side.
- Edge cases: No score canónico — UI muestra eventos directo.

### C.12 Memory (#13) — `system_events` + projections
- Depende de: TODO.
- Alimenta a: Rule engine, History UI, Audit replay.
- Emite: TODO (es el sink).
- Escucha: TODO (es el sink).
- Permisos: ninguno user-facing; SECURITY DEFINER inside RPCs.
- Tablas: `system_events` (atom), `group_events` (proyección), `group_history_entries`.
- RPCs: `record_system_event` (definer), `group_history_feed` (read).
- Riesgos: Crecimiento sin bound.
- Edge cases: Replay desde timestamp X requiere idempotency en todos los handlers.

### C.13 Disputes / Conflicts (#14)
- Depende de: Memberships, Sanctions (opcional), Decisions (opcional).
- Alimenta a: Sanctions (reverse), Membership state (escalate).
- Emite: `dispute.opened`, `dispute.event_added`, `dispute.escalated`, `dispute.resolved`.
- Escucha: ninguno (manual user flow).
- Permisos: `dispute.open`, `dispute.escalate`, `dispute.resolve`.
- Tablas: `group_disputes`, `group_dispute_events` (atom), `group_dispute_appeals`.
- RPCs: `open_dispute`, `add_dispute_event`, `escalate_dispute`, `resolve_dispute`, `appeal_sanction`.
- Riesgos: Appeal sobre sanction ya pagada.
- Edge cases: Dispute resolution = reverse sanction = nuevo `ledger_entry` opuesto.

### C.14 Decisions (#16)
- Depende de: Memberships, `group_decision_rules` config.
- Alimenta a: Rules (rule_change), Membership (state change), Mandates, Sanctions (appeal), Resources, Dissolutions.
- Emite: `decision.proposed`, `decision.vote_started`, `decision.finalized`, `decision.cancelled`.
- Escucha: nothing inbound (user-initiated).
- Permisos: `decision.propose`, `decision.start_vote`, `decision.finalize`, `decision.cancel`.
- Tablas: `group_decisions`, `group_votes`, `vote_casts` (atom), `group_decision_rules`.
- RPCs: `propose_decision`, `start_vote`, `cast_vote`, `finalize_vote`, outcome handlers per `decision_type`.
- Riesgos: Governance change mid-vote.
- Edge cases: ranked_choice tie, consent objection bloquea, weighted vote needs weight snapshot.

### C.15 Mandates / Representation (#23)
- Depende de: Memberships, Permissions catalog.
- Alimenta a: Money RPCs, Sanction RPCs, Decision RPCs.
- Emite: `mandate.granted`, `mandate.revoked`, `mandate.used` (per use).
- Escucha: ninguno.
- Permisos: `mandate.grant`, `mandate.revoke`.
- Tablas: `group_mandates`.
- RPCs: `create_mandate`, `revoke_mandate`, `list_my_mandates`.
- Riesgos: Mandate grant cross-purpose (expense pero usado en sanction).
- Edge cases: Mandate explicit overrides self-party check; expired mandate raises error.

### C.16 Money / Accounting (#19) — see Section G.
### C.17 Property (#18) — capa de Resources ownership.
### C.18 Cultural Norms / Culture (#20)
- Depende de: Memberships.
- Alimenta a: Rules (promote_norm_to_rule).
- Emite: `cultural_norm.proposed`, `cultural_norm.endorsed`, `cultural_norm.promoted`.
- Escucha: ninguno.
- Permisos: `cultural_norm.propose`, `cultural_norm.endorse`, `cultural_norm.promote`.
- Tablas: `group_cultural_norms`, `group_cultural_norm_endorsements`.
- RPCs: `propose_cultural_norm`, `endorse_norm`, `promote_norm_to_rule`.
- Riesgos: Norm promovida pero conflict con rule existente.
- Edge cases: Promotion threshold por governance jsonb.

### C.19 Rituals (#21)
- Depende de: Groups, Memberships, opcional Resources.
- Alimenta a: lectura UI.
- Emite: `ritual.created`, `ritual.occurred` (instance).
- Permisos: `ritual.create`, `ritual.complete`.
- Tablas: `group_rituals`, `group_ritual_occurrences`.
- RPCs: `create_ritual`, `update_ritual`, `record_ritual_occurrence`.

### C.20 Legitimacy (#22)
- No-entidad propia. Es columna enum en `group_decisions.legitimacy_source` (10 valores).
- Permite UI ofrecer "esta decisión es legítima porque <fuente>".

### C.21 Dissolution (#25)
- Depende de: Memberships, Resources (liquidación), Money (settlement final).
- Alimenta a: Group (`groups.dissolved_at`).
- Emite: `dissolution.proposed`, `dissolution.finalized`.
- Escucha: `decision.finalized (decision_type='dissolution')`.
- Permisos: `dissolution.propose`, `dissolution.finalize`.
- Tablas: `group_dissolutions`.
- RPCs: `propose_dissolution`, `finalize_dissolution`.
- Riesgos: Balances no-cero al disolver.
- Edge cases: Forced dissolution con balances activos → fund residuals split prorrateado.

### C.22 Notifications (#7 derivado)
- Ver Sección K.

### C.23-C.25 Comunicación / Incentivos / Cuidado — deferred. No entidad. Posible derivación via Memory + Reputation.

---

# D) OWNERSHIP MODEL CANÓNICO

## D.1 Tenancy boundaries

Tres niveles de tenancy:

| Nivel | Scope | Tablas |
|---|---|---|
| Global | Catálogos compartidos | `rule_shapes_catalog`, `permissions_catalog`, `templates`, `modules`, `profiles` |
| Group-scoped | Por `group_id` | TODO `group_*` + atoms relacionados (`ledger_entries`, `vote_casts`, `rsvp_actions`, ...) |
| User-scoped | Por `user_id` / `actor_id` | `profiles` (self), `push_tokens`, `notification_preferences` |

## D.2 Regla dura de RLS

Toda tabla group-scoped tiene policy:
```sql
USING (group_id IN (SELECT group_id FROM group_memberships WHERE user_id = auth.uid() AND state IN ('active','provisional')))
```
Para writes, además:
```sql
WITH CHECK (group_id IN (... mismo ...))
```

## D.3 Cascades

| Parent | Child | Cascade |
|---|---|---|
| `groups` (dissolve) | Tablas group-scoped | NO cascade; `dissolved_at` se chequea en RPCs (no-write post-dissolve). Mantener data viva para audit. |
| `group_memberships` (delete) | NO se delete; `state='left'` o `'expelled'`. Atoms con `member_id` mantienen FK. |
| `group_rules` (archive) | `group_rule_versions` quedan vivas como audit; engine no las evalúa más. |
| `group_resources` (archive) | Subtypes quedan vivas; reads filtran por `archived_at IS NULL`. Ledger con `source_resource_id` mantiene FK. |
| `group_decisions` (cancel) | `group_votes`, `vote_casts` quedan vivas como atomic record. |
| `profiles` (delete) | NO se delete. GDPR right-to-be-forgotten = anonymize fields, keep id+memberships. |

## D.4 Authority inheritance

```
Member action requires permission P.
1. Si `p_mandate_id IS NOT NULL`:
   1.1 Verificar mandate vivo + scope contains P → OK (authority_path='mandate').
   1.2 Si scope no contains P → error `mandate_scope_violation:<P>`.
2. Si P is self-party permission (record_expense self, etc.) AND actor matches target_party → OK (authority_path='self_party').
3. Else verificar direct_permission via assert_permission(actor, group, P):
   3.1 Direct grant en group_permissions → OK.
   3.2 Role grant via group_role_permissions JOIN group_membership_roles → OK.
   3.3 Else → error `permission_denied:<P>`.
```

Mandates NO heredan a sub-mandates. NO mandate delegation transitiva.

## D.5 Archival semantics

| Tabla | Archive col | Recovery | Notes |
|---|---|---|---|
| `groups` | `dissolved_at` | NUNCA un grupo se "des-disuelve". Resurrect = nuevo grupo. |
| `group_memberships` | `state` enum | sí (e.g. expelled → active via reinvite). |
| `group_rules` | `status='archived'` | sí, vía `republish_rule`. |
| `group_rule_versions` | `status='superseded'` + `effective_until` | NO, son immutable snapshots. |
| `group_resources` | `archived_at` | sí, vía un nuevo `create_group_resource` con `restored_from`. |
| `group_decisions` | `status='cancelled'` | NO, cancelado es terminal. |
| `notifications_outbox` | drop después de N días | NO, son ephemeral. |

## D.6 Cross-group isolation

- **NUNCA** un actor de grupo A puede leer/escribir tabla de grupo B sin membership activa en B.
- **NUNCA** un mandate de grupo A da permission en grupo B.
- **`profiles.display_name`** visible cross-group (es identity global), pero `phone`/`email` solo via self.
- **`group_memberships`** indexada `(user_id)` para que `list_my_groups()` funcione sin scan.

## D.7 Lista canónica por categoría

| Categoría | Tablas |
|---|---|
| Globales | `auth.users`, `profiles`, `rule_shapes_catalog`, `permissions_catalog`, `templates`, `modules` |
| Group-scoped | TODO `group_*`, `ledger_entries`, `vote_casts`, `rsvp_actions`, `check_in_actions`, `bookings`, `system_events`, `notifications_outbox` |
| User-scoped | `push_tokens`, `notification_preferences` (futuro) |
| Append-only | `system_events`, `ledger_entries`, `vote_casts`, `rsvp_actions`, `check_in_actions`, `bookings`, `group_rule_versions`, `group_rule_evaluations`, `group_dispute_events`, `group_reputation_events`, `group_membership_states_log`, `group_resource_ownership_events`, `group_cultural_norm_endorsements`, `group_ritual_occurrences` |
| Versionadas | `group_rule_versions`, (futuro) `group_governance_versions`, `group_role_versions` |
| Mutable lifecycle | `groups`, `group_memberships`, `group_rules`, `group_resources`, `group_resources` subtypes, `group_decisions`, `group_votes`, `group_sanctions`, `group_disputes`, `group_dissolutions`, `group_mandates`, `notifications_outbox.dispatched_at` |
| Soft-deletable | `group_resources.archived_at`, `group_rules.status='archived'`, `group_memberships.state IN ('left','expelled')`, `groups.dissolved_at` |
| NUNCA borrar | TODO append-only + `profiles` (anonymize si GDPR) |

---

# E) EVENT SYSTEM CANÓNICO

## E.1 Naming

`<noun>.<past_verb>` siempre en past. Ejemplos: `expense.recorded`, NO `expense.create`.

## E.2 Catálogo completo

| Event type | Emite | Payload keys | Idempotency key | Listeners | Sync rule eval? | Async side effects | Replay? | Persistencia |
|---|---|---|---|---|---|---|---|---|
| `group.created` | `create_group` | group_id, created_by, base_template | `group:<group_id>` | Notifications (founder welcome) | NO (no rules existen aún) | enqueue welcome notification | YES | system_events permanente |
| `group.dissolved` | `finalize_dissolution` | group_id, finalized_at, residuals | `dissolve:<group_id>` | Notifications all members | NO | notify, freeze writes | YES | permanente |
| `member.invited` | `invite_member` | group_id, invited_phone_or_email, invited_by, invite_token, expires_at | `invite:<token>` | Notifications | NO | enqueue SMS/email | YES | permanente |
| `member.joined` | `accept_invite` o `request_membership` (approved) | group_id, member_id, user_id, via_invite | `join:<member_id>` | Reputation (positive event), Rules (welcome trigger) | YES (rules con trigger `member.joined`) | notify admins | YES | permanente |
| `member.state_changed` | `set_membership_state` | group_id, member_id, from_state, to_state, reason, actor_id | `mstate:<member_id>:<to_state>:<idem>` | Rules, Notifications | YES | notify member | YES | permanente |
| `member.left` | `leave_group` | group_id, member_id, balance_at_exit | `leave:<member_id>:<ts>` | Rules, Notifications | YES | notify admins | YES | permanente |
| `member.profile_updated` | `update_my_profile` | user_id, fields_changed | `profile:<user_id>:<ts>` | NONE (cross-group) | NO | NONE | NO | NO (no es group-scoped) |
| `purpose.set` | `set_group_purpose` | group_id, kind, body, set_by | `purpose:<group>:<kind>:<idem>` | NONE | NO | optional notify | YES | permanente |
| `rule.proposed` | `create_text_rule` o `create_engine_rule` (draft) | group_id, rule_id, version_id, body | `rule_propose:<rule_id>` | NONE | NO | notify admins | YES | permanente |
| `rule.published` | `publish_rule_version` | group_id, rule_id, version_id, shape, effective_from | `rule_pub:<version_id>` | NONE en engine (no trigger event) | NO (publish no es event-driven) | notify members | YES | permanente |
| `rule.archived` | `archive_rule` | group_id, rule_id, archived_by | `rule_arch:<rule_id>:<ts>` | NONE | NO | notify | YES | permanente |
| `rule.evaluated` | `evaluate_rules_for_event` | group_id, rule_version_id, trigger_event_id, depth, verdict, consequences[] | `eval:<trigger_event>:<rule_version>` | NONE (es el output) | NO (es el output) | per consequence | YES | permanente (`group_rule_evaluations`) |
| `role.granted` | `grant_role` | group_id, member_id, role_id, granted_by | `role_grant:<member>:<role>:<ts>` | Notifications | NO | notify | YES | permanente |
| `role.revoked` | `revoke_role` | similar | similar | Notifications | NO | notify | YES | permanente |
| `permission.granted` | `grant_permission` | group_id, member_id, permission_key, granted_by | `perm_grant:<member>:<perm>:<ts>` | NONE | NO | NONE | YES | permanente |
| `mandate.granted` | `create_mandate` | group_id, granter, target_member, scope_permission_keys, expires_at | `mandate:<id>` | NONE | NO | notify target | YES | permanente |
| `mandate.revoked` | `revoke_mandate` | group_id, mandate_id, revoked_by, reason | `mandate_rev:<id>` | NONE | NO | notify target | YES | permanente |
| `resource.created` | `create_group_resource` | group_id, resource_id, resource_type, owner | `res_create:<resource_id>` | Rules | YES (trigger `resource.created`) | notify | YES | permanente |
| `resource.archived` | `archive_resource` | group_id, resource_id, reason | `res_arch:<resource_id>` | Rules | YES | notify | YES | permanente |
| `resource.ownership_transferred` | `transfer_ownership` | group_id, resource_id, from_owner, to_owner | `res_xfer:<resource_id>:<ts>` | Rules | YES | notify both | YES | permanente |
| `expense.recorded` | `record_expense` | group_id, ledger_entry_id, amount, paid_by, recorded_by, source_resource_id, mandate_id, splits | `expense:<idem>` | Rules | **YES** | notify affected | YES | permanente |
| `contribution.recorded` | `record_contribution` | similar | `contrib:<idem>` | Rules | **YES** | notify | YES | permanente |
| `contribution.verified` | `verify_contribution` | group_id, ledger_entry_id, verified_by | `contrib_verify:<entry>` | Rules | YES | notify recorder | YES | permanente |
| `settlement.completed` | `record_settlement` | group_id, ledger_entry_id, from, to, amount, mandate_id | `settle:<idem>` | Rules | **YES** | notify | YES | permanente |
| `pool_charge.created` | `record_pool_charge` | group_id, ledger_entry_id, amount, target_member | `pool_charge:<idem>` | Rules | **YES** | notify target | YES | permanente |
| `payout.recorded` | `record_payout` | similar | `payout:<idem>` | Rules | YES | notify | YES | permanente |
| `transaction.reversed` | `reverse_transaction` | group_id, original_entry_id, reversal_entry_id, reason | `reverse:<original>` | Rules | YES | notify | YES | permanente |
| `sanction.issued` | `issue_sanction` o auto-fired by rule | group_id, sanction_id, target_member, amount, rule_version_id, parent_evaluation_id | `sanction:<id>` | Rules (cuidado loops!) | **YES + depth+1** | notify target | YES | permanente |
| `sanction.paid` | `pay_sanction` | group_id, sanction_id, ledger_entry_id, amount | `sanction_pay:<id>:<idem>` | Rules | YES | notify issuer | YES | permanente |
| `sanction.voided` | `void_sanction` | group_id, sanction_id, voided_by, reason | `sanction_void:<id>` | NONE | NO | notify target | YES | permanente |
| `sanction.appealed` | `start_appeal` | group_id, sanction_id, appeal_id, appellant | `sanction_appeal:<id>` | Rules | YES | notify reviewers | YES | permanente |
| `decision.proposed` | `propose_decision` | group_id, decision_id, decision_type, proposer | `decision:<id>` | NONE | NO | notify members | YES | permanente |
| `decision.vote_started` | `start_vote` | group_id, decision_id, vote_id, method, quorum_snapshot, threshold_snapshot, deadline | `vote_start:<vote_id>` | NONE | NO | notify members | YES | permanente |
| `decision.vote_cast` | `cast_vote` | group_id, vote_id, member_id, choice, weight | `cast:<vote>:<member>:<ts>` (ranked: + rank) | NONE | NO | NONE bulk | YES | permanente (`vote_casts` atom) |
| `decision.finalized` | `finalize_vote` | group_id, decision_id, outcome, tally, legitimacy_source | `finalize:<decision_id>` | Rules + outcome handler | **YES** | notify members + dispatch outcome | YES | permanente |
| `decision.cancelled` | `cancel_decision` | group_id, decision_id, reason | `decision_cancel:<id>` | NONE | NO | notify | YES | permanente |
| `dispute.opened` | `open_dispute` | group_id, dispute_id, opener, respondent, subject | `dispute:<id>` | Rules | YES | notify respondent | YES | permanente |
| `dispute.event_added` | `add_dispute_event` | group_id, dispute_id, event_kind, payload | `dispute_event:<id>` | NONE | NO | notify | YES | permanente |
| `dispute.escalated` | `escalate_dispute` | group_id, dispute_id, escalated_to | `dispute_esc:<id>` | Rules | YES | notify | YES | permanente |
| `dispute.resolved` | `resolve_dispute` | group_id, dispute_id, resolution, consequences | `dispute_resolve:<id>` | Rules | YES | notify, may issue/void sanction | YES | permanente |
| `reputation.event_recorded` | `record_reputation_event` | group_id, member_id, event_type, source_event_id | `rep:<idem>` | NONE | NO | optional notify | YES | permanente |
| `cultural_norm.proposed` | `propose_cultural_norm` | group_id, norm_id, body | `norm:<id>` | NONE | NO | notify | YES | permanente |
| `cultural_norm.endorsed` | `endorse_norm` | group_id, norm_id, member_id | `norm_endorse:<norm>:<member>` | Rules (auto-promote at N endorsements) | YES | NONE | YES | permanente |
| `cultural_norm.promoted` | `promote_norm_to_rule` | group_id, norm_id, rule_id, version_id | `norm_promote:<norm>` | NONE | NO | notify | YES | permanente |
| `ritual.occurred` | `record_ritual_occurrence` | group_id, ritual_id, occurred_at, participants | `ritual:<idem>` | Rules | YES | notify | YES | permanente |

## E.3 Sync vs Async (regla canónica)

**Sync rule eval** se ejecuta en la misma transacción que el atom, BEFORE COMMIT, si:
- El consequence puede mutar estado canónico (sanction issue, membership state, rule publish, ledger entry, resource ownership).

**Async** se enqueue post-commit si:
- Es notification, email, push, projection, search index.

**Ningún async** puede mutar estado canónico. Si lo necesita → debe convertirse en sync RPC adicional.

## E.4 Idempotency

Toda RPC mutante acepta `p_idempotency_key text` (opcional, defaults a `gen_random_uuid()::text`). Constraint UNIQUE `(group_id, idempotency_key)` en cada atom relevante. Retry seguro.

## E.5 Replay

`replay_rule_evaluations(p_group_id, p_from_event_id, p_to_event_id)` (V3) corre el engine sobre events históricos sin mutar estado canónico — solo escribe a `group_rule_evaluations_replay` (tabla separada). Útil para auditoría retrospectiva tras cambio de rule shape.

---

# F) RULE ENGINE COMPLETO

## F.0 Doctrina founder G3 (5 lock-ins, 2026-05-28)

Aplican a TODAS las sub-slices G3.2-G3.5 y a cualquier extensión futura del engine.

1. **Modelo mental: políticas, no automations.** Una regla es `identity + scope + trigger + predicates + consequences + authority + audit`. NO es "if-this-then-that". Catálogo carga `scope` en triggers + `authority_required` en consequences porque son load-bearing para legitimidad institucional. *How to apply*: al agregar atom nuevo, exigir scope + execution + authority_required ANTES de mergear.
2. **Templates-only en G3 entero. Freeform jsonb = V3.** iOS jamás inventa kinds. User sólo elige atoms del catálogo + rellena `schema.fields`. Backend revalida vía `validate_rule_shape` antes de commit. *How to apply*: rechazar cualquier pedido de JSON editor en EditRuleView; subirlo a V3 con simulator full.
3. **Sync canonical vs async derived es load-bearing.** `issue_sanction` = sync + `sanctions.create`. `set_membership_state` = sync + `members.suspend`. `send_notification` = async + no authority. *How to apply*: G3.4 dispatcher rutea por `execution` field del atom. Mezclar paths rompe consistencia transaccional.
4. **G3.2 ≠ noop permanente.** `evaluate_rules_for_event` actual sólo audita (insert en `group_rule_evaluations`); no dispatcha. **Orden lockeado: G3.4 (handlers) ANTES o MERGED con G3.2.** Hookear sync eval sin handlers reales = ilusión.
5. **Explainability = requisito, no nice-to-have.** Cada row en `group_rule_evaluations` (post-G3.3 ALTER) debe responder: qué regla matcheó, qué predicate pasó/falló (con razón + valor), qué acción emitió, por qué. *Schema no opcional*: `parent_evaluation_id`, `depth`, `matched_predicate jsonb`, `actions_emitted jsonb`.
6. **Frontera engine vs voto** (lock-in `6bb56c78`, doctrina `doctrine_engine_vs_vote.md`). **Cambiar autoridad = voto.** **Aplicar autoridad existente = engine.** Reglas detectan el caso y *delegan a deliberación humana* cuando la consecuencia altera el orden social del grupo. *How to apply*: cuando agregues consequence nueva al catálogo, decide si **aplica una regla acordada** (engine sync) o **propone deliberación** (`start_vote` consequence). Casos canónicos: expulsar-por-3-sanciones = engine; abrir-grupo = voto; cobrar-tarde = engine; promover-a-admin = voto; notif-gasto-grande = engine; cambiar-quien-sanciona = voto.

**Why global**: reglas sin transparencia ni autorización catalogada erosionan confianza institucional. El engine es lo que diferencia Ruul de un Slackbot. El bridge engine→voto evita que "automatización" derive en "autoritarismo silencioso".

## F.1 Tablas + ALTERs requeridos

### F.1.1 `rule_shapes_catalog` (live, mig 00084 + G3.1 schema column)

✅ G3.1 cerrado (commit `04976c71`). Esquema final:
```sql
id text PRIMARY KEY,                              -- shape_key (e.g. "trigger.expense.recorded")
kind text NOT NULL CHECK (kind IN ('trigger','condition','consequence')),
label_es text NOT NULL,
summary_es text,
valid_scopes text[] NOT NULL,
valid_resource_types text[],
config_fields jsonb NOT NULL DEFAULT '[]',
sort_order int,
enabled boolean DEFAULT true,
schema jsonb NOT NULL DEFAULT '{}'                -- event_type, compatible_*, fields, execution, authority_required
```

**20 atoms vivos** (G3.1 seedeó 9; G3 polish mig `20260529000000` agregó 11 → 8 triggers + 6 conditions + 6 consequences):

| Categoría | Atoms | Notes |
|---|---|---|
| Triggers (8) | `money.expense_recorded`, `money.settlement_recorded`, `money.settlement_completed`, `contribution.logged`, `membership.left`, `sanction.issued`, `dispute.opened`, `mandate.granted` | `sanction.issued` = meta-trigger: engine puede observar sus propios outputs (depth+cycle guard contienen). Cobertura ~80% de eventos producción observados. |
| Conditions (6) | `amount_above(threshold)`, `amount_between(min, max)`, `actor_role_in([roles])`, `target_role_in([roles])`, `target_self`, `is_first_offense(lookback_days)` | `target_role_in` busca `payload.target_user_id||target` con fallback a membership_id. `is_first_offense` hace lookback contra `group_sanctions` del actor. |
| Consequences (6) | `issue_sanction` (sync, `sanctions.create`), `set_membership_state` (sync, `members.suspend`), `send_notification` (async, no auth), `create_pool_charge` (sync, `pool_charge.record`), `start_vote` (sync, `decisions.create`), [TBD] | `start_vote` = **puente engine→voto**: cuando regla detecta caso que requiere deliberación humana, en vez de aplicar consecuencia automática arranca decision con `use_event_entity=true`. Implementa frontera doctrinal lock-in #6. |

**5 RPCs vivas en backend post-G3**:
- `list_rule_shapes()` — iOS lee al boot (G3.1).
- `validate_rule_shape(p_shape jsonb)` — dry-run validator (G3.1).
- `create_engine_rule(...)` — atomic propose+publish, valida shape server-side (G3.1).
- `group_rules_engine(p_group_id)` — lectura per-rule con shape + condition_tree + consequences (G3.1).
- `group_rule_evaluations(p_group_id, p_limit, p_before)` — read paginado para iOS Disparos feed; hidrata `rule_title` + `trigger_event_type` + `matched_predicate` + `actions_emitted`; active-member gate; cursor por `evaluated_at DESC` (G3.5, mig `060500`).

### F.1.2 `group_rules` (live)
```sql
id uuid PRIMARY KEY,
group_id uuid NOT NULL REFERENCES groups(id),
title text NOT NULL,
rule_type text NOT NULL DEFAULT 'norm',
status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','archived')),
current_version_id uuid,
created_by uuid NOT NULL,
created_at timestamptz DEFAULT now(),
updated_at timestamptz DEFAULT now()
```

### F.1.3 `group_rule_versions` (live, append-only)
```sql
id uuid PRIMARY KEY,
rule_id uuid NOT NULL REFERENCES group_rules(id),
version int NOT NULL,
body text,                          -- text fallback display
shape_key text REFERENCES rule_shapes_catalog(id),
trigger_event_type text,
condition_tree jsonb,
consequences jsonb NOT NULL DEFAULT '[]',
execution_mode text CHECK (execution_mode IN ('sync','async')),
status text NOT NULL CHECK (status IN ('active','superseded','draft')),
effective_from timestamptz,
effective_until timestamptz,
created_by uuid NOT NULL,
created_at timestamptz DEFAULT now(),
UNIQUE (rule_id, version)
-- Partial index: only one active per rule
CREATE UNIQUE INDEX one_active_version_per_rule ON group_rule_versions(rule_id) WHERE status='active';
-- BEFORE UPDATE/DELETE guard: only status & effective_until mutable
```

### F.1.4 `group_rule_evaluations` (estado real post-G3.3, mig `20260528060200`)

✅ ALTER aplicado. Esquema final:
```sql
id uuid PRIMARY KEY,
group_id uuid NOT NULL,
rule_version_id uuid NOT NULL,
source_event_id uuid REFERENCES system_events(id),
matched boolean NOT NULL,
consequences_emitted jsonb NOT NULL DEFAULT '[]',
idempotency_key text NOT NULL UNIQUE,
evaluated_at timestamptz DEFAULT now(),
-- Added by G3.3 (explainability lock-in #5):
parent_evaluation_id uuid REFERENCES group_rule_evaluations(id),
depth int NOT NULL DEFAULT 0 CHECK (depth >= 0 AND depth <= 5),
matched_predicate jsonb,           -- {passed, reason, kind, evaluated_value}
actions_emitted jsonb,             -- [{kind, execution, status, target_id?, error?, audience?, recipients?, severity?, new_state?}]
cycle_detected boolean NOT NULL DEFAULT false   -- set inline por WITH RECURSIVE en evaluator
```

**Decisión real** (diverge del plan original):
- `verdict text` NO se agregó como column independiente — el outcome se infiere de `matched` + `cycle_detected` + `matched_predicate.passed` + `actions_emitted[].status`. iOS `GroupRuleEvaluation.summary` (helper Swift) genera el headline.
- `errors jsonb` NO se agregó — los errors per-action viven dentro de `actions_emitted[].error`. Más localizado, menos columns.
- `rule_id` NO se agregó como column — se deriva por JOIN a `group_rule_versions.rule_id`.
- `cycle_detected boolean` SÍ se agregó (no estaba en plan original) — bandera para que la fila se persista aún en ciclo (transparencia) sin disparar consequences.

Cycle detection: WITH RECURSIVE sobre `parent_evaluation_id` chain matcheando por `rule_version_id` repetido en el path. Depth guard MAX 5 sigue activo en signature.

`evaluate_rules_for_event` signature actual: `(p_event_id uuid, p_mode text, p_parent_evaluation_id uuid DEFAULT NULL)`. DROP+CREATE en G3.3 con default param; PostgREST resuelve callsites 2-arg legacy sin breaking change.

### F.1.5 Índices clave
```sql
CREATE INDEX group_rule_evaluations_group_at ON group_rule_evaluations(group_id, evaluated_at DESC);
CREATE INDEX group_rule_evaluations_trigger ON group_rule_evaluations(trigger_event_id);
CREATE INDEX group_rule_versions_active ON group_rule_versions(rule_id, status) WHERE status='active';
CREATE INDEX group_rules_active_by_group ON group_rules(group_id) WHERE status='active';
CREATE INDEX group_rules_active_by_event_type ON group_rule_versions(trigger_event_type) WHERE status='active';
```

## F.2 RPC `evaluate_rules_for_event` (firma + cuerpo lógico)

```sql
CREATE OR REPLACE FUNCTION evaluate_rules_for_event(
  p_event_id uuid,
  p_mode text DEFAULT 'sync',     -- 'sync' | 'async'
  p_parent_evaluation_id uuid DEFAULT NULL,
  p_depth int DEFAULT 0
) RETURNS TABLE (
  evaluation_id uuid,
  rule_version_id uuid,
  verdict text,
  consequences jsonb
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_event system_events%ROWTYPE;
  v_group_id uuid;
  v_event_type text;
  v_rule_version record;
  v_idem text;
  v_eval_id uuid;
  v_verdict text;
  v_consequences jsonb;
BEGIN
  -- 0. Lock + load event
  SELECT * INTO v_event FROM system_events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'event_not_found:%', p_event_id; END IF;
  v_group_id := v_event.group_id;
  v_event_type := v_event.event_type;

  -- 1. Depth guard
  IF p_depth >= 5 THEN
    INSERT INTO group_rule_evaluations(group_id, rule_id, rule_version_id, trigger_event_id, parent_evaluation_id, depth, verdict, idempotency_key)
    VALUES (v_group_id, NULL, NULL, p_event_id, p_parent_evaluation_id, p_depth, 'recursion_aborted', concat('depth_abort:', p_event_id::text));
    RETURN;
  END IF;

  -- 2. Cycle detection: walk parent_evaluation_id chain, abort si mismo rule_version_id ya en path
  -- (recursive CTE sobre group_rule_evaluations)

  -- 3. Find active rule versions matching trigger_event_type
  FOR v_rule_version IN
    SELECT rv.*, r.title
      FROM group_rule_versions rv
      JOIN group_rules r ON r.id = rv.rule_id
     WHERE r.group_id = v_group_id
       AND r.status = 'active'
       AND rv.status = 'active'
       AND rv.trigger_event_type = v_event_type
       AND (rv.effective_from IS NULL OR rv.effective_from <= now())
       AND (rv.effective_until IS NULL OR rv.effective_until > now())
     ORDER BY rv.created_at  -- stable order
  LOOP
    v_idem := concat('eval:', p_event_id::text, ':', v_rule_version.id::text);

    -- Idempotency: skip if already evaluated for this (event, version)
    IF EXISTS (SELECT 1 FROM group_rule_evaluations WHERE idempotency_key = v_idem) THEN CONTINUE; END IF;

    -- 4. Evaluate condition_tree against v_event.payload
    v_verdict := ruul.evaluate_condition_tree(v_rule_version.condition_tree, v_event.payload, v_event);

    IF v_verdict = 'match' THEN
      v_consequences := v_rule_version.consequences;
    ELSIF v_verdict = 'no_match' THEN
      v_consequences := '[]'::jsonb;
    ELSE
      v_consequences := '[]'::jsonb;
    END IF;

    -- 5. Insert evaluation BEFORE dispatch (so reverse-lookup works)
    INSERT INTO group_rule_evaluations(group_id, rule_id, rule_version_id, trigger_event_id, parent_evaluation_id, depth, verdict, consequences, idempotency_key)
    VALUES (v_group_id, v_rule_version.rule_id, v_rule_version.id, p_event_id, p_parent_evaluation_id, p_depth, CASE WHEN v_verdict='match' THEN 'matched_consequences' ELSE 'no_match' END, v_consequences, v_idem)
    RETURNING id INTO v_eval_id;

    -- 6. Dispatch consequences (if mode=sync)
    IF p_mode = 'sync' AND v_verdict = 'match' THEN
      PERFORM ruul.dispatch_consequences(v_group_id, v_event, v_eval_id, v_consequences, p_depth + 1);
    END IF;

    evaluation_id := v_eval_id;
    rule_version_id := v_rule_version.id;
    verdict := CASE WHEN v_verdict='match' THEN 'matched_consequences' ELSE 'no_match' END;
    consequences := v_consequences;
    RETURN NEXT;
  END LOOP;

  -- Mark event processed
  UPDATE system_events SET processed_at = now() WHERE id = p_event_id AND processed_at IS NULL;

  RETURN;
END;
$$;
```

## F.3 Dispatcher `ruul.dispatch_consequences`

```sql
CREATE OR REPLACE FUNCTION ruul.dispatch_consequences(
  p_group_id uuid,
  p_trigger_event system_events,
  p_evaluation_id uuid,
  p_consequences jsonb,
  p_next_depth int
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cons jsonb;
  v_action text;
  v_kind text;
BEGIN
  FOR v_cons IN SELECT * FROM jsonb_array_elements(p_consequences)
  LOOP
    v_action := v_cons->>'action';
    CASE v_action
      WHEN 'issue_sanction' THEN
        PERFORM ruul.consequence_issue_sanction(p_group_id, p_trigger_event, p_evaluation_id, v_cons, p_next_depth);
      WHEN 'send_notification' THEN
        PERFORM ruul.consequence_send_notification(p_group_id, p_trigger_event, v_cons);
      WHEN 'set_membership_state' THEN
        PERFORM ruul.consequence_set_membership_state(p_group_id, p_trigger_event, p_evaluation_id, v_cons, p_next_depth);
      WHEN 'record_pool_charge' THEN
        PERFORM ruul.consequence_record_pool_charge(p_group_id, p_trigger_event, p_evaluation_id, v_cons, p_next_depth);
      WHEN 'record_reputation_event' THEN
        PERFORM ruul.consequence_record_reputation(p_group_id, p_trigger_event, v_cons);
      ELSE
        UPDATE group_rule_evaluations SET errors = coalesce(errors,'[]'::jsonb) || jsonb_build_object('unknown_action', v_action) WHERE id = p_evaluation_id;
    END CASE;
  END LOOP;
END;
$$;
```

Cada `ruul.consequence_*` invoca la RPC dominio correspondiente con `p_actor := 'system'` y pasa el `p_parent_evaluation_id` para que el system_event que emita la RPC lleve causation tag. Las RPCs dominio internamente llaman `evaluate_rules_for_event(new_event_id, 'sync', p_parent_evaluation_id, p_next_depth)` → recursion correcta.

## F.4 Lifecycle integration con RPCs domain (estado real post-G3.2, mig `20260528060400`)

Cada RPC dominio sigue patrón:
```sql
BEGIN
  -- 1. validate, assert_permission
  -- 2. mutate canonical state (insert ledger, update sanction, etc.)
  -- 3. INSERT INTO system_events (atomic event) RETURNING id INTO v_event_uuid
  -- 4. PERFORM public.evaluate_rules_for_event(v_event_uuid, 'sync')
  -- 5. RETURN result
END;
```

**7 callsites vivos** (3 venían pre-G3.2, 4 nuevos en G3.2):

| Callsite | Event type emitido | Cableado en | Nota |
|---|---|---|---|
| `record_expense` | `money.expense_recorded` | pre-G3.2 | hoy único atom con regla activa fixture |
| `record_settlement` | `money.settlement_completed` | pre-G3.2 | audit-only hasta que founders publiquen rules |
| `record_pool_charge` | `money.pool_charge_created` | pre-G3.2 | audit-only |
| `issue_sanction` | `sanction.issued` | G3.2 (`060400`) | recursión potencial: handler del dispatcher → entry point. Depth+cycle guard contienen |
| `set_membership_state` | `member.state_changed` | G3.2 (`060400`) | cubre `leave_group` (NO requiere callsite separado) |
| `open_dispute` | `dispute.opened` | G3.2 (`060400`) | cubre `dispute_sanction` |
| `finalize_vote` | `decision.finalized` | G3.2 (`060400`) | NO se cablearon outcome handlers G2 (rule.archived/activated/pool_charge_created emergen como bookkeeping, no founder-policy) |

**Predicates vivos** (G3.4, mig `060300`):
- `actor_role_in([roles])` — JOIN a `group_member_roles`, devuelve `evaluated_value = [roles del actor]`.
- `amount_above(threshold)` — compara `event.payload.amount`.
- `target_self` — compara `actor_user_id` vs `payload.target_user_id`.
- NULL/empty predicate = pass (rule sin IF siempre dispara).

**Handlers vivos** (G3.4 + polish `6bb56c78`):
- `consequence.issue_sanction` — sync, PERFORM `issue_sanction` RPC, requires `sanctions.create`.
- `consequence.set_membership_state` — sync, PERFORM RPC, requires `members.suspend`.
- `consequence.send_notification` — async, INSERT en `notifications_outbox` per audience (`actor|admins|group`).
- `consequence.create_pool_charge` — sync, PERFORM `record_pool_charge` RPC, requires `pool_charge.record`. Caso: "cuotas automáticas por gasto en banda media".
- `consequence.start_vote` — sync, PERFORM `propose_decision` + `start_vote`, requires `decisions.create`. Use_event_entity=true linkea decision al objeto del evento. Implementa frontera doctrinal #6 (engine detecta → grupo delibera).

Cada handler envuelto en BEGIN/EXCEPTION; fallo se captura en `actions_emitted[].{status='failed', error}` sin rollback (doctrina lock-in #5).

**Deuda técnica V3** (lock-in `6bb56c78`): ELSIF hardcoded en `_rule_eval_predicate` y `_rule_eval_dispatch` sigue manejable a ≤15 atoms. Refactor a handler registry table-driven (`rule_action_handlers (kind text PK, execution, authority_required, plpgsql_function_name)` + `decision_outcome_handlers` análogo para eliminar cascadas ELSIF en `finalize_vote`) **lockeado V3**. No agregar atoms más allá de ~20 sin hacer el refactor primero.

## F.5 Loop prevention

Tres capas:
1. **Depth guard**: `p_depth >= 5` aborta con verdict `recursion_aborted`.
2. **Cycle detection**: recursive CTE sobre `parent_evaluation_id` chain; si `rule_version_id` reaparece → verdict `cycle_aborted`.
3. **Per-event idempotency**: `UNIQUE (idempotency_key)` evita re-eval del mismo (event, version) si retry.

## F.6 Error handling

- Error en un consequence dispatcher → NO aborta el batch; se persiste en `group_rule_evaluations.errors jsonb`. La transacción **NO rollback** (audit-first doctrine).
- Excepción CRÍTICA (permission denied al ejecutar consequence con `actor='system'`) → log + verdict `error`, dispatch otros consequences sigue.
- Si un consequence sync canónico (issue_sanction, set_membership_state) falla → eval marca `error` y NO se aborta el flow original. Riesgo conocido: estado parcial. Mitigación V3: opt-in `consequence_failure_mode='rollback_all'` por rule version.

## F.7 Retries

Retries solo aplican a async consequences (notifications). Sync no se reintenta: idempotency_key + depth/cycle ya garantizan no-double-fire.

## F.8 Audit + replay

- Toda eval persiste en `group_rule_evaluations`.
- Replay V3: re-corre `evaluate_rules_for_event` con `p_mode='dry_run'`, escribe a `group_rule_evaluations_replay` con flag, no muta estado.

## F.9 `simulate_rule_eval` RPC (V2-G3.6)
```sql
CREATE OR REPLACE FUNCTION simulate_rule_eval(
  p_rule_version_id uuid,
  p_fake_event jsonb
) RETURNS TABLE (
  matched boolean,
  consequences jsonb,
  errors jsonb
)
```
Internamente arma un `system_events` ROW in-memory, evalúa condition_tree, ejecuta dispatcher dry-run (consequences son texto explicativo, no se ejecutan), retorna preview.

## F.10 Workflows + AI agents futuros

Extensión natural: `consequences[].action = 'invoke_workflow'` con `workflow_id` apuntando a tabla `group_workflows`. Workflows = secuencias de actions con state. Out of scope V2. Diseño compatible porque dispatcher es enum-based.

AI agents: `consequences[].action = 'invoke_agent'` con `agent_id` + prompt. El agent inserta system_event posterior con `actor_kind='ai_agent'`. Compatibles porque dispatcher ya supports `actor='system'`.

## F.11 Locking strategy

- `SELECT ... FOR UPDATE` en `system_events` row al inicio de eval evita doble procesamiento.
- Transacción ENVOLVENTE de la RPC domain SE ENCARGA del isolation; eval reusa la conexión (no nuevo statement).

## F.12 Transaction boundaries

| Layer | Tx scope |
|---|---|
| RPC domain (e.g. `record_expense`) | inicia tx, contiene ledger insert + system_event + eval + dispatchers + nested system_events. Commit al final. |
| `evaluate_rules_for_event` (sync) | mismo tx que padre. |
| Dispatcher async (send_notification) | enqueue a outbox = mismo tx; cron drain = tx separada. |
| Cron rule engine cleanup (futuro) | tx separada por batch. |

---

# G) MONEY SYSTEM COMPLETO

## G.1 Atom + projections

### G.1.1 `ledger_entries` (atom append-only)
```sql
id uuid PRIMARY KEY,
group_id uuid NOT NULL,
kind text NOT NULL CHECK (kind IN (
  'expense', 'contribution', 'settlement', 'pool_charge',
  'payout', 'sanction_assessed', 'sanction_paid',
  'reversal', 'asset_valuation', 'transfer_in', 'transfer_out',
  'fund_deposit', 'fund_withdrawal'
)),
amount numeric(20,2) NOT NULL,
currency text NOT NULL DEFAULT 'MXN',
recorded_by_member_id uuid NOT NULL REFERENCES group_memberships(id),
paid_by_member_id uuid REFERENCES group_memberships(id),     -- factual payer (may differ from recorder)
to_member_id uuid REFERENCES group_memberships(id),          -- recipient
source_resource_id uuid REFERENCES group_resources(id),      -- which resource this contextualizes
mandate_id uuid REFERENCES group_mandates(id),               -- if acted-on-behalf
sanction_id uuid REFERENCES group_sanctions(id),
parent_ledger_entry_id uuid REFERENCES ledger_entries(id),   -- for reversals, settlements linking
splits jsonb,                                                -- expense split breakdown
metadata jsonb NOT NULL DEFAULT '{}',
idempotency_key text NOT NULL,
created_at timestamptz DEFAULT now(),
UNIQUE (group_id, idempotency_key)
```

### G.1.2 Projections
- `member_balance_in_group(p_group_id, p_member_id)` returns `{ pool_balance, peer_balance_by_counterparty[] }`.
- `fund_balance_view (group_id, resource_id, balance)`
- `member_obligation_summary (group_id, member_id, pending_sanctions, pending_pool_charges, total_due)`
- `group_money_dashboard (group_id)` — UI hero.

## G.2 Authority + approval flow

Per CanonicalRPCs_Contract.md (signed):

| RPC | Authority paths |
|---|---|
| `record_expense` | self_party (actor = paid_by) OR `direct_permission: expense.record_for_others` OR mandate |
| `record_contribution` | self_party OR `direct_permission: contribution.record_for_others` OR mandate |
| `verify_contribution` | `direct_permission: contribution.verify` |
| `record_settlement` | self_party (actor in {from, to}) OR `direct_permission: settlement.record_for_others` OR mandate |
| `record_pool_charge` | `direct_permission: pool_charge.create` OR mandate (admin-only flow) |
| `record_payout` | `direct_permission: payout.execute` OR mandate |
| `reverse_transaction` | self_party (if actor recorded original) OR `direct_permission: transaction.reverse` |
| `pay_sanction` | self_party (actor = target_member) OR mandate (`sanction.pay_for_other`) |
| `record_asset_valuation` | `direct_permission: asset.value` |

## G.3 Idempotency + ledger semantics

- TODO insert lleva `idempotency_key`. Cliente lo genera; server NO sobreescribe.
- Reverse = INSERT nuevo entry con `kind='reversal'`, `parent_ledger_entry_id = original`, `amount = -original.amount`. NUNCA UPDATE.
- Settlement linking: `ledger_entries.parent_ledger_entry_id` apunta al expense que cancela (cuando settle 1:1). Para settle agregado, `metadata.settled_expense_ids text[]`.

## G.4 Double-entry futuro

V3 opt-in: shadow table `ledger_accounting_lines` por cada `ledger_entries` (debit + credit lines). Mantiene ledger atom + agrega capa accounting. No bloquea V1/V2.

## G.5 Reconciliation

- View `member_balance_in_group` calcula `SUM(amount) WHERE to_member_id = m AND kind IN ('contribution','settlement_in')` − `SUM(amount) WHERE paid_by_member_id = m AND kind='expense'` − … (formula compleja por kind matrix).
- Discrepancia entre `member_obligation_summary` y direct count → trigger discrepancy alert (cron diario, V3).

## G.6 Conexiones a otras capas

| Money ↔ | Conexión |
|---|---|
| Rules | `expense.recorded`, `settlement.completed`, `pool_charge.created`, `sanction.issued/paid` son eventos triggers de reglas. |
| Events | TODO ledger insert → system_event paralelo. |
| Disputes | `pay_sanction` con appeal abierto → rechazo o tag `paid_with_appeal`. |
| Governance | `decision_type='budget'` → outcome handler invoca `record_pool_charge`. |
| Notifications | Cada ledger insert puede enqueue notification (e.g. "te debe X"). |
| Reputation | Patrones de contribución/pago → reputation_event signals. |
| Audit | Es full traceable (system_events + atoms inmutables). |

---

# H) GOVERNANCE SYSTEM

## H.1 Tablas

### H.1.1 `group_decisions`
```sql
id uuid PRIMARY KEY,
group_id uuid NOT NULL,
decision_type text NOT NULL CHECK (decision_type IN (
  'rule_change', 'membership', 'mandate', 'sanction_appeal',
  'budget', 'resource_change', 'governance_change',
  'dissolution', 'cultural_norm_promotion', 'purpose_change', 'free_form'
)),
title text NOT NULL,
description text,
proposed_by_member_id uuid NOT NULL,
status text NOT NULL CHECK (status IN ('proposed','open_for_vote','closed','cancelled')),
legitimacy_source text CHECK (legitimacy_source IN (
  'majority_vote', 'supermajority_vote', 'consensus', 'consent',
  'admin_decree', 'founder_decree', 'tradition', 'mandate_delegation',
  'rule_book', 'external_arbitrator'
)),
quorum_snapshot int,
threshold_snapshot numeric,
payload jsonb NOT NULL DEFAULT '{}',     -- decision_type-specific fields
result_payload jsonb,
created_at timestamptz DEFAULT now(),
closed_at timestamptz
```

### H.1.2 `group_votes`
```sql
id uuid PRIMARY KEY,
group_id uuid NOT NULL,
decision_id uuid NOT NULL REFERENCES group_decisions(id),
method text NOT NULL CHECK (method IN (
  'admin', 'majority', 'supermajority', 'consensus',
  'consent', 'ranked_choice', 'weighted', 'veto'
)),
quorum_snapshot int NOT NULL,
threshold_snapshot numeric NOT NULL,
weights_snapshot jsonb,                  -- {member_id: weight} for weighted
deadline timestamptz,
status text NOT NULL CHECK (status IN ('open','closed','cancelled')),
started_at timestamptz,
finalized_at timestamptz
```

### H.1.3 `vote_casts` (atom append-only)
```sql
id uuid PRIMARY KEY,
group_id uuid NOT NULL,
vote_id uuid NOT NULL,
member_id uuid NOT NULL,
choice text,                             -- 'yes'/'no'/'abstain' or option_id
rank int,                                -- ranked_choice (1..N)
weight numeric NOT NULL DEFAULT 1.0,    -- snapshot from weights_snapshot
metadata jsonb,                          -- consent objection note, etc.
cast_at timestamptz DEFAULT now()
-- ranked_choice: N rows per (vote_id, member_id), one per rank
-- majority/etc: 1 row, latest wins via vote_counts_view
```

## H.2 RPCs

```
propose_decision(p_group_id, p_decision_type, p_title, p_payload, p_legitimacy_source) → decision_id
start_vote(p_decision_id, p_method, p_quorum, p_threshold, p_deadline, p_weights) → vote_id
cast_vote(p_vote_id, p_choice, p_rank?, p_metadata?) → cast_id
record_consent_objection(p_vote_id, p_member_id, p_note) → cast_id (kind=objection)
finalize_vote(p_vote_id) → result
cancel_decision(p_decision_id, p_reason) → void
```

## H.3 Quorum + threshold

- **Snapshot** al `start_vote`. NO se recalculan si membership cambia.
- **Quorum** = `count(distinct member_id) ≥ quorum_snapshot`.
- **Threshold** = `sum(choice='yes' * weight) / sum(weight) ≥ threshold_snapshot`.
- **Consent**: `forall casts: choice != 'objection' OR objection.acceptable=true`. Single sustained objection → vote fails.
- **Ranked-choice (Borda)**: tally por rank, dispatcher computa winner.
- **Weighted**: `weights_snapshot[member_id]` aplicado al cast.

## H.4 Authority delegation via mandate

- `cast_vote` NO acepta `p_mandate_id`. Voting es non-delegable por doctrina (representación directa solo).
- `propose_decision` con `p_mandate_id` → permite proponer en nombre de otro si scope incluye `decision.propose`.

## H.5 Outcome dispatcher

Al finalize_vote con outcome `passed`:
```sql
CASE p_decision.decision_type
  WHEN 'rule_change'   THEN PERFORM publish_rule_version(...) USING p_decision.payload
  WHEN 'membership'    THEN PERFORM set_membership_state(...) USING p_decision.payload
  WHEN 'mandate'       THEN PERFORM create_mandate(...) USING p_decision.payload
  WHEN 'sanction_appeal' THEN PERFORM void_sanction(...) OR pay_sanction(...) per payload
  WHEN 'budget'        THEN PERFORM record_pool_charge(...) USING p_decision.payload
  WHEN 'resource_change' THEN PERFORM create_group_resource(...) OR archive_resource(...) OR transfer_ownership(...)
  WHEN 'governance_change' THEN UPDATE groups SET governance = ... (V3: + group_governance_versions snapshot)
  WHEN 'dissolution'   THEN PERFORM finalize_dissolution(...)
  WHEN 'cultural_norm_promotion' THEN PERFORM promote_norm_to_rule(...)
  WHEN 'purpose_change' THEN PERFORM set_group_purpose(...)
  WHEN 'free_form'     THEN NULL  -- decisión sin efecto canónico, solo audit
END;
```
Cada handler emite su propio system_event que dispara reglas.

## H.6 Immutable history

`vote_casts` append-only con guard. `group_decisions.result_payload` se escribe una sola vez al `finalize_vote`; guard partial: UPDATE permitido SOLO si `status='open_for_vote' → 'closed'` (single transition).

## H.7 Emergency powers / veto

- `decision_type='governance_change'` con `payload.emergency=true` + `legitimacy_source='founder_decree'` → bypassa quorum si rol = founder.
- Veto = `method='veto'`: una sola `choice='veto'` cast por miembro con `veto_holder=true` rol falla la decision.

---

# I) DISPUTES + CONSEQUENCES

## I.1 Tablas

```sql
group_disputes (
  id uuid PK,
  group_id uuid,
  opener_member_id uuid,
  respondent_member_id uuid,
  subject_kind text CHECK (subject_kind IN ('sanction','member_behavior','decision','rule','resource_use','other')),
  subject_id uuid,
  status text CHECK (status IN ('open','under_review','resolved','escalated','withdrawn')),
  resolution_payload jsonb,
  closed_at timestamptz,
  created_at timestamptz
)

group_dispute_events (atom append-only) (
  id, dispute_id, event_kind, actor_id, payload, created_at
)

group_dispute_appeals (
  id, dispute_id, sanction_id, status, reviewers_member_ids[], created_at
)
```

## I.2 Lifecycle

```
open  ───┬──> under_review ───┬──> resolved
         │                    └──> escalated ──> resolved
         └────────────────────────────────────> withdrawn
```

`resolved.resolution_payload` puede incluir:
- `{ action: 'void_sanction', sanction_id }` → consequence reverses sanction.
- `{ action: 'issue_new_sanction', target_member_id, amount, kind }` → counter-sanction.
- `{ action: 'restore_membership', member_id }` → un-expel.
- `{ action: 'no_action' }` → audit only.

## I.3 Appeal flow

```
issue_sanction(target_member)
  → target_member.start_appeal(sanction_id, reason)
    → group_dispute created with subject_kind='sanction'
    → group_dispute_appeals row created
    → reviewers notified (notifications_outbox)
    → reviewers vote via finalize_fine_reviews OR finalize_vote(decision_type='sanction_appeal')
      → resolve_dispute(resolution)
```

## I.4 Automatic vs manual

- **Automatic**: rule engine consequence `issue_sanction` → no manual review unless target appeals.
- **Manual**: user-initiated `open_dispute` for behavioral issues.

## I.5 Arbitration future

V3: `group_arbitrators` table + `escalate_dispute(p_arbitrator_id)` routes to specific reviewer. Out of V2 scope.

---

# J) MEMORY / AUDIT SYSTEM

## J.1 Append-only strategy

| Tabla | Guard | Mutability |
|---|---|---|
| `system_events` | partial guard | only `processed_at: null → ts` |
| `ledger_entries` | full guard | NONE post-insert |
| `vote_casts` | full guard | NONE |
| `rsvp_actions` | full guard | NONE |
| `check_in_actions` | full guard | NONE |
| `bookings` | full guard | NONE |
| `group_rule_versions` | partial guard | `status`, `effective_until` only |
| `group_rule_evaluations` | full guard (NEW) | NONE |
| `group_dispute_events` | full guard | NONE |
| `group_reputation_events` | full guard | NONE |
| `group_membership_states_log` | full guard | NONE |
| `group_resource_ownership_events` | full guard | NONE |
| `group_cultural_norm_endorsements` | full guard | NONE |
| `group_ritual_occurrences` | full guard | NONE |

`ruul.raise_immutable_atom()`:
```sql
CREATE OR REPLACE FUNCTION ruul.raise_immutable_atom() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'immutable_atom:%:%', TG_TABLE_NAME, OLD.id USING ERRCODE = '23514';
END;
$$ LANGUAGE plpgsql;
```

## J.2 Retention

| Tabla | Retention | Archive strategy |
|---|---|---|
| `system_events` | 1y hot, archive a partición frío después | particionado monthly |
| `ledger_entries` | forever (es contabilidad) | particionado monthly, sin archive |
| `group_rule_evaluations` | 90d hot, archive después | partición + cold storage S3 (V3) |
| `notifications_outbox` | 7d post-dispatch | hard delete |
| `vote_casts` | forever | sin archive |

## J.3 Replay

Replay engine V3:
```sql
replay_event(p_event_id) -- corre engine en modo dry_run
replay_group_history(p_group, p_from, p_to) -- procesa eventos secuencialmente
```
Escribe a tabla replay separada; NUNCA muta canónico.

## J.4 Actor attribution

- Cada atom carga `actor_id uuid` y opcional `actor_kind text` (`user|system|ai_agent|cron`).
- `system_events.actor_id` puede ser NULL para system-emitted.

## J.5 Causality chains

- `parent_evaluation_id` en `group_rule_evaluations`.
- `parent_ledger_entry_id` en `ledger_entries` (settlement → expense).
- `parent_event_id` en `system_events` (consequence event → trigger event).
- Correlation ID: `system_events.correlation_id uuid` (NEW, V2-G3.3) — todo el batch de un trigger comparte correlation_id.

## J.6 Timeline reconstruction

`group_history_feed(p_group, p_filters)` UNION sobre:
- `system_events`
- `group_events` (proyección semantic)
- `ledger_entries` (display via UI map)
- `vote_casts` (aggregate to vote.cast event)
- `group_dispute_events`
- `group_reputation_events`
- `group_rule_evaluations` (admin only)

Ordered by `created_at DESC`, filterable por `event_type`, `actor_id`, `target_member_id`.

---

# K) NOTIFICATION SYSTEM

## K.1 Tablas

```sql
notifications_outbox (
  id uuid PK,
  group_id uuid NOT NULL,
  kind text NOT NULL,                          -- 'sanction.issued', 'expense.recorded', 'vote.deadline_soon', ...
  target_member_id uuid NOT NULL,
  source_event_id uuid REFERENCES system_events(id),
  payload jsonb NOT NULL,
  scheduled_for timestamptz DEFAULT now(),
  dispatched_at timestamptz,
  delivery_status text,                        -- 'pending','dispatched','failed','revoked_token','suppressed'
  retry_count int DEFAULT 0,
  last_retry_at timestamptz,
  created_at timestamptz DEFAULT now(),
  UNIQUE (group_id, kind, target_member_id, source_event_id)
)

push_tokens (
  id uuid PK,
  user_id uuid REFERENCES auth.users(id),
  apns_token text,
  device_id text,
  active boolean DEFAULT true,
  registered_at timestamptz
)

notification_preferences (    -- V3
  user_id, group_id, kind, enabled, channel
)
```

## K.2 Event-driven enqueue

Patrón:
- Cada RPC dominio emite system_event.
- Trigger AFTER INSERT en `system_events` → `ruul.enqueue_notifications_for_event(event)` (definer) → inserts a outbox.
- O las RPCs llaman directo `enqueue_notification(...)`.

## K.3 Fanout

`enqueue_notifications_for_event` resuelve audiencia por `event.kind`:
- `expense.recorded` → fanout a participantes en `splits[]`.
- `sanction.issued` → solo target_member + admins.
- `vote.deadline_soon` → todos los `vote_pending_members`.
- `decision.finalized` → fanout a todo el grupo.

## K.4 Delivery guarantees

- At-least-once vía cron retry hasta `retry_count >= 5` → marca `failed`.
- Dedupe vía UNIQUE constraint (`group_id, kind, target, source_event_id`).
- Backoff exponencial: `last_retry_at + 2^retry_count * 1 minute`.

## K.5 Batching

V3: agrupar por `(target_user_id, group_id, 5min_window)` → 1 push notification con summary.

## K.6 Preferences

V3: `notification_preferences (user_id, group_id, kind, enabled)`. Pre-dispatch check: skip si `enabled=false`.

## K.7 Cron

Edge function `dispatch-notifications-every-minute`:
1. SELECT outbox WHERE dispatched_at IS NULL AND scheduled_for ≤ now() AND retry_count < 5.
2. Para cada, lookup push_tokens, send via APNs.
3. UPDATE delivery_status + dispatched_at.

---

# L) FUTURE-PROOFING

## L.1 Múltiples grupos por usuario
✅ Ya soportado. `group_memberships (user_id, group_id)` n:m. `list_my_groups()` indexed.

## L.2 Organizaciones complejas / Subgrupos
Diseño futuro:
- `groups.parent_group_id uuid REFERENCES groups(id)` (nullable).
- Permission inheritance opt-in (`groups.inherit_parent_permissions boolean`).
- Members en parent NO son automáticamente members del child; explicit memberships.
- NO implementar todavía. Bloqueador: RLS queries con CTE recursivo agregan latencia.

## L.3 Nested authority
- Mandates ya son delegación. Sub-mandates (mandate delegando a otro mandate) bloqueados por doctrina.
- Para nested orgs: `group_mandates.parent_mandate_id` (V4).

## L.4 Federation
Out of scope. Requeriría: `federations`, cross-tenant identity bridge, schema-level multi-tenant strategy. NO bloquear con decisiones actuales.

## L.5 AI agents
- `actor_kind ∈ ('user','system','ai_agent')` ya soportado en system_events.
- Agent identity = pseudo-membership con `member.kind='agent'` + token-based auth.
- Rule engine ya soporta `consequence.action='invoke_agent'` (futuro). NO implementar todavía.

## L.6 Workflows / Automation chains
- Extensión de rule consequences: `action='invoke_workflow'` + `workflow_id`.
- Tabla `group_workflows (id, group_id, steps jsonb, ...)`.
- Workflow steps = chained system_events con `correlation_id`.
- Compatible con design actual; NO implementar V2.

## L.7 Tokenización
- Si tokens internos: nueva resource_type='token'. Ledger maneja como any other money con `currency='TOKEN_X'`.
- External (web3): out of scope, fuera del envelope de Ruul.

## L.8 Reputación portable
- Reputation events son group-scoped. Para portable: `cross_group_reputation_aggregate(user_id)` view que UNION events filtrando por opt-in `groups.share_reputation`.
- NO implementar todavía.

## L.9 Permissions marketplace
- Catálogo `permissions_catalog` es seed-controlled. Marketplace requeriría: per-group permission definitions. Out of scope.

## L.10 Plugins / external integrations
- Vía edge functions + outbox routing.
- `notifications_outbox.channel text` ('apns'|'webhook'|'slack'|'email').
- Compatible.

## L.11 Decisiones actuales que ayudan
- Atoms append-only → replay always possible.
- `idempotency_key` everywhere → retry safe.
- Polymorphic resources → nuevos tipos sin schema change.
- Rule shapes vocabulary in DB → nuevos shapes sin deploy iOS.
- Mandate-as-explicit → delegation pattern reutilizable.
- `system_events` + correlation_id → causality across multiple primitives.

## L.12 Decisiones actuales que bloquean
- `groups.governance jsonb` sin versionar → tracking changes harder.
- `groups.roles jsonb` (legacy) → ya migrado a tabla.
- Sin particionado en atoms → escalability cap > 100M rows.
- Permission catalog statico → no marketplace.

---

# M) IMPLEMENTATION PLAN

## M.1 Prioridad ordenada (revisada 2026-05-28 post-G3.5 commit `cf9a8b8d`)

| # | Item | Capa | Sesiones | Estado / Bloquea |
|---|---|---|---|---|
| 0 | V2-G3.1 Shape catalog + builder + dry-run + 4 RPCs + iOS engine UX | Rules+iOS | — | ✅ DONE (commit `04976c71`, 419 tests) |
| 1 | V2-G3.3 ALTER `group_rule_evaluations` (explainability columns + cycle_detected + 3-arg signature) | Rules | — | ✅ DONE (commit `30efadce`, mig `060200`) |
| 2 | V2-G3.4 Predicate evaluator + 3 consequence handlers (sync sanction, sync membership, async notification) | Rules | — | ✅ DONE (commit `904e9127`, mig `060300`, 4/4 smokes) |
| 3 | V2-G3.2 Cable hook en 4 callsites canónicos (issue_sanction, set_membership_state, open_dispute, finalize_vote) | Rules+todo | — | ✅ DONE (commit `7270e3d4`, mig `060400`, e2e verde) |
| 4 | V2-G3.5 iOS Disparos feed (RPC `group_rule_evaluations` + RuleEvaluationsStore + RuleEvaluationsView + 8 tests) | iOS UI+Rules | — | ✅ DONE (commit `cf9a8b8d`, mig `060500`, 427 tests) |
| 5 | ~~V2-G3.6 Simulator~~ → **diferido a V3** (dry-run ya quedó en G3.1) | Rules | — | V3 |
| 6 | **V2-G8 Engine-driven UX** — banner global "Sistema evaluó M reglas en últimas 24h" en `GroupHomeFeedView` + per-resource "qué reglas matchearon aquí" | iOS UI | 1-2 | siguiente; G3 ya cerrado |
| 7 | V2-G4 Sanction ↔ Money deep (partial pay, plans, auto-pay from fund) | Money+Sanctions | 3-4 | independent de G8 |
| 8 | V3: Particionar `system_events` + `ledger_entries` monthly | Memory+Money | 2 | scalability |
| 9 | V3: `group_governance_versions` + `group_role_versions` snapshots | Authority+Governance | 1-2 | audit |
| 10 | V3: Deprecate `rules`, `fines`, `events` legacy tables | Cleanup | 1 | nothing critical |
| 11 | V3: Cron `discrepancy_alert` for ledger reconciliation | Money | 1 | observability |
| 12 | V3: Replay engine + freeform jsonb rule editor + simulator full | Memory+Rules | 2-3 | audit complete |
| 12b | V3: **Handler registry refactor** — `rule_action_handlers` + `decision_outcome_handlers` tables, eliminar ELSIF cascades en `_rule_eval_predicate`/`_rule_eval_dispatch`/`finalize_vote`. Bloqueador soft: no crecer catálogo > 20 atoms sin esto. | Rules+Governance | 1-2 | scaling atoms |
| 13 | V4: Subgroups (`groups.parent_group_id`) | Group | 5+ | org complex |
| 14 | V4: AI agents (`actor_kind='ai_agent'`) | Automation | 5+ | productizar |

## M.2 Qué NO hacer todavía
- NO crear entidad para Comunicación, Incentivos, Cuidado.
- NO implementar federation / multi-org.
- NO crear permissions marketplace.
- NO migrar a double-entry accounting (V3+).
- NO implementar AI agents.
- NO unify atoms en single table (mantener por flow).

## M.3 Deuda técnica aceptable temporal
- `groups.governance jsonb` sin versionar (V3 fix).
- `rules` / `fines` / `events` legacy coexisten (deprecate V3).
- `notifications_outbox` sin user preferences (V3).
- Sin particionado en atoms (V3 cuando vol ≥ 10M rows).
- `member_balance_in_group` recalcula on-read (sin cache); aceptable hasta 1k members.

## M.4 Deuda técnica NO aceptable
- `group_rule_evaluations` sin atom guard → ALTER mandatorio en G3.3.
- Hooks SYNC `evaluate_rules_for_event` no wireados → G3.2 mandatorio.
- Dispatcher de consequences inexistente → G3.4 mandatorio.
- Permission check inline duplicado vs `assert_permission` → auditar y consolidar en G3.0.
- Mutar atom directamente vía RPC sin guard → fix antes de habilitar más writes.

## M.5 Riesgos técnicos
- **Loop infinito de eval** mitigado por depth+cycle, pero requiere test exhaustivo.
- **Partial state ante error en dispatcher** — Decisión: `errors jsonb` en eval, no rollback. Aceptable si UX expone errores claramente.
- **Race condition en concurrent vote_casts**: `vote_counts_view` usa GROUP BY + max(cast_at); concurrent casts del mismo member resuelven by latest. Mitigado.
- **`record_settlement` over-pay** ya tiene fix V2-G4 pending.

## M.6 Observabilidad necesaria
- Métricas: rule_eval_duration_p95, dispatch_consequence_count, depth_aborted_count, cycle_aborted_count, outbox_pending_count, notification_failure_rate.
- Logs: structured con `correlation_id`, `group_id`, `rule_version_id`.
- Sentry: ya integrado, captura excepciones en sync path.

---

# N) SMOKE TESTS

Todos en `swift-testing` framework. Backend smokes en SQL scripts ejecutables vía `psql` + comparación de output esperado.

## N.1 Groups
1. `create_group` happy → returns group_id + admin membership creado.
2. `create_group` con nombre duplicado del mismo user → OK (no unique).
3. `create_group` con `base_template='dinner_recurring'` → seeded rules existen.
4. `dissolve_group` con balance != 0 → error `dissolution_blocked_pending_balance`.
5. `dissolve_group` happy → `dissolved_at` set, RPCs subsequent fallan con `group_dissolved`.

## N.2 Memberships
1. `invite_member` → invite row, system_event, notification enqueued.
2. `accept_invite` happy → membership active.
3. `accept_invite` con invite expirado → error `invite_expired`.
4. `set_membership_state(suspended)` por non-admin → `permission_denied:membership.suspend`.
5. `leave_group` con pending sanction → error `pending_obligations`.
6. `remove_member` happy → state='expelled', log row.
7. RLS: user A select group_memberships of group de user B → 0 rows.

## N.3 Authority
1. `assert_permission(actor, group, 'expense.record')` con mandate explicit con scope → OK, authority_path='mandate'.
2. `assert_permission` con mandate inválido (revoked) → error `mandate_revoked`.
3. `assert_permission` self_party = OK.
4. `assert_permission` direct_grant = OK.
5. `assert_permission` sin nada = `permission_denied`.
6. `create_mandate` con scope vacío → error `mandate_scope_empty`.
7. `revoke_role` que dejaría grupo sin admin → error `last_admin_protection`.

## N.4 Rules
1. `validate_rule_shape` con shape válido → `valid=true`.
2. `validate_rule_shape` con shape_key inexistente → `valid=false, errors=[shape_not_found]`.
3. `publish_rule_version` happy → row en `group_rule_versions` + status='active'.
4. `publish_rule_version` con rule existente y previous active → previous → 'superseded'.
5. `evaluate_rules_for_event` con event sin reglas matching → 0 eval rows.
6. `evaluate_rules_for_event` con regla matching + consequence `send_notification` → 1 eval row + 1 outbox row.
7. Recursion test: rule A consequence triggers regla B consequence triggers... → aborta a depth 5.
8. Cycle test: rule A → event X → rule A re-match (cycle) → aborta `cycle_aborted`.
9. Idempotency: `evaluate_rules_for_event(same_event)` 2x → 1 row en evaluations.
10. RLS: select `group_rule_evaluations` cross-group → 0 rows.
11. Atom guard: UPDATE `group_rule_evaluations` → exception.

## N.5 Events
1. `record_system_event` happy → row con idempotency_key.
2. `record_system_event` con dup idempotency_key → returns existing id.
3. UPDATE system_events SET event_type → exception.
4. UPDATE system_events SET processed_at = ts WHERE processed_at IS NULL → OK.

## N.6 Money
1. `record_expense` self happy → ledger row + system_event + rule eval.
2. `record_expense` con `mandate_id` válido → ledger row con mandate_id persisted.
3. `record_expense` con `mandate_id` cuyo scope no incluye `expense.record_for_others` → `mandate_scope_violation`.
4. `record_expense` con duplicate idempotency_key → returns existing entry, no double-insert.
5. `record_settlement` que cancela expense → `parent_ledger_entry_id` set, balance moves to 0.
6. `reverse_transaction` → new ledger row con negative amount + parent ref.
7. `pay_sanction` self → ledger row kind='sanction_paid', sanction.status='paid'.
8. `pay_sanction` con appeal abierto → error `appeal_open` (unless `force=true`).
9. Atom guard: UPDATE ledger_entries SET amount → exception.
10. RLS: select ledger_entries cross-group → 0 rows.
11. View: `member_balance_in_group` matches sum.

## N.7 Disputes
1. `open_dispute` happy.
2. `add_dispute_event` por opener → row.
3. `add_dispute_event` por third-party non-reviewer → `permission_denied`.
4. `resolve_dispute(action='void_sanction')` → sanction.status='voided', system_event emitted.
5. `appeal_sanction` por non-target → `permission_denied`.

## N.8 Governance
1. `propose_decision` happy.
2. `start_vote` snapshots quorum + threshold.
3. `cast_vote` happy → vote_cast row.
4. `cast_vote` 2x mismo member → 2 rows; `vote_counts_view` cuenta el último.
5. `cast_vote` ranked_choice con rank=1,2,3 → 3 rows.
6. `cast_vote` ranked con rank duplicado mismo member → error `duplicate_rank`.
7. `finalize_vote` reached quorum + threshold → status=closed, outcome='passed', dispatcher invocado.
8. `finalize_vote` decision_type='rule_change' → `publish_rule_version` invocado.
9. `finalize_vote` no quorum → outcome='no_quorum', no dispatch.
10. `cancel_decision` por proposer → status='cancelled'.
11. Atom guard: UPDATE vote_casts → exception.

## N.9 Notifications
1. RPC enqueue → outbox row con idempotency UNIQUE.
2. Enqueue dup → no second row.
3. Cron drain happy → dispatched_at set.
4. Cron drain APNs failure → retry_count++, delivery_status='failed' tras 5 retries.

## N.10 Audit
1. `group_history_feed` returns UNION en orden cronológico.
2. Filter por `event_type` works.
3. RLS: cross-group → 0 rows.
4. Replay (V3): dry run no muta canónico, escribe a replay tabla.

## N.11 Cross-layer integration
1. **End-to-end**: founder publishes rule trigger `expense.recorded` IF amount>1000 THEN `issue_sanction:warning`. Member records expense $1500. Assert: 1 ledger entry, 1 system_event(expense.recorded), 1 evaluation(matched), 1 sanction issued, 1 ledger entry (sanction_assessed), 1 notification outbox row.
2. **Vote drives rule change**: propose decision_type=rule_change with new shape. Members cast yes. Finalize. Assert: new rule_version published, old version superseded, system_events for vote.finalized + rule.published.
3. **Membership state via decision**: propose decision_type=membership target=X state=expelled. Vote passes. Assert: `group_memberships.state='expelled'`, log row, notification to target.
4. **Race**: 2 concurrent `cast_vote` mismo member, same vote. Assert: both rows present in vote_casts; latest counts in view.

---

# CIERRE

Este documento es la traducción técnica de `GroupPrimitives.md` al backend real.

## Estado post-V2-G3 EPIC cerrado (commits `30efadce`→`6bb56c78`)
✅ G3.1 → G3.5 + polish. 6 migs (`060000`→`060500` + `20260529000000`). 427/427 tests RuulCore. **20 atoms** (8 triggers + 6 conditions + 6 consequences). 7 callsites cableados. 5 consequence handlers vivos (sync sanction, sync membership, sync pool_charge, sync start_vote, async notification). iOS Disparos feed accesible desde RulesListView toolbar.

**Pendiente menor** (no bloquea cierre G3, cae en V2-G8):
- Banner global "Sistema evaluó M reglas en últimas 24h" en `GroupHomeFeedView`.
- Sheet "¿Por qué pasó esto?" en eventos generados por engine.

## Siguiente foco (V2 restante)
1. **V2-G8 Engine-driven UX** (1-2 sesiones) — banner + "¿por qué pasó esto?" sheet + per-resource "qué reglas matchearon aquí".
2. **V2-G4 Sanction ↔ Money deep** (3-4 sesiones) — partial payments, payment plans, auto-pay from fund. Independent de G8.

Tras G4+G8 → tag `v2.0.0-rc` → pase V3 (consolidación / cleanup / launch + handler registry refactor antes de crecer catálogo > 20).

## Cambios diferidos (V3)
- Particionado mensual.
- Versionado governance + roles.
- Replay engine.
- Deprecación legacy tables.
- Notification preferences.

## NO implementar
- Comunicación, Incentivos, Cuidado como entidades.
- Federation, subgroups, AI agents (capas L.x).

## Naming canónico locked
- `group_*` tables, `record_*`/`issue_*`/`publish_*` RPCs, `<noun>.<past_verb>` events, `actor_id`/`member_id` distinction, mandate_id explicit precedence.
