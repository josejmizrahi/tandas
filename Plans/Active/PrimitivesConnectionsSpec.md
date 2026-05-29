# PrimitivesConnectionsSpec — Especificación técnica implementable

> Producido 2026-05-29 contra Supabase proyecto `ruul` (verificado vía MCP
> `mcp__supabase__execute_sql` + `list_tables` + `list_migrations` + `pg_catalog`).
> Cada afirmación sobre el estado actual está taggeada como **[V]** (Verificado),
> **[NV]** (No Verificado), **[F]** (Falta confirmado) o **[C]** (Conflicto BD-vs-doctrina).
>
> Fuentes:
> - Doctrina: `Plans/Active/GroupPrimitives.md` (25 primitivas).
> - Doc previo: `Plans/Active/PrimitivesArchitecture.md` (1933 líneas; FASE 0 ya documenta derivas).
> - BD real: 96 migraciones aplicadas (20260526191721 → 20260529192246).
> - Diff disco↔aplicado: 4 SQLs en disco sin aplicar (v2_g8/g4, ver §0.5).

---

## ÍNDICE

1. [FASE 0 — Inventario real](#fase-0--inventario-real)
2. [A) Arquitectura por capas](#a-arquitectura-por-capas)
3. [B) Dependency graph](#b-dependency-graph)
4. [C) Matriz de conexiones](#c-matriz-de-conexiones)
5. [D) Ownership model](#d-ownership-model)
6. [E) Event system canónico](#e-event-system-canónico)
7. [F) Rule engine completo](#f-rule-engine-completo)
8. [G) Money system](#g-money-system)
9. [H) Governance system](#h-governance-system)
10. [I) Disputes + consecuencias](#i-disputes--consecuencias)
11. [J) Memory / Audit](#j-memory--audit)
12. [K) Notifications](#k-notifications)
13. [L) Future-proofing](#l-future-proofing)
14. [M) Plan por partes (PARTE 0 — PARTE 12)](#m-plan-por-partes)
15. [N) Smoke tests](#n-smoke-tests)

---

# FASE 0 — INVENTARIO REAL

## 0.1 Schemas + extensions

**Schemas existentes [V]** (query: `SELECT nspname FROM pg_namespace`):
`auth`, `extensions`, `graphql`, `graphql_public`, `public`, `realtime`, `storage`, `supabase_migrations`, `vault`.

- **[F] Schema `ruul`** — no existe. Toda función "ruul.*" referida en `PrimitivesArchitecture.md` (~15 menciones: `ruul.dispatch_consequences`, `ruul.consequence_*`, `ruul.raise_immutable_atom`, `ruul.evaluate_condition_tree`, `ruul.rule_eval_depth`) es ficción doctrinal. Las funciones reales viven en `public` con prefijo `_*`. Doctrina forward: **no crear schema `ruul`**; mantener prefijo `_` en `public`.

**Extensions instaladas [V]** (query: `pg_extension`):
- `pgcrypto` 1.3 (en `extensions`) — `gen_random_uuid`.
- `uuid-ossp` 1.1 (en `extensions`).
- `pg_stat_statements` 1.11 (en `extensions`).
- `plpgsql` 1.0 (en `pg_catalog`).
- `supabase_vault` 0.3.1 (en `vault`).

**Extensions NO instaladas [F]** (relevantes):
- `pg_cron` — disponible pero no instalado. Todo job recurrente DEBE ser edge function con Supabase scheduler. La capa SQL solo expone RPCs (`emit_mandate_expiring_events()` etc.) que el scheduler invoca.
- `pg_net` — disponible pero no instalado. La capa SQL NO puede hacer HTTP. Si una consequence necesita web call → edge function.
- `pg_partman` — disponible pero no instalado. Particionado mensual de `group_events`/`group_resource_transactions` (mencionado en PrimitivesArchitecture.md §A.13 y §J.2) es ficción.
- `pgmq` — disponible pero no instalado. La queue de notificaciones es la tabla `notifications_outbox`, drenada por edge function.

## 0.2 Tablas en `public` (46 reales) [V]

> Conteo y descripciones verificados vía `mcp__supabase__list_tables` + `pg_catalog.pg_description`.

| Cluster | Tabla | Rows hoy | Comentario |
|---|---|---|---|
| Identity | `profiles` | 25 | Primitive 1 — 1:1 con `auth.users`. |
| Group | `groups` | 11 | Primitive 1/2/22 — jsonb `settings`, `decision_rules`, `roles_catalog`. |
| Group | `group_purposes` | 11 | Primitive 3 — multi-kind. |
| Membership | `group_memberships` | 27 | Primitives 1/2/15 — `status` + `membership_type`. |
| Membership | `group_membership_events` | 31 | Primitive 15 audit — append-only (atom guards activos). |
| Membership | `group_invites` | 18 | Primitive 15 entry. |
| Authority | `permissions` | 49 | Primitive 17 catálogo global, read-only. |
| Authority | `group_roles` | 29 | Primitive 5. |
| Authority | `group_role_permissions` | 549 | Primitive 17 bridge. |
| Authority | `group_member_roles` | 28 | Primitive 5/6 join. |
| Authority | `group_mandates` | 3 | Primitive 23. |
| Rules | `rule_shapes_catalog` | 19 | Primitive 4 — vocab. |
| Rules | `group_rules` | 9 | Primitive 4 — header mutable. |
| Rules | `group_rule_versions` | 13 | Primitive 4 — append-only snapshots. |
| Rules | `group_rule_evaluations` | 11 | Primitive 4 — append-only audit. |
| Resources | `group_resources` | 8 | Primitive 8/18 — envelope polimórfico. |
| Resources | `group_resource_events` | 0 | Subtype event. |
| Resources | `group_resource_funds` | 0 | Subtype fund. |
| Resources | `group_resource_slots` | 0 | Subtype slot. |
| Resources | `group_resource_spaces` | 0 | Subtype space. |
| Resources | `group_resource_assets` | 0 | Subtype asset. |
| Resources | `group_resource_asset_valuations` | 0 | Append-only valuation history. |
| Resources | `group_resource_rights` | 0 | Subtype right. |
| Resources | `group_resource_capabilities` | 0 | Per-resource feature toggles. |
| Resources | `group_resource_series` | 1 | Primitive 21 (Ritual) — recurrence + ritual_meaning. |
| Resources | `group_resource_bookings` | 0 | Append-only booking atom. |
| Resources | `group_rsvp_actions` | 0 | Append-only RSVP atom. |
| Resources | `group_check_in_actions` | 0 | Append-only check-in atom. |
| Money | `group_resource_transactions` | 36 | **Primitive 19 — ledger atom canónico**. Append-only. |
| Money | `group_obligations` | 23 | Primitive 19 — p2p/p2pool debt con identidad. |
| Money | `group_settlements` | 15 | Money 2.0 — settlement entity. |
| Money | `group_settlement_obligations` | 13 | Bridge settlement→obligations cerradas. |
| Money | `group_contributions` | 1 | Primitive 9 — non-monetary aportes. |
| Governance | `group_decisions` | 4 | Primitive 16/22 — proposal envelope. Realtime-published. |
| Governance | `group_decision_options` | 5 | Opciones discretas. |
| Governance | `group_votes` | 6 | Primitive 16 — append-only ballot (atom, no `vote_casts` separada). |
| Conflict | `group_sanctions` | 4 | Primitive 11. |
| Conflict | `group_disputes` | 4 | Primitive 14. Realtime-published. |
| Conflict | `group_dispute_events` | 10 | Append-only timeline. |
| Reputation | `group_reputation_events` | 21 | Primitive 12 — append-only, **sin score column**. |
| Culture | `group_cultural_norms` | 2 | Primitive 20 — opt-in. |
| Dissolution | `group_dissolutions` | 0 | Primitive 25. |
| Memory | `group_events` | 168 | **Primitive 13 — universal audit log**. `id bigint` cursor + `uuid_id` public. Realtime-published. |
| Notifications | `notification_tokens` | 0 | APNs tokens. |
| Notifications | `notification_preferences` | 0 | Per-(user,group,category,channel). |
| Notifications | `notifications_outbox` | 4 | Append-mostly (partial guard V3-A3a). |

## 0.3 Tablas declaradas en `PrimitivesArchitecture.md` que NO existen [C]

> Cada una es deriva doctrinal vs BD. Listar para que no se proponga ALTER sobre ellas.

| Tabla en doc | Realidad | Acción canónica |
|---|---|---|
| `ledger_entries` (~30 refs) | **No existe**. Atom es `group_resource_transactions`. | Renombrar en todo el doc o aceptar `ledger_entries` como alias semántico. **Doctrina forward**: `group_resource_transactions` es el nombre real. |
| `system_events` (~50 refs) | **No existe**. Atom es `group_events`. | Renombrar. FASE 0 del doc actual ya lo nota. |
| `vote_casts` (separada de `group_votes`) | **No existe**. Ballot atom = `group_votes` (con `seq` bigint + atom guards). | El modelo conceptual de "decision envelope + vote container + cast atom" colapsó en `group_decisions` + `group_votes`. |
| `group_decision_rules` (tabla) | **No existe** como tabla. Lógica en `groups.decision_rules jsonb` + RPC `group_decision_rules(p_group_id) returns jsonb`. | Mantener jsonb hasta que crezca > 20 keys. |
| `group_pool_charges` | **No existe**. Pool charges = `group_obligations.obligation_kind='pool_charge'` + `group_resource_transactions.transaction_type='pool_charge'`. | Polimórfico vía discriminator. OK. |
| `group_funds`, `group_assets`, `group_spaces`, `group_documents` | Reales son `group_resource_funds`, `group_resource_assets`, `group_resource_spaces`. `group_documents` **no existe**. | `documents` queda como FALTA. Otros = name drift. |
| `group_dispute_appeals` | **No existe**. Appeals modelan via `group_disputes(subject_kind='sanction', subject_id=sanction_id)`. | Mantener polimorfismo. |
| `group_membership_states_log` | **No existe**. Real es `group_membership_events`. | Name drift. |
| `group_ritual_occurrences`, `group_rituals` | **No existen**. Rituals = `group_resource_series.ritual_meaning + ritual_marker_kind`. | Rituals son metadata sobre resource series, no entidad propia. |
| `group_cultural_norm_endorsements` | **No existe**. Endorsements = `group_cultural_norms.endorsed_count integer` (incrementado por `endorse_norm`/`endorse_cultural_norm` RPCs). | Sin tabla de endorsements por miembro hoy. **[F]** Si se necesita auditabilidad per-endorser → ALTER add table. Hoy se pierde quién endorsó. |
| `group_resource_ownership_events` | **No existe**. Ownership transfer audit pasa por `group_events.event_type='resource.ownership_transferred'` (event_type que tampoco está emitido aún — ver §0.6). | **[F]** Histórico de ownership = derivable de `group_events` filtrado. |
| `group_governance_versions` | **No existe**. Cambios a `groups.decision_rules` no se versionan. | **[F]** Riesgo: cambia quórum sin audit. Acción V3 propuesta = append `group_governance_versions(group_id, snapshot, effective_from)`. Hoy NO existe. |
| `group_history_entries` | **No existe**. UI lee directo de `group_events` vía RPC `group_events_recent`. | Proyección amigable se hace client-side. OK. |
| `push_tokens` | Real es `notification_tokens`. | Name drift. |
| `templates` | **No existe**. La doctrina de templates (Plans/Active/Beta1*, V1) no llegó a tabla. RPCs `create_group` aceptan `p_category text` y `groups.settings` jsonb. | Templates son FALTA confirmado. No bloqueante para Foundation. |
| `modules` | **No existe**. Module registry vivía en V2 anterior; quedó muerto post-canonical reset. | Si V3 quiere modules dinámicos, primero tabla. Hoy = jsonb `groups.settings.active_modules` (no enforced). |

## 0.4 Columnas declaradas que NO existen / divergen [C]

| Declaración doc | Realidad BD | Evidencia |
|---|---|---|
| `groups.governance jsonb` | **No existe**. Reales: `settings`, `decision_rules`, `roles_catalog` (3 jsonb). | `information_schema.columns` query. |
| `group_decisions.status='closed'` | **No existe**. Estados: `draft`, `open`, `passed`, `rejected` (verificados con `SELECT DISTINCT status` y default `'draft'`). | Default `'draft'`; data observada: `open`, `passed`, `rejected`. |
| `group_obligations.due_at` | **No existe**. Columnas reales: `created_at, updated_at, status, amount_outstanding, source_*`. | Sin `due_at` → no se puede emitir `obligation.overdue` (V3-A4a deferred). |
| `group_events.processed_at` | **No existe**. Reales: `id (bigint), uuid_id, group_id, actor_user_id, event_type, entity_kind, entity_id, summary, payload, occurred_at, created_at`. | El modelo "marcar event como processed" no aplica — eval ya es síncrona inline. |
| `group_events.idempotency_key` con UNIQUE per (group_id, event_type) | **No existe**. La idempotencia vive en `group_rule_evaluations.idempotency_key` UNIQUE global. | El event no tiene idempotency; el atom que lo origina (transactions/votes/etc.) sí, vía `client_id`. |
| `group_rule_evaluations.verdict text` | **No existe**. Outcome se infiere de `matched bool` + `cycle_detected bool` + `matched_predicate.passed` + `actions_emitted[].status`. | Decisión real explicada en PrimitivesArchitecture.md §F.1.4. |
| `group_rule_evaluations.trigger_event_id` | **No existe** como column propio. Usa `source_event_id uuid` (FK lógica a `group_events.uuid_id`). | Verificado. |
| `group_rule_evaluations.rule_id` | **No existe**. Se deriva por JOIN `group_rule_versions.rule_id`. | Verificado. |
| `notifications_outbox.{kind,target_member_id,source_event_id,scheduled_for,delivery_status,retry_count,last_retry_at}` | Reales: `recipient_user_id, category, payload jsonb, dispatch_status, attempts, last_error, dispatched_at`. | El partial guard V3-A3a opera sobre las reales. |

## 0.5 Migraciones aplicadas vs en disco [V/C]

**Aplicadas en BD [V]** (query: `supabase_migrations.schema_migrations`):
- 96 migraciones desde `20260526191721 canonical_reset` hasta `20260529192246 v3_a4b_emit_mandate_expiring_events` (inventario inicial).
- **+5 aplicadas 2026-05-29 (PARTE 1 + PARTE 2)**:
  - `20260529202136 v2_g8_1_rule_evaluation_summary_rpc` — disk file `20260529010000_…sql` (fix drift `m.state`→`gm.status`).
  - `20260529203115 v2_g8_2_system_event_engine_provenance` — disk file `20260529020000_…sql` sin drift.
  - `20260529203228 v2_g4_1_sanction_payment_status_rpc` — disk file `20260529030000_…sql` sin drift.
  - `20260529203312 v2_g4_2_sanction_payment_plans` — disk file `20260529040000_…sql` (fix drift signature `record_system_event`: 5 args posicionales → named arg con `p_payload =>`).
  - `20260529203431 v3_parte1_profiles_rls_self_or_co_member` — disk file homónimo (PARTE 1: drop `profiles_select_authenticated`, create policy self-or-co-member).
- **+3 aplicadas 2026-05-29 (PARTE 3 — gaps puros)**:
  - `20260529204001 v3_parte3_1_emit_role_granted_event` — `assign_role_to_member` ahora emite `role.granted` a `group_events`.
  - `20260529204002 v3_parte3_2_emit_role_revoked_event` — `revoke_role_from_member` ahora emite `role.revoked` a `group_events`.
  - `20260529204003 v3_parte3_3_emit_dispute_event_added` — `append_dispute_event` ahora emite `dispute.event_added` a `group_events` (sin tocar el atom privado `group_dispute_events`).
- **+1 aplicada 2026-05-29 (PARTE 5b — leave_group balance guard)**:
  - `20260529205001 v3_parte5b_leave_group_balance_guard` — `leave_group` ahora asserta `member_balance_in_group=0` antes de delegar a `set_membership_state`. Path de expulsión admin queda intacto (gap doctrinal: la función no cuenta obligations donde el miembro es `owed_to`).
- **+2 aplicadas 2026-05-29 (PARTE 7 — governance versioning)**:
  - `20260529210001 v3_parte7_a_group_governance_versions_table` — nuevo atom append-only `group_governance_versions` (id, group_id, snapshot jsonb, effective_from, effective_until, set_by, source_decision_id). UNIQUE partial index "una versión activa por grupo". Partial atom guard solo permite mutar `effective_until`. Atom no-delete guard.
  - `20260529210002 v3_parte7_b_set_decision_rules_writes_version` — ambas overloads (legacy 4-arg + modern 6-arg) ahora cierran versión previa (`effective_until=now()`) + insertan nueva fila + augmentan payload de `decision_rules.set` con `version_id` para reverse-link. `source_decision_id` queda NULL en path admin directo; lo llevará el handler `governance_change` de `finalize_vote` cuando PARTE 4 aterrice.

**Smokes PARTE 7 verdes** (5/5):
- 2 calls consecutivos → 2 versions, primera con `effective_until` cerrado, segunda activa ✓
- UPDATE snapshot directo → bloqueado (partial guard) ✓
- DELETE directo → bloqueado (atom no-delete) ✓
- Eventos `decision_rules.set` carry `version_id` (reverse-link a snapshot) ✓
- INSERT paralelo activo → bloqueado por UNIQUE partial index ✓

- **+1 aplicada 2026-05-29 (PARTE 5a — pay_sanction sugar)**:
  - `20260529212001 v3_parte5a_pay_sanction_sugar_rpc` — RPC self-party `pay_sanction(sanction_id, amount, unit?, client_id?)` que delega a `record_settlement` con paid_to_kind='pool'. Resuelve target_membership server-side, valida outstanding, rechaza over-pay (evita ledger orphans). Mandate path se mantiene via `record_settlement` directo. Smokes 5/5: non-target rechazado ✓ / partial $100/$300 ✓ / over-pay rechazado ✓ / pay-to-zero cascadea sanction→completed ✓ / pay sanción cerrada rechazado ✓.

- **+1 aplicada 2026-05-29 (PARTE 8 — notifications dedup + retention)**:
  - `20260529213001 v3_parte8_notifications_dedup_and_retention` — (a) UNIQUE partial index `(group_id, category, payload->>'idempotency_key')` WHERE `payload ? 'idempotency_key'`; opt-in para emisores. (b) `_notifications_outbox_no_delete` relajado: DELETE permitido solo cuando `dispatched_at IS NOT NULL AND < now() - 30d`. Permite retention cron sin bypass RLS. Smokes 7/7: insert con key OK ✓ / duplicado mismo key+cat bloqueado por UNIQUE ✓ / mismo key + cat distinto libre ✓ / sin key libre 2x ✓ / DELETE undispatched bloqueado ✓ / DELETE dispatched=5d bloqueado ✓ / DELETE dispatched=60d permitido ✓.

- **+1 aplicada 2026-05-29 (PARTE 8b — security hardening por advisor)**:
  - `20260529214001 v3_parte8b_security_hardening` — closeout para Supabase advisor: (i) ALTER FUNCTION ... SET search_path='public' en 4 trigger fns (3 míos + `_group_decisions_partial_guard`). (ii) REVOKE EXECUTE FROM anon, public + GRANT EXECUTE TO authenticated en cada SECURITY DEFINER de public (defensa-en-profundidad además del `auth.uid() IS NULL` interno). (iii) REVOKE EXECUTE FROM authenticated en 7 internas (`_smoke_money_flow`, `_rule_eval_predicate/dispatch`, `_resolve_authority_path`, `_assert_mandate_authorizes`, `_auto_promote_norm_internal`, `_check_norm_promotion_threshold`) que son postgres-only. Resultado: anon=0 / authenticated=129 (mismo que pre-mig) / internals expuestos=0. Smokes: `my_profile()` desde authenticated OK ✓, anon bloqueado con 42501 ✓, `_smoke_money_flow()` desde authenticated bloqueado ✓.

**Re-audit §0.6 post-PARTE 3**: el catálogo "eventos declarados pero NO emitidos" era parcialmente falso. Lo único que faltaba realmente eran las 3 RPCs zero-emit ya cerradas. Los demás (`dispute.escalated`, `rule.published`, `mandate.granted/revoked`, `money.transaction_reversed`, `dissolution.proposed/finalized`, `resource.ownership_changed`, `dispute.resolved`) **ya están en código** — solo no aparecen en data dev porque no se han ejercido en tests. **Doctrinales pendientes (no slices mecánicos)**:
- `sanction.paid` vs `sanction.completed` actual: `update_sanction_status` emite `sanction.<new_status>` dinámico (`sanction.completed/reversed/cancelled`); el doc pide `sanction.paid` separado. Decisión: ¿rename `completed` → `paid` cuando origen es settlement? ¿O emit alias?
- `mandate.used`: no hay emisor; el FK guard `assert_mandate_authorizes` corre por cada uso pero no emite. ¿Vale la inflación del log?
- `member.left` vs `member.expelled` vs el actual `member.state_changed`: ¿split por motivo o mantener un solo event con `new_state` en payload?

**Resultado**:
- BD vivo: 101 migs.
- 4 disk files `20260529010000-040000` quedan idempotentes (CREATE OR REPLACE / IF NOT EXISTS) — futuros `supabase db reset` los re-aplican sin error.
- Memoria `project_v2_release_rc.md` queda **corregida** por esta entrada: las 4 G8/G4 migs ahora SÍ están aplicadas.

**Drift histórico documentado y corregido pre-apply**:
- g8.1: `m.state` → `gm.status`. El SQL en disco fue escrito cuando la columna se llamaba `state`; el schema canónico la renombró a `status` en `00001_canonical_schema.sql`.
- g4.2: `record_system_event(uuid, text, text, uuid, jsonb)` → named args. Real signature: `(p_group_id, p_event_type, p_entity_kind, p_entity_id, p_summary text, p_payload jsonb)` — el SQL en disco omitía `p_summary` y pasaba el jsonb en posición 5 (sin coerción → "function does not exist").

**Smokes verdes 2026-05-29**:
- `group_rule_evaluation_summary(group_id, 24*365*5)` → `{evaluations_count:9, has_failures:true, window_hours:43800, last_evaluated_at:<ts>}`.
- `system_event_engine_provenance(event_uuid)` → graceful `{found:false, reason:'event_type_not_engine_actionable'}` cuando el payload legacy no incluye `sanction_id`.
- `group_sanction_payment_status(sanction_id)` → shape completo con `payments[]` hidratado vía `paid_by_display_name`.
- `group_sanction_payment_plan_active(sanction_id)` → `{active:false}` correcto en sanciones sin plan; tabla + 3 funcs + 2 indexes + 1 policy creados.
- RLS profiles: N.1.1 self ✓ / N.1.2 isolated_other bloqueado ✓ / N.1.3 co_member visible ✓ / N.1.4 anon=0 ✓. `group_members` RPC sigue hidratando display_name (SECURITY DEFINER bypassea RLS).

## 0.6 Catálogo de event_type real en `group_events` [V]

> Query: `SELECT DISTINCT event_type, COUNT(*) FROM group_events GROUP BY event_type`. 31 tipos observados en producción dev.

| event_type | n | Notas |
|---|---|---|
| `boundary_policy.updated` | 3 | |
| `contribution.logged` | 1 | (no `contribution.recorded` — name drift vs doc) |
| `cultural_norm.endorsed` | 1 | trigger para auto-promote (V3-A2). |
| `cultural_norm.promoted_to_rule` | 1 | (no `cultural_norm.promoted`) |
| `cultural_norm.proposed` | 2 | |
| `cultural_norm.retired` | 1 | |
| `decision_rules.set` | 1 | |
| `decision.finalized` | 2 | |
| `decision.started` | 4 | (no `decision.proposed` ni `decision.vote_started` — uno solo) |
| `decision.vote_cast` | 6 | |
| `dispute.opened` | 4 | |
| `dispute.resolved` | 3 | |
| `group.created` | 9 | |
| `group.visibility_updated` | 2 | |
| `mandate.granted` | 3 | |
| `mandate.revoked` | 3 | |
| `member.invited` | 18 | |
| `member.joined` | 17 | |
| `member.state_changed` | 3 | |
| `money.expense_recorded` | 30 | (no `expense.recorded` — name drift) |
| `money.settlement_recorded` | 15 | (no `settlement.completed`) |
| `purpose.set` | 9 | |
| `resource_series.created` | 1 | |
| `resource_series.updated` | 2 | |
| `resource.archived` | 4 | |
| `resource.created` | 8 | |
| `role.created` | 1 | (no `role.granted`/`role.revoked` — solo created) |
| `role.permissions_updated` | 1 | |
| `rule.archived` | 2 | |
| `rule.created` | 6 | (no `rule.published`/`rule.proposed` separados) |
| `sanction.issued` | 5 | |

**Eventos declarados en doc que NO se emiten [F]**:
- `expense.recorded`, `settlement.completed`, `pool_charge.created`, `payout.recorded`, `transaction.reversed` (todos `money.*` reales o no emitidos).
- `decision.proposed`, `decision.vote_started`, `decision.cancelled`.
- `dispute.event_added`, `dispute.escalated`.
- `member.profile_updated`, `member.left`, `member.expelled` (solo `state_changed`).
- `role.granted`, `role.revoked`, `permission.granted`, `permission.revoked`.
- `mandate.used`.
- `rule.published`, `rule.evaluated` (rule.created sí emite; eval no aparece como event_type — vive en `group_rule_evaluations` directamente).
- `resource.ownership_transferred`.
- `sanction.paid`, `sanction.voided`, `sanction.appealed`.
- `contribution.verified` (RPC `verify_contribution` la emite — verificar). [NV — el código del RPC dice que sí; data dev podría no tener trigger todavía].
- `reputation.event_recorded`.
- `ritual.occurred`.

## 0.7 RPCs públicas verificadas (135 funciones contadas en `pg_proc`) [V]

> Snapshot del scan. Lista parcial canónica más arriba en este archivo; completa en `pg_proc` query.

**Confirmadas vivas** (subconjunto crítico):
- Identity: `my_profile()`, `update_my_profile(p_display_name, p_username, p_avatar_url, p_bio)`, `handle_new_auth_user()` (trigger), `delete_and_export_my_data()`.
- Group: `create_group(p_name, p_slug, p_category, p_purpose_declared)`, `group_summary(p_group_id)`, `group_foundation_status(p_group_id)`, `list_my_groups()`, `set_group_visibility(p_group_id, p_visibility)`, `group_visibility(p_group_id)`.
- Membership: `invite_member`, `accept_invite`, `request_membership`, `confirm_provisional`, `set_membership_state`, `leave_group`, `set_group_boundary_policy`, `group_boundary_policy`, `group_membership_boundary`, `group_members`.
- Purpose: `set_group_purpose`, `archive_group_purpose`, `group_purposes_active`.
- Authority: `assert_permission`, `assert_member_of_group`, `has_group_permission`, `is_group_member`, `list_permissions_catalog`, `list_member_permissions`, `list_group_roles`, `create_custom_role`, `update_role_permissions`, `assign_role_to_member`, `revoke_role_from_member`.
- Mandates: `grant_mandate`, `revoke_mandate`, `report_on_mandate`, `group_mandates_active`, `emit_mandate_expiring_events`.
- Rules: `list_rule_shapes`, `validate_rule_shape`, `create_text_rule`, `create_engine_rule`, `propose_rule`, `publish_rule_version`, `archive_rule`, `promote_norm_to_rule`, `propose_norm`, `endorse_norm`, `retire_norm`, `propose_cultural_norm`, `endorse_cultural_norm`, `retire_cultural_norm`, `group_rules_active`, `group_rules_engine`, `group_cultural_norms_active`, `evaluate_rules_for_event`, `group_rule_evaluations`.
- Internals (`_`-prefixed): `_rule_eval_predicate`, `_rule_eval_dispatch`, `_resolve_authority_path`, `_assert_mandate_authorizes`, `_auto_promote_norm_internal`, `_check_norm_promotion_threshold` (trigger), `_group_decisions_partial_guard` (trigger), `_notifications_outbox_partial_guard` (trigger), `_notifications_outbox_no_delete` (trigger), `_smoke_money_flow` (test fixture), `atom_no_mutation_guard` (trigger generic), `atom_no_delete_guard` (trigger generic), `assert_*_same_group` (FK guards), `assert_resource_type` (subtype guard), `set_updated_at` (trigger generic).
- Resources: `create_resource`, `create_group_resource`, `update_resource`, `archive_resource`, `revert_archive_resource`, `set_resource_ownership`, `record_asset_valuation`, `create_resource_series`, `update_resource_series`, `list_group_resource_series`, `group_resources_active`, `enable_resource_capability`, `disable_resource_capability`.
- Bookings/RSVP/check-in: `book_resource`, `cancel_booking`, `submit_rsvp`, `submit_check_in`, `mark_no_show`.
- Money: `record_expense`, `record_contribution`, `verify_contribution`, `record_non_monetary_contribution`, `log_contribution`, `record_settlement`, `record_pool_charge`, `record_payout`, `reverse_transaction`, `member_balance_in_group`, `member_obligation_summary`, `group_money_movements`, `group_contributions_active`.
- Sanctions: `issue_sanction`, `update_sanction_status`, `dispute_sanction`, `group_sanctions_active`.
- Decisions: `start_vote`, `cast_vote` (2 overloads), `cast_ranked_vote`, `finalize_vote`, `cancel_vote`, `decision_detail`, `list_decisions_active`, `list_decisions_history`, `set_decision_rules` (2 overloads), `group_decision_rules`, `current_vote_for`, `current_votes_for_decision`.
- Disputes: `open_dispute`, `append_dispute_event`, `assign_mediator`, `record_dispute_resolution`, `escalate_dispute_to_vote`, `dispute_sanction`, `dispute_detail`, `list_dispute_events`, `group_disputes_active`.
- Reputation: `record_reputation_event`, `retract_reputation_event`, `member_reputation_events`, `group_reputation_events`.
- Dissolution: `propose_dissolution`, `approve_dissolution`, `finalize_dissolution`, `record_liquidation_step`, `group_dissolution_active`.
- Memory: `record_system_event` (inserta a `group_events`), `group_events_recent`.
- Notifications: `register_my_notification_token`, `set_notification_preference`, `my_notification_preferences`.

**RPCs declaradas en doc pero NO existen [F]**:
- `pay_sanction`, `void_sanction`, `start_appeal`, `finalize_fine_reviews`, `issue_manual_fine`, `appeal_sanction` (toda la familia "fine" legacy).
- `propose_decision` (la propuesta hoy se hace inline con `start_vote`).
- `record_consent_objection` (consent objection se modela vía `cast_vote` con choice especial).
- `simulate_rule_eval` (dry-run no implementado).
- `replay_rule_evaluations` (replay no implementado).
- `enqueue_notification` (la cola se llena via inline INSERT en RPCs de dominio, no via función).
- `rule_evaluation_summary` (v2_g8_1 SQL en disco pendiente).
- `sanction_payment_status`, `propose_payment_plan` (v2_g4_1/2 SQL en disco pendiente).
- `create_mandate` (real es `grant_mandate`; name drift).
- `transfer_ownership` (real es `set_resource_ownership` + flow manual).
- `create_role`, `grant_role`, `revoke_role` (reales: `create_custom_role`, `assign_role_to_member`, `revoke_role_from_member`).
- `add_dispute_event` (real es `append_dispute_event`).
- `escalate_dispute` (real es `escalate_dispute_to_vote`).
- `resolve_dispute` (real es `record_dispute_resolution`).
- `remove_member` (real es `set_membership_state(p_membership_id, 'expelled', reason)`).

## 0.8 Triggers verificados [V]

> Query: `information_schema.triggers WHERE trigger_schema='public'`. 70+ triggers.

**Atom guards canónicos** (full = `atom_no_mutation_guard` BEFORE UPDATE + `atom_no_delete_guard` BEFORE DELETE):
- `group_events`, `group_resource_transactions`, `group_rule_evaluations`, `group_check_in_actions`, `group_rsvp_actions`, `group_dispute_events`, `group_reputation_events`, `group_resource_asset_valuations`, `group_settlement_obligations`, `group_membership_events`, `group_votes`.

**Atom guards parciales** (mutación permitida solo en columns específicas):
- `group_rule_versions` — `effective_until` mutable.
- `group_reputation_events` — `status, visibility` mutables (override del listado "full" anterior; verifica reputación retract).
- `group_resource_bookings` — `status, reason, metadata` mutables.
- `notifications_outbox` — `dispatch_status, attempts, last_error, dispatched_at` mutables (V3-A3a).
- `group_decisions` — bloquea mutación material si OLD.status ∈ (`passed`, `rejected`); `updated_at` libre (V3-A3b).

**FK / cross-group guards**:
- `assert_member_role_same_group` en `group_member_roles` (INSERT + UPDATE).
- `assert_mandate_same_group` en `group_resource_transactions` y `group_settlements` (INSERT + UPDATE).
- `assert_source_mandate_same_group` en `group_obligations` (INSERT + UPDATE).
- `assert_settlement_obligation_same_group` en `group_settlement_obligations` (INSERT).
- `assert_resource_type('<subtype>')` en cada subtype table — fuerza `group_resources.resource_type = '<subtype>'`.

**Lifecycle triggers**:
- `set_updated_at` BEFORE UPDATE en todas las tablas mutables (`groups`, `group_memberships`, `group_purposes`, `group_resources` y subtypes, `group_resource_series`, `group_resource_capabilities`, `group_rules`, `group_mandates`, `group_disputes`, `group_dissolutions`, `group_obligations`, `group_settlements`, `group_sanctions`, `group_decisions`, `group_cultural_norms`, `notification_preferences`, `profiles`).
- `_check_norm_promotion_threshold` AFTER UPDATE OF `endorsed_count` en `group_cultural_norms` (V3-A2 auto-promote).

## 0.9 RLS posture [V]

> Query: `pg_policies WHERE schemaname='public'`. ~95 policies activas. RLS ENABLED en todas las 46 tablas públicas.

**Patrón canónico**:
- `*_select_members` — SELECT permitido si caller es member activo del grupo.
- `*_select_visible` — SELECT amplía a respect `visibility` column (members vs públicos del grupo).
- `*_insert_permission` — INSERT delegado a `assert_permission(group_id, '<perm>')` inline.
- `*_update_permission` — UPDATE igual.
- `*_select_via_parent` — subtype tables heredan visibilidad del envelope (`group_resources`).
- Atoms (append-only) tienen SOLO `*_select_*` policies; writes pasan obligatoriamente por SECURITY DEFINER RPCs.

**Casos especiales verificados**:
- `profiles_select_authenticated` — **[C]** todo authenticated puede leer todos los profiles. La doctrina del doc dice "phone/email solo via self"; en la realidad `profiles` tiene columns `phone` y otras que SÍ son visibles cross-tenant a authenticated. **Acción recomendada**: revisar policy y restringir cross-group leaks; documentar columnas safe.
- `group_rule_evaluations_select_admin` — SOLO admin del grupo lee evaluations. Restricción correcta.
- `group_disputes_select_involved_or_records` — disputas solo visibles a partes involucradas o role con `dispute.records` permission.
- `group_invites_select_visible` — invites visibles al invitador, invitado, y admins.
- `notifications_outbox_select_self` — solo recipient lee la fila.
- `permissions_select_anyone` — catalog público.
- `rule_shapes_catalog_select_anyone` — catalog público.

## 0.10 Índices clave verificados [V]

| Tabla | Index | Función |
|---|---|---|
| `group_events` | `(group_id, created_at DESC, id DESC)` | feed paginado. |
| `group_events` | `(entity_kind, entity_id)` | reverse-lookup por entidad. |
| `group_events` | `UNIQUE (uuid_id)` | join estable via uuid. |
| `group_memberships` | `UNIQUE (group_id, user_id)` | invariant. |
| `group_memberships` | partial `(group_id, user_id) WHERE status='active'` | hot path. |
| `group_resource_transactions` | `UNIQUE (group_id, client_id)` | **idempotency real**. |
| `group_resource_transactions` | `UNIQUE (seq)` global | cursor FIFO. |
| `group_resource_transactions` | `(group_id, seq)` | feed paginado. |
| `group_resource_transactions` | `(mandate_id) WHERE NOT NULL` | mandate audit. |
| `group_resource_transactions` | `(source_entity_kind, source_entity_id)` | reverse-lookup. |
| `group_rule_evaluations` | `UNIQUE (idempotency_key)` | retry-safe. |
| `group_rule_evaluations` | `(group_id, created_at DESC)` | feed. |
| `group_rule_evaluations` | `(parent_evaluation_id)` | depth chain walk. |
| `group_obligations` | partial `(owed_by_membership_id) WHERE status IN ('open','partially_settled')` | hot path balance. |
| `group_settlements` | `UNIQUE (group_id, client_id)` | idempotency. |
| `group_votes` | `(decision_id, voter_membership_id, seq DESC)` | DISTINCT ON `current_vote_for`. |
| `notifications_outbox` | partial `(dispatch_status) WHERE dispatch_status='pending'` | cron drain. |

## 0.11 Constraints / FKs notables [V]

- `group_memberships UNIQUE (group_id, user_id)` — un user, una membership por grupo.
- `group_obligations.amount_outstanding` debe ser `≤ amount_original` (no check verificado; **[NV]**).
- `group_rule_evaluations.depth >= 0 AND <= 5` — declarado en doc; **[NV]** debe verificarse el CHECK constraint.
- `group_resource_transactions` polimórfico via `(source_entity_kind, source_entity_id)` — sin FK, validación a nivel de RPC.

## 0.12 Veredicto del inventario

| Pregunta del brief | Respuesta |
|---|---|
| ¿Primitivas ya definidas? | 22/25 con entidad en BD; 3 sin entidad (Comunicación, Incentivos, Cuidado) — diferidas por doctrina. |
| ¿Relaciones existentes? | Sí, `group_id` + `*_membership_id` + polimórfico `(entity_kind, entity_id)` consolidados. |
| ¿Inconsistencias detectadas? | Drift masivo entre nombres en doc (`ledger_entries`, `system_events`, `vote_casts`, `group_funds`, etc.) y nombres reales. La FASE 0 del doc actual lista las críticas. |
| ¿Duplicados? | 0 críticos. `group_decisions` + `group_votes` NO son duplicados. |
| ¿Huérfanas? | 3 (Comunicación, Incentivos, Cuidado) — diferir, sin entidad propia hoy. |
| ¿Sobrecargadas? | `groups.settings/decision_rules/roles_catalog` cargan ~25 keys cada uno. Vigilar growth. |
| ¿Implementado vs conceptual? | Foundation (22 primitivas) IMPLEMENTADO. Rule engine, money, votes, disputes, dissolution = vivos. Faltan: simulate, replay, payment plans, sanction payment status RPC, rule eval summary RPC, mandate.used event, audit ownership transfer. |
| ¿Naming inconsistencies? | `member_id` vs `membership_id` (forward: `*_membership_id`). `actor_id` vs `actor_user_id` (forward: `actor_user_id` para FK a `auth.users`; `*_membership_id` para identidad dentro del grupo). `kind` vs `type` (predominante `kind`). |
| ¿Dependencias circulares peligrosas? | Engine recursion mitigado (depth 5 + cycle detection in `_rule_eval_predicate`). Vote outcome handlers NO emiten eventos que disparen votos nuevos (frontera engine vs voto preservada por catálogo, no por código). |
| ¿Problemas RLS/authority? | `profiles_select_authenticated` permite leer profiles cross-tenant. **Acción**: restringir columnas sensibles o cambiar a `select_self_or_group_member`. |
| ¿Append-only correctos? | Sí, atoms críticos guardados. Faltaba `group_decisions` partial — agregado V3-A3b. |
| ¿Versionado? | Solo `group_rules` → `group_rule_versions`. NO `groups.decision_rules`. NO `group_roles`. NO `permissions_catalog` (immutable seed). |

---

# A) ARQUITECTURA POR CAPAS

> 12 capas. Cada primitiva vive en exactamente una capa primaria. La numeración referencia GroupPrimitives.md.

## A.1 Identity layer

| Item | Detalle |
|---|---|
| Primitivas | #1 (Personas / Members). |
| Tablas | `auth.users` (Supabase), `profiles`. |
| RPCs | `my_profile()`, `update_my_profile(...)`, `delete_and_export_my_data()`. |
| Triggers | `handle_new_auth_user()` (lo aplica `auth.users`, mira mig 23 followup), `profiles_set_updated_at`. |
| Ownership | `auth.uid() = profiles.id` — self. |
| Invariantes | `profiles.id = auth.users.id` (1:1). Phone único cuando no null. |
| Boundaries | NO group_id. Cross-tenant by design. |
| Modifica | `display_name`, `username`, `avatar_url`, `bio`. |
| NO modifica | `id`, `created_at`, `phone` (solo via auth sync). |
| Append-only? | NO (mutable lifecycle). |
| Riesgos | RLS leak (ver 0.9). |
| Estado | **[V] LIVE**. |

## A.2 Group layer

| Item | Detalle |
|---|---|
| Primitivas | #1 group identity, #3 purpose (root), #22 legitimacy (root), #25 dissolution. |
| Tablas | `groups`, `group_purposes`, `group_dissolutions`. |
| RPCs | `create_group`, `set_group_purpose`, `archive_group_purpose`, `set_group_visibility`, `group_visibility`, `group_summary`, `group_foundation_status`, `propose_dissolution`, `approve_dissolution`, `finalize_dissolution`, `record_liquidation_step`. |
| Ownership | `groups.created_by` + primer admin via memberships. |
| Invariantes | `slug` único cuando no null; `dissolved_at IS NOT NULL` → bloquea writes (enforced en RPCs, **[NV]** trigger global). |
| Versionado | **[F]** `groups.decision_rules` jsonb no versionado. |
| Modifica | `name, description, purpose_summary, visibility, status, category, settings, decision_rules, roles_catalog, archived_at, dissolved_at`. |
| NO modifica | `id, slug` (post-set), `created_by`, `created_at`. |
| Riesgos | Governance change retroactivo. Mitigación: snapshot quorum/threshold en `group_decisions` al `start_vote`. |
| Estado | **[V] LIVE** (foundation status RPC verificado). |

## A.3 Membership layer

| Item | Detalle |
|---|---|
| Primitivas | #1 quality of belonging, #2 boundary, #15 entry/exit. |
| Tablas | `group_memberships`, `group_invites`, `group_membership_events`. |
| RPCs | `invite_member`, `accept_invite`, `request_membership`, `confirm_provisional`, `set_membership_state`, `leave_group`, `set_group_boundary_policy`, `group_boundary_policy`, `group_membership_boundary`, `group_members`. |
| Estados verificados | `status`: defaults `'active'`; observed `active`, otros via `set_membership_state`. `membership_type`: defaults `'member'`. |
| Invariantes | `UNIQUE (group_id, user_id)` — un user, una membership viva. |
| Append-only | `group_membership_events` SÍ (atom guards). |
| Modifica | `status, membership_type, title, provisional_until, confirmed_at, suspended_until, suspended_reason, left_at, left_reason, joined_via, turn_order, metadata`. |
| Riesgos | Balance pendiente al salir. **[F]** RPC `leave_group` no bloquea hoy si `member_balance_in_group != 0`. Acción: agregar guard. |
| Estado | **[V] LIVE**. |

## A.4 Authority layer

| Item | Detalle |
|---|---|
| Primitivas | #5 roles, #6 power/authority, #17 permissions, #23 representation. |
| Tablas | `permissions`, `group_roles`, `group_role_permissions`, `group_member_roles`, `group_mandates`. |
| RPCs | `assert_permission`, `has_group_permission`, `is_group_member`, `assert_member_of_group`, `list_permissions_catalog`, `list_member_permissions`, `list_group_roles`, `create_custom_role`, `update_role_permissions`, `assign_role_to_member`, `revoke_role_from_member`, `grant_mandate`, `revoke_mandate`, `report_on_mandate`, `group_mandates_active`, `emit_mandate_expiring_events`, `_resolve_authority_path`, `_assert_mandate_authorizes`. |
| Authority precedence | `mandate > self_party > direct_permission` — locked. Helper `_resolve_authority_path` decide ruta. |
| Triggers | `group_member_roles_same_group`, `group_mandates_set_updated_at`. |
| Versionado | **[F]** `group_roles.permission_keys` cambios no versionados. Append `group_role_versions` queda para V3. |
| Riesgos | Mandate expirado usado → mitigation: `_assert_mandate_authorizes` valida `revoked_at IS NULL AND (ends_at IS NULL OR ends_at > now())`. |
| Estado | **[V] LIVE** + V3-A4b emisor `mandate.expiring_in_24h` shipped. |

## A.5 Rules layer

| Item | Detalle |
|---|---|
| Primitivas | #4 reglas/normas, #20 culture (via promote_norm_to_rule). |
| Tablas | `rule_shapes_catalog` (vocab), `group_rules` (header), `group_rule_versions` (snapshots), `group_rule_evaluations` (audit), `group_cultural_norms` (proposed norm path). |
| RPCs | `list_rule_shapes`, `validate_rule_shape`, `create_text_rule`, `create_engine_rule`, `propose_rule`, `publish_rule_version`, `archive_rule`, `propose_norm`, `endorse_norm`, `retire_norm`, `promote_norm_to_rule`, `propose_cultural_norm`, `endorse_cultural_norm`, `retire_cultural_norm`, `group_rules_active`, `group_rules_engine`, `group_cultural_norms_active`, `evaluate_rules_for_event`, `group_rule_evaluations`, `_rule_eval_predicate`, `_rule_eval_dispatch`, `_auto_promote_norm_internal`. |
| Atoms append-only | `group_rule_versions` (partial: `effective_until` only), `group_rule_evaluations` (full guard). |
| Catálogo vivo | 19 shapes: 8 triggers + 6 conditions + 5 consequences. Ver §F.4 para enumeración exacta. |
| Versionado | YES — `group_rule_versions` con `version int` + UNIQUE active (informal). **[NV]** verificar `UNIQUE INDEX one_active_per_rule WHERE status='active'`. |
| Invariantes | `group_rule_evaluations.idempotency_key UNIQUE` global. `depth <= 5`. |
| Riesgos | Loop eval. Shape inválido (mitigation: `validate_rule_shape` server-side antes de commit). |
| Estado | **[V] LIVE** post-G3 (mig serie `20260528192916`-`20260528211259`). |

## A.6 Event layer (event sourcing)

| Item | Detalle |
|---|---|
| Primitivas | #13 memoria, root para rule engine. |
| Tablas | `group_events` (universal audit, NO `system_events`). |
| RPCs | `record_system_event(p_group_id, p_event_type, p_entity_kind, p_entity_id, p_summary, p_payload)` — SECURITY DEFINER. `group_events_recent(p_group_id, p_limit, p_before)`. |
| Schema real | `id bigint` (monotonic cursor, NO gapless), `uuid_id uuid` (stable public), `group_id`, `actor_user_id`, `event_type`, `entity_kind`, `entity_id`, `summary`, `payload jsonb`, `occurred_at`, `created_at`. |
| Atom | Full guards: `group_events_atom_guard` BEFORE UPDATE, `group_events_no_delete` BEFORE DELETE. |
| Invariantes | `payload jsonb` default `'{}'`. Sin `processed_at` ni `idempotency_key` propios — el evaluator usa `source_event_id = uuid_id`. |
| Idempotency | A nivel del evento NO. A nivel de eval, `group_rule_evaluations.idempotency_key` (formato `eval:<event_uuid>:<rule_version_id>`). |
| Riesgos | Crecimiento sin partición. **[F]** pg_partman no instalado; particionado manual queda para V3 si > 5M rows. |
| Estado | **[V] LIVE** + realtime publication (`mig 20260527235000`). |

## A.7 Money layer

| Item | Detalle |
|---|---|
| Primitivas | #19 contabilidad, #8 resources (subtype fund), #9 contribuciones. |
| Tablas | `group_resource_transactions` (atom canónico), `group_obligations` (p2p debt), `group_settlements`, `group_settlement_obligations` (bridge), `group_contributions` (non-monetary), `group_resource_funds` (subtype). |
| RPCs | `record_expense`, `record_contribution`, `verify_contribution`, `log_contribution` (non-monetary), `record_non_monetary_contribution`, `record_settlement`, `record_pool_charge`, `record_payout`, `reverse_transaction`, `record_asset_valuation`, `member_balance_in_group`, `member_obligation_summary`, `group_money_movements`, `group_contributions_active`. |
| Atom | `group_resource_transactions` con full guards + `mandate_same_group` FK guard. |
| Tri-role | Columnas: `from_membership_id`, `to_membership_id`, `paid_by_membership_id`, `recorded_by`. |
| Idempotency | `UNIQUE (group_id, client_id)` en `group_resource_transactions` y `group_settlements`. |
| Reversal | `reverse_transaction` inserta nuevo entry con `reversed_entry_id = original.id`. NUNCA UPDATE. |
| Obligations | `status` ∈ `open|partially_settled|settled|void` (defaults `open`). Sin `due_at` column. |
| Settlements | `status` defaults `initiated`. Cierran obligations FIFO vía `group_settlement_obligations`. |
| Riesgos | Doble pago si retry sin `client_id`. Mitigation: `client_id` requerido en producción (NULL permitido pero no idempotente). |
| Estado | **[V] LIVE**. V3-S1 Splitwise picker shipped (memoria 2026-05-29). |

## A.8 Resource layer

| Item | Detalle |
|---|---|
| Primitivas | #8 recursos, #18 propiedad, #21 ritual (via series). |
| Tablas | `group_resources` (envelope), subtypes: `group_resource_events`, `group_resource_funds`, `group_resource_slots`, `group_resource_spaces`, `group_resource_assets`, `group_resource_asset_valuations`, `group_resource_rights`. Capacities: `group_resource_capabilities`. Recurrence: `group_resource_series`. Bookings: `group_resource_bookings`. Actions: `group_rsvp_actions`, `group_check_in_actions`. |
| RPCs | `create_resource`, `create_group_resource` (envelope-only legacy), `update_resource`, `archive_resource`, `revert_archive_resource`, `set_resource_ownership`, `record_asset_valuation`, `create_resource_series`, `update_resource_series`, `list_group_resource_series`, `group_resources_active`, `enable_resource_capability`, `disable_resource_capability`, `book_resource`, `cancel_booking`, `submit_rsvp`, `submit_check_in`, `mark_no_show`. |
| Ownership | `ownership_kind` ∈ `group|member|role` (defaults `group`), `owner_membership_id` cuando member. |
| Subtype enforcement | Triggers `assert_resource_type('<subtype>')` BEFORE INSERT/UPDATE en cada subtype table. |
| Atoms append-only | `group_resource_asset_valuations`, `group_resource_bookings` (partial guard), `group_rsvp_actions`, `group_check_in_actions`. |
| Riesgos | Subtype row sin envelope; archive con balance > 0 (fund). |
| Estado | **[V] LIVE**. |

## A.9 Governance layer

| Item | Detalle |
|---|---|
| Primitivas | #16 decisiones, #22 legitimidad. |
| Tablas | `group_decisions`, `group_decision_options`, `group_votes` (es el atom + envelope colapsado), `groups.decision_rules jsonb` (per-group config). |
| RPCs | `start_vote`, `cast_vote` (overload con weight), `cast_ranked_vote`, `finalize_vote`, `cancel_vote`, `decision_detail`, `list_decisions_active`, `list_decisions_history`, `set_decision_rules` (overload), `group_decision_rules`, `current_vote_for`, `current_votes_for_decision`, `escalate_dispute_to_vote`. |
| Estados decisión | `draft|open|passed|rejected` (real). NO `closed`/`cancelled`/`open_for_vote` como el doc decía. |
| Atom | `group_votes` con `seq bigint` monotonic + `atom_no_mutation_guard` + `atom_no_delete_guard`. Múltiples casts permitidos por miembro mientras decision está `open`; counting via DISTINCT ON `(decision_id, voter_membership_id) ORDER BY seq DESC`. |
| Atom partial | `group_decisions` con `_group_decisions_partial_guard` (bloquea mutación material si OLD.status terminal). |
| Quorum/threshold | Snapshot en `group_decisions.quorum_pct` + `threshold_pct` al `start_vote`. NO se recalculan. |
| Weighted/ranked | `group_votes.weight numeric default 1`. Ranked vía `cast_ranked_vote` que inserta múltiples rows con metadata. |
| Outcome handlers | `finalize_vote` ramifica por `decision_type` ∈ `membership` (mig 20260528173934), `rule_change` (mig 20260528175113), `pool_charge` (mig 20260528180224). Otros types TBD. |
| Mandate en votos | `cast_vote` NO acepta `p_mandate_id` — voting non-delegable. **[V]** verificado en signature. |
| Estado | **[V] LIVE** (8 methods + 11 decision_types declarados; verificar exhaustividad de handlers post-G2). |

## A.10 Conflict layer

| Item | Detalle |
|---|---|
| Primitivas | #14 conflictos. |
| Tablas | `group_disputes`, `group_dispute_events`. |
| RPCs | `open_dispute`, `append_dispute_event`, `assign_mediator`, `record_dispute_resolution`, `escalate_dispute_to_vote`, `dispute_sanction`, `dispute_detail`, `list_dispute_events`, `group_disputes_active`. |
| Lifecycle | `status` defaults `open`. Verificado: `open`, transitions via mediator/resolution. Sin enum CHECK explícito en BD; **[NV]** validar transitions en RPC. |
| Atom | `group_dispute_events` con full guards. |
| Polimorfismo | `subject_kind` + `subject_id` apunta a sanction/decision/rule/resource/member_behavior. |
| Mediación | `mediator_membership_id` (set via `assign_mediator`). Realtime-published. |
| Appeals | Modeladas como `group_disputes(subject_kind='sanction')`, NO tabla separada. |
| Cascadas | `record_settlement_cascades_to_linked_sanctions` (mig 20260528050718) — cerrar sanción al settle. `dispute_resolution_releases_sanction_status` (mig 20260528052112) — resolver dispute libera sanction `paid/voided`. |
| Estado | **[V] LIVE**. |

## A.11 Memory layer

Ver §A.6. La memoria canónica es `group_events` + `group_reputation_events` + proyecciones derivables.

## A.12 Notification layer

| Item | Detalle |
|---|---|
| Primitivas | #7 comunicación (parcial — solo capa outbound). |
| Tablas | `notifications_outbox`, `notification_tokens`, `notification_preferences`. |
| RPCs | `register_my_notification_token`, `set_notification_preference`, `my_notification_preferences`. |
| Atom partial | `notifications_outbox` con `_notifications_outbox_partial_guard` (solo `dispatch_status, attempts, last_error, dispatched_at` mutables) + `_notifications_outbox_no_delete` (V3-A3a). |
| Cron | **[F]** edge function `dispatch-notifications-every-minute` declarada en CLAUDE.md global; NO verificable desde SQL. Asumir externo. |
| Idempotency | Sin UNIQUE constraint declarada en BD; dedup vía `category + payload.idempotency_key` (jsonb) — **[NV]** depende de la capa enqueue. |
| Estado | **[V] LIVE** + V3-A3 partial guard shipped. |

## A.13 Matriz por capa

| Layer | Foundation? | Dependents | Append-only atoms | Versionado | Soft-delete |
|---|---|---|---|---|---|
| Identity | core | Membership, all writes | — | — | NO |
| Group | core | Todo group-scoped | — | **[F]** governance versions | `dissolved_at` |
| Membership | core | Authority, Money, Votes | `group_membership_events` | — | `status=left/expelled` |
| Authority | core | Toda RPC | — | **[F]** role versions | mandate `revoked_at` |
| Rules | core | Engine eval | `group_rule_versions` (partial), `group_rule_evaluations` (full) | versions immutable | rule `status=archived` |
| Event | core | Toda audit + engine | `group_events` (full) | — | NUNCA |
| Money | high | Sanctions, Settlements | `group_resource_transactions` (full), `group_settlement_obligations` (full), `group_resource_asset_valuations` (full) | — | NUNCA |
| Resource | high | Money (funds), Bookings | `group_resource_bookings` (partial), `group_rsvp_actions` (full), `group_check_in_actions` (full) | — | `archived_at` |
| Governance | high | Rules, Money, Membership | `group_votes` (full), partial `group_decisions` (terminal) | — | NO (terminal terminal) |
| Conflict | medium | Sanctions, Membership | `group_dispute_events` (full) | — | — |
| Memory | core | TODA proyección | `group_events`, `group_reputation_events` (partial: status/visibility) | — | NUNCA |
| Notification | low | Cross-layer outbound | `notifications_outbox` (partial) | — | drop > N días (manual) |

---

# B) DEPENDENCY GRAPH

```
profiles                          (Identity, atomic)
   ↓
groups                            (Group tenant root)
   ↓
group_memberships                 ← group_invites
   ↓
   ├→ group_roles, group_role_permissions, permissions
   ├→ group_member_roles (join)
   ├→ group_mandates                       (Authority delegation)
   ├→ group_reputation_events              (Reputation atom; partial guard)
   ├→ group_resource_transactions          (Money atom: from/to/paid_by/recorded_by)
   ├→ group_obligations                    (Money debt with identity)
   ├→ group_settlements                    (Money settlement entity)
   ├→ group_votes                          (Governance atom; voter_membership_id)
   ├→ group_rsvp_actions, group_check_in_actions, group_resource_bookings  (Resource interactions)
   ├→ group_sanctions                      (Conflict; target, issuer)
   ├→ group_disputes                       (Conflict; opener, respondent, mediator)
   ├→ group_resources                      (Property; owner_membership_id)
   ├→ group_membership_events              (Lifecycle audit)
   └→ group_dissolutions                   (Dissolution actor)

groups.decision_rules jsonb       (Governance config; per-group)

group_resources                   ← group_memberships (owner)
   ↓
   ├→ group_resource_events       (subtype: event)
   ├→ group_resource_funds        (subtype: fund / pool / protected pool)
   ├→ group_resource_slots        (subtype: slot)
   ├→ group_resource_spaces       (subtype: space)
   ├→ group_resource_assets       (subtype: asset)
   │    ↓
   │    group_resource_asset_valuations (append-only)
   ├→ group_resource_rights       (subtype: right)
   ├→ group_resource_capabilities (per-resource feature toggles)
   ├→ group_resource_series       (recurrence + ritual_meaning — Ritual primitive)
   ├→ group_resource_bookings     (booking atom)
   ├→ group_resource_transactions (source_resource_id; money contextualizado)
   └→ group_rsvp_actions, group_check_in_actions

rule_shapes_catalog               (global vocab, immutable seed)
   ↓
group_rules                       ← group_cultural_norms (promote_norm_to_rule, trigger auto-promote V3-A2)
   ↓
group_rule_versions               (append-only snapshots; partial guard on effective_until)
   ↓
group_rule_evaluations            (append-only audit; full guard)
   ↑  parent_evaluation_id ─┐
   └────────────────────────┘ (recursion chain, depth ≤ 5)
   ↑
   └─ disparado por: record_system_event() → evaluate_rules_for_event(p_event_uuid_id, 'sync')

group_events                      (Memory atom — universal append-only)
   ↑
   └ INSERT vía record_system_event(...) por toda RPC mutante
   ↓ (sync, dentro de la misma TX)
   ├→ evaluate_rules_for_event    (rule engine entry)
   │     ↓
   │     _rule_eval_predicate
   │     ↓ (match)
   │     _rule_eval_dispatch
   │      ├→ issue_sanction       (sync, recursive trigger eval)
   │      ├→ set_membership_state (sync)
   │      ├→ record_pool_charge   (sync)
   │      ├→ start_vote (propose_decision + start_vote) (sync — engine→voto bridge)
   │      └→ insert into notifications_outbox (async)
   └→ (no projection table; UI lee via group_events_recent RPC)

group_decisions                   ← group_memberships (proposed_by)
   ↓
group_decision_options
   ↓
group_votes                       (append-only atom; weight + seq)
   ↓ (finalize_vote)
   ├→ outcome handler per decision_type:
   │    ├→ membership handler   (mig 20260528173934) → set_membership_state
   │    ├→ rule_change handler  (mig 20260528175113) → publish_rule_version → group_rule_versions
   │    ├→ pool_charge handler  (mig 20260528180224) → record_pool_charge
   │    └→ [F] otros decision_types — sin handlers explícitos hoy (rule_book/sanction_appeal/budget/resource_change/governance_change/dissolution/cultural_norm_promotion/purpose_change/free_form)
   └→ record_system_event('decision.finalized')

group_sanctions                   ← group_rules (rule_version_id, NULL si manual)
   ↓ FK
   ├→ source_event_id → group_events.uuid_id
   ├→ dispute_id → group_disputes
   └→ obligation_id → group_obligations
   ↑ status mutado vía update_sanction_status, dispute_sanction
   ↓ side effects de issue_sanction:
   ├→ record_reputation_event (mig 20260528201454 line ~82-89: rule_violation o commitment_broken)
   ├→ record_system_event('sanction.issued')
   └→ evaluate_rules_for_event(...)

group_resource_transactions       (Money atom)
   ↑ Insert vía:
   ├ record_expense
   ├ record_contribution
   ├ record_settlement (con bridge group_settlement_obligations FIFO)
   ├ record_pool_charge
   ├ record_payout
   ├ reverse_transaction
   └ (futuro) pay_sanction
   ↓ side effects:
   ├→ group_obligations.amount_outstanding (decrementa cuando settle)
   ├→ group_events ('money.expense_recorded', 'money.settlement_recorded')
   └→ evaluate_rules_for_event(...)

group_disputes                    ← group_sanctions, group_decisions, group_resources
   ↓
   ├→ group_dispute_events (atom)
   ├→ escalated_decision_id → group_decisions
   └→ record_system_event ('dispute.opened', 'dispute.resolved')

group_mandates                    ← group_memberships
   ↓ usado por:
   └→ record_expense, record_contribution, record_settlement, record_pool_charge, record_payout, issue_sanction (todas como `p_mandate_id`)

notifications_outbox              ← inline INSERT en RPCs + dispatcher en _rule_eval_dispatch
   ↓
   └→ APNs vía edge function (externa)
```

## B.1 Reglas duras del grafo (locked)

1. **Toda escritura group-scoped** carga `group_id` + `actor_user_id` (auth.uid()) + opcionalmente `mandate_id`.
2. **Toda RPC de dominio mutante** termina con `record_system_event(...)` que inserta a `group_events`.
3. **`evaluate_rules_for_event(uuid_id, 'sync')`** se llama EN LA MISMA TX, post-insert del atom + group_event, pre-commit. Verificado en 7 callsites (`record_expense`, `record_settlement`, `record_pool_charge`, `issue_sanction`, `set_membership_state`, `open_dispute`, `finalize_vote`).
4. **Outcome handlers de votos** son sync inline; no via cron. Solo 3 implementados (membership, rule_change, pool_charge); 8 decision_types más sin handler.
5. **`notifications_outbox` writes** son ASYNC (no bloquean commit); edge function drena.
6. **Mandate-aware RPCs validan scope** ANTES de mutar; mandate inválido raise `permission_denied:<perm>`, nunca fallback.
7. **Recursion guard**: `_rule_eval_predicate`/`_rule_eval_dispatch` reciben `depth int`; abort si `>= 5`. Cycle detection vía `parent_evaluation_id` chain.
8. **Atoms NUNCA se mutan** salvo columnas explícitas en partial guards.

---

# C) MATRIZ DE CONEXIONES

> Una fila por primitiva canónica. Estado entre corchetes.

### C.1 Members / Identity (#1)
- **Depende**: `auth.users`.
- **Alimenta**: TODO writer (actor_user_id, recorded_by).
- **Eventos emitidos**: ninguno hoy en `group_events` (profile updates son cross-tenant; no group_id). **[F]** Si se quiere audit, agregar `member.profile_updated` por grupo donde el user es member.
- **Eventos escuchados**: ninguno.
- **Permisos clave**: ninguno (self).
- **Tablas**: `profiles`.
- **RPCs**: `my_profile`, `update_my_profile`, `delete_and_export_my_data`.
- **Estado**: **[V] LIVE**.
- **Riesgos**: `profiles_select_authenticated` permite leak cross-tenant.
- **Edge cases**: phone change requiere re-verify OTP; GDPR delete = anonymize, keep id.

### C.2 Memberships / Boundary (#2, #15)
- **Depende**: Identity, Group.
- **Alimenta**: Authority, Money, Votes, Sanctions, Disputes, Reputation.
- **Eventos**: emite `member.invited` (18 en data), `member.joined` (17), `member.state_changed` (3), `member.left` (**[F]** no emitido directo; `leave_group` debe emitir `member.left` o `member.state_changed`), `member.expelled` (**[F]** no emitido).
- **Escucha**: `decision.finalized` con `decision_type='membership'` → mutar estado.
- **Permisos**: `member.invite`, `member.expel`, `membership.suspend`, `membership.activate`.
- **Tablas**: `group_memberships`, `group_invites`, `group_membership_events`.
- **RPCs**: `invite_member`, `accept_invite`, `request_membership`, `confirm_provisional`, `set_membership_state`, `leave_group`.
- **Estado**: **[V] LIVE**.
- **Riesgos**: balance pendiente al salir; **[F]** sin guard hoy.
- **Edge cases**: provisional → active automático en `provisional_until` reached (**[F]** edge function pendiente); reinvite a expelled requiere permission separada.

### C.3 Purpose (#3)
- **Depende**: Group.
- **Alimenta**: lectura UI.
- **Eventos**: `purpose.set` (9 en data). NO emite `purpose.changed`.
- **Permisos**: `purpose.set` (vía role).
- **Tablas**: `group_purposes` (multi-kind).
- **RPCs**: `set_group_purpose`, `archive_group_purpose`, `group_purposes_active`.
- **Estado**: **[V] LIVE**.
- **Edge cases**: múltiples kinds simultáneos (declared/operative/emotional).

### C.4 Rules (#4)
- **Depende**: Group, `rule_shapes_catalog`, `group_cultural_norms` (opcional).
- **Alimenta**: Engine eval, Sanctions (auto-issue), Notifications, Pool charges, Votes (bridge).
- **Eventos emitidos**: `rule.created` (6), `rule.archived` (2). **[F]** `rule.published` no emitido como event_type separado — el create_engine_rule consolida.
- **Escucha**: `cultural_norm.endorsed` con `endorsed_count >= threshold` (V3-A2 trigger). **[F]** Engine no escucha sus propios `rule.archived` (correcto).
- **Permisos**: `rules.create`, `rules.publish`, `rules.archive`.
- **Tablas**: `group_rules`, `group_rule_versions`, `group_rule_evaluations`, `rule_shapes_catalog`.
- **RPCs**: ver §A.5.
- **Estado**: **[V] LIVE** post-G3.
- **Riesgos**: loop eval (mitigado), shape inválido (mitigado), rule con `effective_from` futuro (**[NV]** verificar en evaluator query).
- **Edge cases**: rule archived mid-eval — eval termina (idempotency); rule re-publish = nueva version.

### C.5 Roles (#5)
- **Depende**: Group, Memberships, `permissions`.
- **Alimenta**: Authority (permission resolution).
- **Eventos**: `role.created` (1), `role.permissions_updated` (1). **[F]** `role.granted/revoked` por miembro no emitidos.
- **Permisos**: `roles.create`, `roles.grant`, `roles.revoke`, `roles.edit`.
- **Tablas**: `group_roles`, `group_role_permissions`, `group_member_roles`.
- **RPCs**: `create_custom_role`, `update_role_permissions`, `assign_role_to_member`, `revoke_role_from_member`, `list_group_roles`.
- **Estado**: **[V] LIVE**.
- **Edge cases**: revocar último admin — **[F]** RPC no bloquea; agregar guard.

### C.6 Power / Authority (#6)
Combinación de Roles + Permissions + Mandates (C.5 + C.7 + C.15).

### C.7 Permissions (#17)
- **Depende**: `permissions` catalog (49 rows), Roles, Memberships.
- **Alimenta**: TODA RPC con `assert_permission`.
- **Eventos**: ninguno hoy. **[F]** `permission.granted/revoked` no emitidos.
- **Permisos**: `permissions.grant`, `permissions.revoke`.
- **Tablas**: `permissions` (catalog), `group_role_permissions` (bridge). NO hay tabla de direct member-level permissions hoy (toda asignación pasa por rol).
- **RPCs**: `assert_permission`, `has_group_permission`, `list_permissions_catalog`, `list_member_permissions`, `update_role_permissions`.
- **Estado**: **[V] LIVE**.
- **Edge cases**: catalog drift — `permissions` table es seed; cambiar requiere mig.

### C.8 Resources (#8) + Property (#18)
- **Depende**: Group, Memberships.
- **Alimenta**: Money (funds), Bookings, Series, RSVPs.
- **Eventos**: `resource.created` (8), `resource.archived` (4), `resource_series.created` (1), `resource_series.updated` (2). **[F]** `resource.ownership_transferred` no emitido.
- **Permisos**: `resources.create`, `resources.archive`, `resources.transfer`, `resources.configure`.
- **Tablas**: ver §A.8.
- **RPCs**: ver §A.8.
- **Estado**: **[V] LIVE**.
- **Edge cases**: archive fund con balance > 0 — **[F]** sin guard; transfer asset con valuation pendiente.

### C.9 Contributions (#9)
- **Depende**: Memberships, Money.
- **Alimenta**: Reputation (verify path), Member balance.
- **Eventos**: `contribution.logged` (1 — name drift vs `contribution.recorded` del doc). **[V]** `contribution.verified/rejected` emitidos por `verify_contribution` (V3-A1).
- **Permisos**: ninguno self-record (registrar ≠ aprobar doctrine); `contributions.verify` para verify-by-other.
- **Tablas**: `group_contributions` (non-monetary), `group_resource_transactions` con `transaction_type='contribution'`.
- **RPCs**: `record_contribution`, `log_contribution`, `record_non_monetary_contribution`, `verify_contribution`.
- **Estado**: **[V] LIVE** + V3-A1 verify shipped.
- **Edge cases**: in-kind contribution; verify by self bloqueado en RPC.

### C.10 Sanctions (#11)
- **Depende**: Rules (rule_version_id opt), Memberships (target), Money (linked obligation).
- **Alimenta**: Disputes (appeal), Money, Reputation.
- **Eventos**: `sanction.issued` (5). **[F]** `sanction.paid`, `sanction.voided`, `sanction.appealed` no emitidos como tales — usar `dispute_sanction` y `record_settlement` para cerrar cascada.
- **Escucha**: `rule.evaluated` con `consequence.issue_sanction` → auto-issue.
- **Permisos**: `sanctions.create`, `sanctions.void`, `sanctions.review`, `sanctions.payment_plan`.
- **Tablas**: `group_sanctions`, link con `group_obligations` via `obligation_id`.
- **RPCs**: `issue_sanction`, `update_sanction_status`, `dispute_sanction`, `group_sanctions_active`. **[F]** `pay_sanction`, `void_sanction`, `start_appeal`, `propose_payment_plan` no existen (los SQL están en disco pero no aplicados).
- **Estado**: **[V] LIVE** parcial; payment plans + payment status RPC = **[C]** SQL en disco sin aplicar.
- **Edge cases**: sanción duplicada (mitigada por idempotency engine); partial payment (en SQL pendiente); auto-pay from fund (V3 deferred).

### C.11 Reputation (#12)
- **Depende**: Memberships.
- **Alimenta**: UI display; futuro Incentivos.
- **Eventos**: NO emite event_type a `group_events` por sí mismo. Los `record_reputation_event` insertan a `group_reputation_events` (atom).
- **Escucha**: `sanction.issued` → cableado inline en `issue_sanction` (mig 20260528201454). `contribution.verified` → cableado inline en `verify_contribution` (V3-A1).
- **Permisos**: `reputation.record`.
- **Tablas**: `group_reputation_events` (partial guard: `status, visibility` mutables; resto inmutable).
- **RPCs**: `record_reputation_event`, `retract_reputation_event`, `member_reputation_events`, `group_reputation_events`.
- **Estado**: **[V] LIVE**.
- **Edge cases**: NO score column — UI lista eventos directo.

### C.12 Memory (#13)
- **Depende**: TODO.
- **Alimenta**: Engine, UI history, audit.
- **Eventos**: ES el sink. 31 event_types observados (§0.6).
- **Permisos**: ninguno user-facing; RPC SECURITY DEFINER.
- **Tablas**: `group_events`.
- **RPCs**: `record_system_event` (DEFINER), `group_events_recent`.
- **Estado**: **[V] LIVE** + realtime.
- **Riesgos**: crecimiento sin bound; **[F]** sin partición.

### C.13 Disputes (#14)
- **Depende**: Memberships, Sanctions/Decisions/Rules/Resources (subject polimórfico).
- **Alimenta**: Sanctions (resolution releases), Membership (escalate → vote).
- **Eventos**: `dispute.opened` (4), `dispute.resolved` (3). **[F]** `dispute.event_added`, `dispute.escalated` no emitidos como event_type.
- **Escucha**: ninguno (user-initiated).
- **Permisos**: `disputes.open`, `disputes.mediate`, `disputes.escalate`, `disputes.resolve`.
- **Tablas**: `group_disputes`, `group_dispute_events`.
- **RPCs**: ver §A.10.
- **Estado**: **[V] LIVE** + realtime.
- **Riesgos**: appeal sobre sanción pagada — mitigation parcial vía `record_settlement_cascades_to_linked_sanctions`.

### C.14 Decisions (#16)
- **Depende**: Memberships, `groups.decision_rules` config.
- **Alimenta**: Rules (rule_change), Membership (membership), Pool charges, Mandates (futuro), Sanctions appeal (futuro).
- **Eventos**: `decision.started` (4), `decision.vote_cast` (6), `decision.finalized` (2), `decision_rules.set` (1).
- **Escucha**: nothing inbound (user-initiated) + `start_vote` consequence del engine.
- **Permisos**: `decisions.create`, `decisions.start_vote`, `decisions.finalize`, `decisions.cancel`.
- **Tablas**: `group_decisions`, `group_decision_options`, `group_votes`.
- **RPCs**: ver §A.9.
- **Estado**: **[V] LIVE** post-G2 (8 vote methods + 11 decision_types catalogados; 3 handlers vivos).
- **Edge cases**: ranked_choice tie, consent objection bloquea, weighted vote con weight snapshot, governance change mid-vote (mitigado por snapshot).

### C.15 Mandates / Representation (#23)
- **Depende**: Memberships, `permissions` catalog (scope keys).
- **Alimenta**: Money RPCs (`p_mandate_id`), Sanctions, Decisions (propose).
- **Eventos**: `mandate.granted` (3), `mandate.revoked` (3). V3-A4b emite `mandate.expiring_in_24h` vía `emit_mandate_expiring_events()` cron-callable.
- **Escucha**: ninguno.
- **Permisos**: `mandates.grant`, `mandates.revoke`.
- **Tablas**: `group_mandates`.
- **RPCs**: ver §A.4.
- **Estado**: **[V] LIVE**.
- **Edge cases**: mandate expirado en uso → raises; mandate cross-group bloqueado por trigger `assert_mandate_same_group` en transactions + settlements.

### C.16 Money / Accounting (#19) — ver §G
### C.17 Property (#18) — ver §A.8 + C.8
### C.18 Cultural Norms / Culture (#20)
- **Depende**: Memberships.
- **Alimenta**: Rules (auto-promote via V3-A2).
- **Eventos**: `cultural_norm.proposed` (2), `cultural_norm.endorsed` (1), `cultural_norm.promoted_to_rule` (1), `cultural_norm.retired` (1).
- **Escucha**: ninguno; el trigger `_check_norm_promotion_threshold` dispara auto-promote cuando `endorsed_count >= groups.settings.cultural_norm_auto_promote_threshold`.
- **Permisos**: `cultural_norms.propose`, `cultural_norms.endorse`, `cultural_norms.retire`.
- **Tablas**: `group_cultural_norms`. **[F]** Sin tabla de endorsers per miembro (sólo counter).
- **RPCs**: ver §A.5.
- **Estado**: **[V] LIVE** + V3-A2 shipped.
- **Riesgos**: norm promovida conflict con rule existente — sin guard hoy.

### C.19 Rituals (#21)
- **Modela como**: `group_resource_series.ritual_meaning + ritual_marker_kind`. **NO tabla propia**.
- **RPCs**: `create_resource_series` (con ritual fields), `update_resource_series`, `list_group_resource_series(p_group_id, p_rituals_only)`.
- **Estado**: **[V] LIVE**.

### C.20 Legitimacy (#22)
- **Modela como**: `group_decisions.legitimacy_source text` (sin CHECK enum verificado en BD; valores reales observados: `majority` default + más vía `set_decision_rules`).
- **No-entidad propia**.

### C.21 Dissolution (#25)
- **Depende**: Memberships, Resources, Money.
- **Alimenta**: `groups.dissolved_at`.
- **Eventos**: ninguno emitido en `group_events` con prefijo `dissolution.*` en data observada. **[NV]** verificar RPC behavior.
- **Escucha**: `decision.finalized` con `decision_type='dissolution'` (**[F]** handler no implementado en BD post-G2; verificar).
- **Permisos**: `dissolution.propose`, `dissolution.approve`, `dissolution.finalize`.
- **Tablas**: `group_dissolutions`.
- **RPCs**: `propose_dissolution`, `approve_dissolution`, `finalize_dissolution`, `record_liquidation_step`, `group_dissolution_active`.
- **Estado**: **[V] LIVE** (RPCs presentes, 0 rows en data).
- **Riesgos**: balances no-cero al disolver — **[F]** sin guard.

### C.22 Notifications (#7 derivado)
Ver §K.

### C.23 Boundary policy (sub-primitiva de #2/#15)
- **Eventos**: `boundary_policy.updated` (3).
- **Tablas**: `groups.settings.boundary_policy` jsonb.
- **RPCs**: `set_group_boundary_policy`, `group_boundary_policy`.

### C.24 Comunicación / Incentivos / Cuidado (#7, #10, #24)
- **Estado**: deferred. No entidad propia. Posibles derivaciones:
  - Comunicación → outbox + canal externo (Slack/WhatsApp bridge futuro).
  - Incentivos → projection sobre `group_reputation_events` + behavior signals.
  - Cuidado → projection sobre `group_events.actor_user_id` agregado.

---

# D) OWNERSHIP MODEL CANÓNICO

## D.1 Tenancy

| Nivel | Scope | Tablas |
|---|---|---|
| Global | Catálogos shared | `auth.users`, `profiles`, `permissions`, `rule_shapes_catalog` |
| Group-scoped | Por `group_id` | TODA `group_*` table + atoms relacionados |
| User-scoped | Por `user_id` / `recipient_user_id` | `notification_tokens`, `notification_preferences`, `notifications_outbox` |

## D.2 Regla dura RLS (locked)

```sql
USING (
  group_id IN (
    SELECT group_id FROM group_memberships
    WHERE user_id = auth.uid()
      AND status IN ('active','provisional')
  )
)
```
Aplicado a TODAS las tablas group-scoped excepto donde se restringe más (e.g. `group_rule_evaluations` solo admin, `group_disputes` solo partes involucradas).

## D.3 Cascades

| Parent | Child | Política |
|---|---|---|
| `groups.dissolved_at` set | Tablas group-scoped | NO CASCADE; check en RPCs (no-write post-dissolve). Audit data viva. |
| `group_memberships` delete | NUNCA delete. `status='left'/'expelled'`. Atoms con `membership_id` mantienen FK. |
| `group_rules.status='archived'` | `group_rule_versions` viven; engine no las evalúa (filtra por `r.status='active'`). |
| `group_resources.archived_at` set | Subtypes viven; reads filtran. |
| `group_decisions.status` terminal | `group_votes` viven (atom). Partial guard bloquea mutación de decision material. |
| `profiles` delete | NUNCA delete. GDPR = anonymize fields, keep id + memberships. |

## D.4 Authority inheritance (D-4 lock)

```
Member action requires permission P.
1. Si p_mandate_id IS NOT NULL:
   1.1 Verificar mandate vivo (status='active' AND revoked_at IS NULL AND (ends_at IS NULL OR ends_at > now())).
   1.2 Verificar mandate.scope contiene P. Si no → permission_denied:<P>.
   1.3 Verificar mandate.group_id = action.group_id (FK guard).
   1.4 OK con authority_path='mandate'.
2. Si actor es self-party (record_expense self, settle_self, cast_own_vote, etc.) → OK authority_path='self_party'.
3. Else assert_permission(actor, group, P):
   3.1 JOIN group_member_roles + group_role_permissions + permissions.
   3.2 OK authority_path='direct_permission'.
   3.3 Else → permission_denied:<P>.
```

**Locked**: mandates NO encadenan (`mandate(A→B)` no permite a B usar otro mandate para C). NO mandate inference.

## D.5 Archival semantics

| Tabla | Archive col | Recovery |
|---|---|---|
| `groups` | `dissolved_at` | NUNCA un grupo se "des-disuelve". |
| `group_memberships` | `status` enum | sí (expelled → active via reinvite). |
| `group_rules` | `status='archived'` | sí, vía nueva version active. |
| `group_rule_versions` | partial guard solo `effective_until` | NO mutable. |
| `group_resources` | `archived_at` | sí, vía `revert_archive_resource`. |
| `group_decisions` | partial guard si terminal | NO mutable, terminal. |
| `notifications_outbox` | (futuro) drop > N días | NO recovery. |

## D.6 Cross-group isolation

- RPCs SECURITY DEFINER set `LOCAL ROLE` y filtran por `group_id` explícitamente.
- Mandate cross-group bloqueado por `assert_mandate_same_group`.
- Role assignment cross-group bloqueado por `assert_member_role_same_group`.
- Settlement obligations cross-group bloqueadas por `assert_settlement_obligation_same_group`.

---

# E) EVENT SYSTEM CANÓNICO

## E.1 Naming (locked)

`<noun>.<past_verb>` siempre past tense. **Excepción**: events de dominio money llevan prefijo `money.*` (`money.expense_recorded`, `money.settlement_recorded`). Mantener este prefijo — está en data observada.

## E.2 Catálogo verificado

> 31 event_types observados en data. Lista canónica de los **emitidos hoy**.

| event_type | Emisor (RPC) | Payload keys obligatorias | Sync rule eval? | Side effects async | Persistencia |
|---|---|---|---|---|---|
| `group.created` | `create_group` | `group_id`, `created_by`, `name`, `category` | NO (no rules) | enqueue welcome (futuro) | `group_events` permanente |
| `group.visibility_updated` | `set_group_visibility` | `group_id`, `old`, `new` | NO | NONE | permanente |
| `member.invited` | `invite_member` | `group_id`, `invitee_email_or_phone`, `invited_by`, `invite_id` | NO | enqueue email/sms (externo) | permanente |
| `member.joined` | `accept_invite` o `request_membership` (approved) | `group_id`, `membership_id`, `user_id`, `via_invite_id` | YES | notify admins | permanente |
| `member.state_changed` | `set_membership_state`, `leave_group` (vía esta) | `group_id`, `membership_id`, `from_state`, `to_state`, `reason` | YES | notify member | permanente |
| `purpose.set` | `set_group_purpose` | `group_id`, `kind`, `body`, `set_by` | NO | notify (opt) | permanente |
| `boundary_policy.updated` | `set_group_boundary_policy` | `group_id`, policy snapshot | NO | NONE | permanente |
| `decision_rules.set` | `set_decision_rules` | `group_id`, `default_style`, `quorum_min`, `default_method`, `legitimacy_source` | NO | NONE | permanente |
| `role.created` | `create_custom_role` | `group_id`, `role_id`, `key`, `permission_keys` | NO | NONE | permanente |
| `role.permissions_updated` | `update_role_permissions` | `group_id`, `role_id`, `permission_keys` (new) | NO | NONE | permanente |
| `mandate.granted` | `grant_mandate` | `group_id`, `mandate_id`, `representative_membership_id`, `mandate_type`, `scope`, `ends_at` | NO | notify representative | permanente |
| `mandate.revoked` | `revoke_mandate` | `group_id`, `mandate_id`, `revoked_by`, `reason` | NO | notify representative | permanente |
| `rule.created` | `create_text_rule`, `create_engine_rule`, `propose_rule` (+ `publish_rule_version` inline) | `group_id`, `rule_id`, `version_id`, `rule_type`, `shape_key` | NO | notify | permanente |
| `rule.archived` | `archive_rule` | `group_id`, `rule_id`, `archived_by`, `reason` | NO | notify | permanente |
| `resource.created` | `create_resource`, `create_group_resource` | `group_id`, `resource_id`, `resource_type`, `owner_kind`, `owner_membership_id` | YES (trigger possible) | notify | permanente |
| `resource.archived` | `archive_resource` | `group_id`, `resource_id`, `reason` | YES | notify | permanente |
| `resource_series.created` | `create_resource_series` | `group_id`, `series_id`, `cadence`, `ritual_meaning` | NO | NONE | permanente |
| `resource_series.updated` | `update_resource_series` | similar | NO | NONE | permanente |
| `contribution.logged` | `log_contribution`, `record_contribution`, `record_non_monetary_contribution` | `group_id`, `contribution_id` o `transaction_id`, `membership_id`, `amount`, `type` | YES | notify | permanente |
| `money.expense_recorded` | `record_expense` | `group_id`, `transaction_id`, `amount`, `paid_by`, `recorded_by`, `source_resource_id`, `mandate_id`, `split_mode`, `split_breakdown` | **YES** | notify affected | permanente |
| `money.settlement_recorded` | `record_settlement` | `group_id`, `settlement_id`, `transaction_id`, `from`, `to`, `amount`, `mandate_id` | **YES** | notify | permanente |
| `sanction.issued` | `issue_sanction` | `group_id`, `sanction_id`, `target_membership_id`, `amount`, `rule_version_id`, `source_event_id`, `parent_evaluation_id` | **YES + depth+1** | notify target | permanente |
| `decision.started` | `start_vote` | `group_id`, `decision_id`, `method`, `quorum_pct`, `threshold_pct`, `closes_at` | NO | notify members | permanente |
| `decision.vote_cast` | `cast_vote`, `cast_ranked_vote` | `group_id`, `decision_id`, `vote_id`, `voter_membership_id`, `weight` | NO | NONE bulk | permanente (atom `group_votes`) |
| `decision.finalized` | `finalize_vote` | `group_id`, `decision_id`, `outcome`, `tally`, `legitimacy_source` | **YES** + outcome handler | notify + outcome dispatch | permanente |
| `dispute.opened` | `open_dispute` | `group_id`, `dispute_id`, `opener`, `respondent`, `subject_kind`, `subject_id` | YES | notify respondent | permanente |
| `dispute.resolved` | `record_dispute_resolution` | `group_id`, `dispute_id`, `method`, `outcome` | YES | notify; may cascade settle/void | permanente |
| `cultural_norm.proposed` | `propose_cultural_norm` | `group_id`, `norm_id`, `title`, `norm_type` | NO | notify | permanente |
| `cultural_norm.endorsed` | `endorse_cultural_norm`, `endorse_norm` | `group_id`, `norm_id`, `endorsed_count_new` | YES (auto-promote trigger) | NONE | permanente |
| `cultural_norm.promoted_to_rule` | `promote_norm_to_rule`, `_auto_promote_norm_internal` | `group_id`, `norm_id`, `rule_id`, `version_id` | NO | notify | permanente |
| `cultural_norm.retired` | `retire_cultural_norm`, `retire_norm` | `group_id`, `norm_id`, `reason` | NO | notify | permanente |
| `mandate.expiring_in_24h` (V3-A4b) | `emit_mandate_expiring_events()` (cron-callable) | `group_id`, `mandate_id`, `ends_at` | YES (rule may fire reminder) | notify representative | permanente |
| `contribution.verified` / `contribution.rejected` (V3-A1) | `verify_contribution` | `group_id`, `contribution_id`, `outcome`, `verified_by` | YES | notify recorder | permanente |

## E.3 Events declarados pero NO emitidos hoy [F]

Si V3 los necesita, agregar inline `record_system_event` en las RPCs correspondientes:

- `member.left`, `member.expelled` (hoy solo `member.state_changed` cubre).
- `member.profile_updated` (cross-tenant; replicar por cada grupo donde es member, o no emitir).
- `role.granted`, `role.revoked` por miembro (hoy solo `role.created` y `role.permissions_updated`).
- `permission.granted`, `permission.revoked`.
- `mandate.used` (audit per uso).
- `rule.published` separado de `rule.created`.
- `rule.evaluated` (audit a `group_events` además de `group_rule_evaluations`).
- `resource.ownership_transferred`.
- `sanction.paid`, `sanction.voided`, `sanction.appealed`.
- `obligation.overdue` (V3-A4a DEFERRED — sin `due_at` column).
- `dispute.event_added`, `dispute.escalated`.
- `reputation.event_recorded`.
- `ritual.occurred`.
- `dissolution.proposed`, `dissolution.approved`, `dissolution.finalized`.
- `transaction.reversed`.

## E.4 Sync vs Async regla canónica (locked)

**Sync (within tx)**: si el consequence muta estado canónico (sanction, membership, ledger, rule version, decision, resource ownership).
**Async (outbox)**: notifications, projections, search index.
**Never async para mutar canónico**. Si lo requiere → debe ser sync inline en otra RPC.

## E.5 Idempotency

- **Atoms con `client_id`**: `group_resource_transactions`, `group_settlements`. Cliente envía `p_client_id`; UNIQUE `(group_id, client_id)`. Retry → la 2da call retorna lo de la 1ra.
- **Rule evaluations**: `idempotency_key = 'eval:' || source_event_id::text || ':' || rule_version_id::text`. UNIQUE global. Retry safe.
- **Otros**: no estandarizado. **[F]** decisiones, votos, sanciones no aceptan `p_client_id` hoy. Si V3 quiere retry-safe sin double-issue, ALTER signatures.

## E.6 Replay

**[F]** No implementado. RPC `replay_rule_evaluations(p_group_id, p_from, p_to)` declarada en doc pero NO existe. Diseño futuro: corre `evaluate_rules_for_event` con `p_mode='dry_run'`, escribe a tabla `group_rule_evaluations_replay` separada.

---

# F) RULE ENGINE COMPLETO

## F.1 Doctrina founder G3 (6 lock-ins)

> Source: PrimitivesArchitecture.md §F.0 + memorias `doctrine_rule_engine_g3.md`, `doctrine_engine_vs_vote.md`.

1. **Modelo mental: políticas, no automations**. Una regla = identity + scope + trigger + predicates + consequences + authority + audit.
2. **Templates-only**. iOS jamás inventa kinds. User elige atoms del catálogo. Server valida con `validate_rule_shape`.
3. **Sync canonical vs async derived**. `issue_sanction`=sync+`sanctions.create`; `set_membership_state`=sync+`members.suspend`; `send_notification`=async+no auth; `start_vote`=sync+`decisions.create`.
4. **G3.2 ≠ noop permanente**. `evaluate_rules_for_event` ahora SÍ dispatcha (mig 20260528201454).
5. **Explainability = requisito**. Cada `group_rule_evaluations` carga `matched_predicate jsonb` + `actions_emitted jsonb` + `parent_evaluation_id` + `depth` + `cycle_detected`.
6. **Frontera engine vs voto**. **Cambiar autoridad = voto. Aplicar autoridad existente = engine.** Bridge: `consequence.start_vote` permite que regla *delegue a deliberación humana* cuando consecuencia altera orden social.

## F.2 Tablas — schema real verificado

### F.2.1 `rule_shapes_catalog` [V]

```
shape_key       text PK
category        text NOT NULL          -- 'trigger'|'condition'|'consequence'
display_name    text NOT NULL
description     text
schema          jsonb NOT NULL DEFAULT '{}'  -- event_type, fields, execution, authority_required
resource_types  text[] NOT NULL DEFAULT '{}'
metadata        jsonb NOT NULL DEFAULT '{}'
```

**RLS**: `rule_shapes_catalog_select_anyone` (catalog público).

### F.2.2 `group_rules` [V]

Columnas reales (inferidas por consistencia + comment): `id, group_id, title, rule_type ('norm'|'rule'), status ('draft'|'active'|'archived'), current_version_id?, created_by, created_at, updated_at`. Verificar exact schema vía `\d group_rules` si se necesita.

### F.2.3 `group_rule_versions` [V]

```
id                  uuid PK
rule_id             uuid NOT NULL → group_rules(id)
version             int NOT NULL
execution_mode      text NOT NULL                  -- 'sync'|'async'
body                text                            -- text-rule display fallback
trigger_event_type  text                            -- matches rule_shapes_catalog trigger
condition_tree      jsonb                           -- predicate
consequences        jsonb                           -- [{kind, ...}]
shape_key           text                            -- ref a rule_shapes_catalog
effective_from      timestamptz DEFAULT now()
effective_until     timestamptz                     -- mutable (partial guard)
published_by        uuid                            -- NULL si auto-promote (V3-A2)
created_at          timestamptz DEFAULT now()
```

**Guard**: `group_rule_versions_atom_guard` BEFORE UPDATE — solo `effective_until` mutable. `group_rule_versions_no_delete` BEFORE DELETE.

### F.2.4 `group_rule_evaluations` [V]

```
id                    uuid PK
rule_version_id       uuid NOT NULL → group_rule_versions(id)
group_id              uuid NOT NULL
source_event_id       uuid                          -- FK lógica a group_events.uuid_id
matched               bool NOT NULL
consequences_emitted  jsonb NOT NULL DEFAULT '[]'   -- legacy
idempotency_key       text NOT NULL UNIQUE
created_at            timestamptz DEFAULT now()
parent_evaluation_id  uuid → group_rule_evaluations(id)
depth                 int NOT NULL DEFAULT 0
matched_predicate     jsonb                          -- {passed, reason, kind, evaluated_value}
actions_emitted       jsonb NOT NULL DEFAULT '[]'    -- [{kind, execution, status, target_id?, error?, audience?}]
cycle_detected        bool NOT NULL DEFAULT false
```

**Guards**: full atom guards (`atom_no_mutation_guard` + `atom_no_delete_guard`).
**Índices**: `(idempotency_key)`, `(group_id, created_at DESC)`, `(parent_evaluation_id)`.
**RLS**: `group_rule_evaluations_select_admin` (admin-only).

## F.3 Catálogo vivo — 19 shapes [V]

Query: `SELECT shape_key, category FROM rule_shapes_catalog ORDER BY category`.

**Triggers (8)**:
1. `trigger.contribution.logged`
2. `trigger.decision.finalized`
3. `trigger.dispute.opened`
4. `trigger.mandate.granted`
5. `trigger.member.state_changed`
6. `trigger.money.expense_recorded`
7. `trigger.money.settlement_recorded`
8. `trigger.sanction.issued` (meta-trigger; engine observa sus outputs)

**Conditions (6)**:
1. `condition.actor_role_in`
2. `condition.amount_above`
3. `condition.amount_between`
4. `condition.is_first_offense`
5. `condition.target_role_in`
6. `condition.target_self`

**Consequences (5)**:
1. `consequence.create_pool_charge` (sync, `pool_charge.record`)
2. `consequence.issue_sanction` (sync, `sanctions.create`)
3. `consequence.send_notification` (async, no auth)
4. `consequence.set_membership_state` (sync, `members.suspend`)
5. `consequence.start_vote` (sync, `decisions.create` — bridge engine→voto)

> El doc afirma "6 consequences" — realidad es **5**. Drift cosmético.

## F.4 RPCs reales del engine [V]

```sql
-- Public
evaluate_rules_for_event(p_event_uuid_id uuid, p_mode text DEFAULT 'sync', p_parent_evaluation_id uuid DEFAULT NULL) RETURNS uuid
list_rule_shapes() RETURNS SETOF rule_shapes_catalog
validate_rule_shape(p_shape jsonb) RETURNS jsonb
create_text_rule(p_group_id, p_title, p_body, p_rule_type DEFAULT 'norm', p_severity DEFAULT 1) RETURNS record
create_engine_rule(p_group_id, p_title, p_shape_key, p_condition_tree, p_consequences, p_rule_type DEFAULT 'norm', p_severity DEFAULT 1) RETURNS record
publish_rule_version(p_rule_id, p_execution_mode, p_body, p_trigger_event_type, p_condition_tree, p_consequences, p_shape_key) RETURNS uuid
archive_rule(p_rule_id, p_reason) RETURNS void
group_rules_active(p_group_id) RETURNS SETOF record
group_rules_engine(p_group_id) RETURNS SETOF record
group_rule_evaluations(p_group_id, p_limit DEFAULT 50, p_before timestamptz DEFAULT NULL) RETURNS SETOF record

-- Internals (public._ prefix; NO schema ruul)
_rule_eval_predicate(p_condition_tree jsonb, p_event group_events) RETURNS jsonb
_rule_eval_dispatch(p_action jsonb, p_event group_events, p_rule_version_id uuid) RETURNS jsonb
```

Notar:
- `_rule_eval_predicate` y `_rule_eval_dispatch` reciben **`group_events%ROWTYPE`** (no `system_events` como el doc declara). [C]
- `evaluate_rules_for_event` recibe **`p_event_uuid_id`** (el `uuid_id` de la fila, no el `id bigint`). [V]

## F.5 Lifecycle integration con 7 callsites [V]

| RPC callsite | event_type emitido | Cableado |
|---|---|---|
| `record_expense` | `money.expense_recorded` | sync inline pre-G3.2 |
| `record_settlement` | `money.settlement_recorded` | sync inline pre-G3.2 |
| `record_pool_charge` | (sin event_type observado) | sync inline pre-G3.2 |
| `issue_sanction` | `sanction.issued` | sync inline G3.2 (mig 20260528201454) |
| `set_membership_state` | `member.state_changed` | sync inline G3.2 |
| `open_dispute` | `dispute.opened` | sync inline G3.2 |
| `finalize_vote` | `decision.finalized` | sync inline G3.2 |

Patrón canónico:
```sql
BEGIN
  -- 1. validate + assert_permission
  -- 2. mutate state (insert canonical row)
  -- 3. INSERT INTO group_events ... RETURNING uuid_id INTO v_event_uuid
  -- 4. PERFORM evaluate_rules_for_event(v_event_uuid, 'sync')
  -- 5. RETURN
END;
```

## F.6 Loop prevention (3 capas verificadas)

1. **Depth guard**: `p_depth >= 5` (declared in code; verificar EXCEPTION). Aborta con verdict implicit `recursion_aborted`.
2. **Cycle detection**: `cycle_detected bool` column en `group_rule_evaluations`. Set por WITH RECURSIVE walk de `parent_evaluation_id` chain matcheando `rule_version_id` repetido.
3. **Per-event idempotency**: `UNIQUE (idempotency_key)` evita re-eval del mismo (event_uuid, rule_version_id) en retry.

## F.7 Error handling

- Error en consequence dispatcher → captura en `actions_emitted[].status='failed'+error` sin rollback (audit-first).
- Excepción crítica (permission denied al ejecutar consequence con actor sistema) → log + verdict error, demás consequences siguen.
- Sync consequence fallido (issue_sanction, set_membership_state) → eval marca error y NO aborta flow original. Riesgo: estado parcial. **[F]** Mitigation V3: opt-in `consequence_failure_mode='rollback_all'` por rule version.

## F.8 Replay

**[F]** No implementado. Diseño: `replay_rule_evaluations(p_group_id, p_from_event_id, p_to_event_id)` corre engine con `p_mode='dry_run'` sobre events históricos, escribe a tabla separada `group_rule_evaluations_replay`.

## F.9 Simulación

**[F]** RPC `simulate_rule_eval(p_rule_version_id, p_fake_event)` declarada en doc; NO existe. Necesaria para V3 EditRuleView preview.

## F.10 Workflows + AI agents futuros

Extensión natural:
- `consequences[].kind = 'invoke_workflow'` con `workflow_id` apuntando a (futura) `group_workflows`.
- `consequences[].kind = 'invoke_agent'` con `agent_id` + prompt. Agent inserta `group_events` posterior con `actor_user_id=NULL` + payload `actor_kind='ai_agent'`.

Compatibilidad: dispatcher es `CASE WHEN action.kind = ... THEN PERFORM ...` enum-based. Agregar `kind` requiere ALTER dispatcher y `rule_shapes_catalog` seed.

## F.11 Locking

- `SELECT ... FOR UPDATE` en `group_events` row al inicio de eval (**[NV]** verificar — el body interno no fue auditado).
- TX envolvente de la RPC dominio se encarga del isolation; eval reusa.

## F.12 Transaction boundaries

| Layer | Tx scope |
|---|---|
| RPC dominio | inicia tx; contiene canonical write + group_event + eval + nested dispatchers. |
| `evaluate_rules_for_event` sync | mismo tx que parent. |
| `send_notification` async | inserta a `notifications_outbox` en mismo tx; cron drain = tx separada. |
| Edge function cron | tx separada por batch. |

## F.13 ALTERs faltantes para versión completa [F]

1. **`group_rule_versions` UNIQUE active partial**: `CREATE UNIQUE INDEX one_active_version_per_rule ON group_rule_versions(rule_id) WHERE effective_until IS NULL;` — **[NV]** verificar si ya existe.
2. **`group_rule_evaluations.depth CHECK (depth >= 0 AND depth <= 5)`** — **[NV]** verificar.
3. **`group_events.event_type` enum / lookup table** — hoy es text libre. Para forzar catálogo: `CREATE TABLE event_type_catalog (event_type text PK, ...)` + FK soft. Opcional V3.
4. **Particionado mensual** de `group_events` + `group_resource_transactions` — V3 cuando > 5M rows.
5. **`group_rule_evaluations_replay` table** — V3 si se necesita replay.

---

# G) MONEY SYSTEM COMPLETO

## G.1 Atom canónico — `group_resource_transactions` [V]

> Es el `ledger_entries` del doc. **Doctrina forward: usar nombre real**.

```
id                     uuid PK DEFAULT gen_random_uuid()
seq                    bigint NOT NULL UNIQUE        -- monotonic cursor FIFO
group_id               uuid NOT NULL
resource_id            uuid                          -- subtype envelope (fund/pool/asset)
transaction_type       text NOT NULL                 -- 'expense'|'contribution'|'settlement'|'pool_charge'|'payout'|'reversal'|'fund_deposit'|...
from_membership_id     uuid                          -- party que paga / cede
to_membership_id       uuid                          -- party que recibe
paid_by_membership_id  uuid                          -- tri-role: payer real (puede diferir de from)
amount                 numeric NOT NULL
unit                   text NOT NULL                 -- 'MXN'|'USD'|...
source_resource_id     uuid                          -- contextualización (qué resource motiva)
source_entity_kind     text                          -- polimórfico: 'sanction'|'obligation'|'event'|...
source_entity_id       uuid
reversed_entry_id      uuid                          -- self-ref para reversals
split_breakdown        jsonb                         -- per-payer breakdown (V3-S1 Splitwise)
split_mode             text                          -- 'even'|'exact'|'percentage'|'shares'|'custom'
in_kind                bool NOT NULL DEFAULT false
description            text
metadata               jsonb NOT NULL DEFAULT '{}'
client_id              text                          -- idempotency key (UNIQUE per group)
recorded_by            uuid                          -- tri-role: who recorded (RBAC actor)
mandate_id             uuid                          -- if acted on behalf
occurred_at            timestamptz NOT NULL DEFAULT now()
created_at             timestamptz NOT NULL DEFAULT now()
```

**Guards**: `atom_no_mutation_guard` (full), `atom_no_delete_guard`, `assert_mandate_same_group`.
**Índices**: `(group_id, seq)`, `(mandate_id) WHERE NOT NULL`, `(resource_id)`, `(source_entity_kind, source_entity_id)`, `UNIQUE (group_id, client_id)`, `UNIQUE (seq)`.
**Tri-role doctrine**: `recorded_by` (RBAC actor) ≠ `paid_by_membership_id` (factual) ≠ `to_membership_id` (recipient). Hard-coded.

## G.2 Otras tablas Money [V]

### `group_obligations`
```
id, group_id, owed_by_membership_id, owed_to_membership_id, owed_to_kind ('member'|'pool'),
source_transaction_id, source_resource_id, source_mandate_id,
obligation_kind ('debt'|'pool_charge'|'sanction'|...),
amount_original, amount_outstanding, unit,
status ('open'|'partially_settled'|'settled'|'void'),
description, metadata,
created_at, updated_at
```

**[F]** Sin `due_at` column. V3-A4a deferred.
**Trigger**: `assert_source_mandate_same_group`, `set_updated_at`.

### `group_settlements`
```
id, group_id, paid_by_membership_id, paid_to_membership_id, paid_to_kind ('member'|'pool'),
amount, unit, status ('initiated'|'confirmed'|...),
ledger_entry_id (FK a transactions), client_id (UNIQUE per group), notes, metadata,
recorded_by, confirmed_at, mandate_id,
created_at, updated_at
```

### `group_settlement_obligations` (bridge)
```
settlement_id, obligation_id, amount_applied, applied_at
```
Append-only (atom guards).

### `group_contributions`
Non-monetary contributions (cuidado/moderación/docs). 1 row hoy. Acepta verify path via `verify_contribution`.

## G.3 Authority + approval (per CanonicalRPCs_Contract.md signed)

| RPC | Authority paths |
|---|---|
| `record_expense` | self_party (actor=paid_by) ∨ `expenses.record_for_others` ∨ mandate (scope contiene `expenses.record_for_others`) |
| `record_contribution` | self_party ∨ `contributions.record_for_others` ∨ mandate |
| `verify_contribution` | `contributions.verify` (NO self-verify; bloqueado en RPC) |
| `record_settlement` | self_party (actor ∈ {from, to}) ∨ `settlements.record_for_others` ∨ mandate |
| `record_pool_charge` | `pool_charge.create` ∨ mandate (admin-only flow) |
| `record_payout` | `pool_payout.execute` ∨ mandate |
| `reverse_transaction` | self_party (actor recorded original) ∨ `transactions.reverse` |
| `record_asset_valuation` | `asset.value` |
| `issue_sanction` | `sanctions.create` ∨ engine `actor=system` |

## G.4 Idempotency + reversal semantics [V]

- TODO insert lleva `client_id` (cliente genera, server NO sobreescribe). Si NULL, no idempotente.
- Reverse = INSERT nuevo entry con `transaction_type='reversal'` + `reversed_entry_id=original.id` + `amount = -original.amount` (o inverso por kind). NUNCA UPDATE original.
- Settlement linking: bridge `group_settlement_obligations` consume obligations FIFO. `group_obligations.amount_outstanding` decrementa.

## G.5 Splitwise (V3-S1) [V]

> shipped 2026-05-29 commit `5366919e`.

- iOS materializa `split_breakdown jsonb` client-side (cents + leftover distribution determinista en `ExpenseSplitCalculator`).
- iOS siempre envía `p_split_mode='custom'` con `p_split_breakdown` ya resuelto.
- 4 modos visuales en picker: parejo / exacto / porcentaje / partes.
- Tests `ExpenseSplitCalculatorTests` cubren 80/80 escenarios.

## G.6 Conexiones a otras capas

| Money ↔ | Conexión |
|---|---|
| Rules | triggers `money.expense_recorded`, `money.settlement_recorded`, `sanction.issued`, `contribution.logged`. Consequences `create_pool_charge`, `issue_sanction`. |
| Events | TODA RPC ledger emite `group_events`. |
| Disputes | `dispute_sanction` linkea via `group_sanctions.dispute_id`. Settlement cascade: `record_settlement` cierra sanción linked (mig 20260528050718). |
| Governance | `decision_type='pool_charge'` outcome handler invoca `record_pool_charge` (mig 20260528180224). |
| Notifications | Cada ledger insert puede `enqueue_notification` (vía consequence `send_notification`). |
| Reputation | `verify_contribution` cablea `contribution_recognized`. `issue_sanction` cablea `rule_violation`/`commitment_broken`. |
| Audit | Full traceable. `seq` monotónico permite FIFO replay. |

## G.7 ALTERs faltantes [F]

1. **`group_obligations.due_at timestamptz`** — desbloquea V3-A4a `obligation.overdue` emitter.
2. **`pay_sanction` RPC** — falta. Hoy se cierra vía `record_settlement` linked con cascade.
3. **`sanction_payment_status` RPC** — SQL en disco `20260529030000` sin aplicar.
4. **`propose_payment_plan` / sanction payment plans** — SQL en disco `20260529040000` sin aplicar.
5. **`rule_evaluation_summary` RPC** — SQL en disco `20260529010000` sin aplicar.
6. **`leave_group` balance guard** — bloquear leave si balance != 0.

---

# H) GOVERNANCE SYSTEM

## H.1 Tablas reales [V]

### `group_decisions`
```
id, group_id, title, body,
decision_type text DEFAULT 'proposal',     -- 'membership'|'rule_change'|'pool_charge'|... (sin CHECK enum estricto)
method text DEFAULT 'majority',            -- 'admin'|'majority'|'supermajority'|'consensus'|'consent'|'ranked_choice'|'weighted'|'veto' (8)
legitimacy_source text DEFAULT 'majority', -- 'majority'|'supermajority'|'consensus'|'consent'|'admin_decree'|'founder_decree'|'tradition'|'mandate_delegation'|'rule_book'|'external_arbitrator' (10)
status text DEFAULT 'draft',               -- 'draft'|'open'|'passed'|'rejected'
threshold_pct numeric,                     -- snapshot
quorum_pct numeric,                        -- snapshot
committee_only bool DEFAULT false,
reference_kind text,                       -- polimórfico subject
reference_id uuid,
opens_at, closes_at, decided_at,
result jsonb DEFAULT '{}',
metadata jsonb DEFAULT '{}',
created_by, created_at, updated_at
```

**Partial guard** `_group_decisions_partial_guard`: si OLD.status ∈ (`passed`, `rejected`) bloquea mutación material (excepto `updated_at`).

### `group_decision_options`
```
id, decision_id, option_label, sort_order, metadata
```

### `group_votes` (atom)
```
id, seq (UNIQUE), group_id, decision_id, voter_membership_id,
option_id, vote_value (text — 'yes'|'no'|'abstain'|...), weight numeric DEFAULT 1,
reason, cast_at, created_at
```
**Full guards**. **Indexed `(decision_id, voter_membership_id, seq DESC)`** → DISTINCT ON via `current_vote_for`.

### `groups.decision_rules jsonb` (per-group config)
Carga `default_method`, `default_style`, `quorum_min`, `default_legitimacy_source`, `notes`.

## H.2 RPCs reales [V]

```sql
set_decision_rules(p_group_id, p_default_style, p_quorum_min, p_notes) → jsonb
set_decision_rules(p_group_id, p_default_style, p_quorum_min, p_notes, p_default_method, p_default_legitimacy_source) → jsonb
group_decision_rules(p_group_id) → jsonb

start_vote(p_group_id, p_title, p_body, p_decision_type, p_method,
           p_legitimacy_source DEFAULT 'majority',
           p_opens_at, p_closes_at,
           p_threshold_pct, p_quorum_pct,
           p_committee_only DEFAULT false,
           p_reference_kind, p_reference_id,
           p_options jsonb, p_metadata jsonb) → uuid

cast_vote(p_decision_id, p_option_id, p_vote_value, p_reason) → uuid
cast_vote(p_decision_id, p_option_id, p_vote_value, p_reason, p_weight) → uuid
cast_ranked_vote(p_decision_id, p_rankings jsonb, p_reason) → uuid

finalize_vote(p_decision_id) → text       -- outcome dispatcher inline
cancel_vote(p_decision_id, p_reason) → void

decision_detail(p_decision_id) → jsonb
list_decisions_active(p_group_id) → SETOF record
list_decisions_history(p_group_id, p_limit) → SETOF record

current_vote_for(p_decision_id, p_voter_membership_id) → group_votes
current_votes_for_decision(p_decision_id) → SETOF group_votes
```

**[F]** `propose_decision` separado (la propuesta = `start_vote` directo); `record_consent_objection` (vía `cast_vote` con choice especial).

## H.3 Quorum + threshold (locked snapshot)

- Snapshot al `start_vote`. NO recalculan.
- Counting via DISTINCT ON `(decision_id, voter_membership_id) ORDER BY seq DESC` (latest cast per voter).
- Weighted: `weight numeric` en cast; tally suma.
- Ranked: `cast_ranked_vote` insert múltiples rows con `metadata.rank`.
- Consent: choice especial; un single sustained objection falla.

## H.4 Authority + mandate

- `cast_vote` NO acepta mandate (voting non-delegable). Verificado en signature.
- `start_vote` SÍ podría aceptar mandate (proposer-on-behalf); **[NV]** verificar signature exacta.

## H.5 Outcome dispatcher (3 handlers vivos) [V/F]

Implementados:
- `decision_type='membership'` → `set_membership_state` (mig 20260528173934).
- `decision_type='rule_change'` → `publish_rule_version` (mig 20260528175113).
- `decision_type='pool_charge'` → `record_pool_charge` (mig 20260528180224).

Faltantes [F]:
- `decision_type='mandate'` → `grant_mandate`/`revoke_mandate`.
- `decision_type='sanction_appeal'` → `update_sanction_status('voided')` o partial.
- `decision_type='budget'` → ?
- `decision_type='resource_change'` → `create_resource`/`archive_resource`/`set_resource_ownership`.
- `decision_type='governance_change'` → mutate `groups.decision_rules` (+ debería versionar).
- `decision_type='dissolution'` → `finalize_dissolution`.
- `decision_type='cultural_norm_promotion'` → `promote_norm_to_rule`.
- `decision_type='purpose_change'` → `set_group_purpose`.
- `decision_type='free_form'` → audit only.

## H.6 Immutable history

- `group_votes` full atom guards.
- `group_decisions` partial guard si terminal.
- `result jsonb` se escribe una vez al finalize.

## H.7 Emergency / veto

- `method='veto'`: una sola `choice='veto'` cast por miembro con rol veto holder falla decision. **[NV]** verificar en `finalize_vote` body.
- `legitimacy_source='founder_decree'` + emergency flag bypass quorum: **[NV]** no claro en BD.

---

# I) DISPUTES + CONSECUENCIAS

## I.1 Tablas reales [V]

### `group_disputes`
```
id, group_id, opened_by_membership_id, respondent_membership_id,
subject_kind, subject_id,   -- polimórfico
title, description,
status DEFAULT 'open',      -- 'open'|'mediation'|'resolved'|'escalated_to_vote' (sin CHECK explícito; observado en data)
mediator_membership_id, resolution_method, resolution,
escalated_decision_id,      -- FK a group_decisions cuando escalado
opened_at, resolved_at,
metadata, updated_at
```

### `group_dispute_events` (atom)
```
id, dispute_id, event_type, body, metadata, ...
```
Full guards.

## I.2 RPCs reales [V]

```sql
open_dispute(p_group_id, p_subject_kind, p_subject_id, p_title, p_description, p_respondent_membership_id) → uuid
append_dispute_event(p_dispute_id, p_event_type, p_body, p_metadata DEFAULT '{}') → uuid
assign_mediator(p_dispute_id, p_mediator_membership_id) → void
record_dispute_resolution(p_dispute_id, p_method, p_resolution_text, p_outcome jsonb) → void
escalate_dispute_to_vote(p_dispute_id, p_decision_title, p_decision_method, p_closes_at) → uuid
dispute_sanction(p_sanction_id, p_summary) → uuid    -- opens dispute con subject_kind='sanction'
dispute_detail(p_dispute_id) → record
list_dispute_events(p_dispute_id, p_limit DEFAULT 200) → SETOF record
group_disputes_active(p_group_id, p_limit DEFAULT 50) → SETOF record
```

## I.3 Lifecycle observado [V]

```
open ──┬→ mediation ──┬→ resolved
       │              └→ escalated_to_vote ──→ resolved (via finalize_vote outcome handler)
       └────────────→ withdrawn (manual)
```

## I.4 Cascadas verificadas [V]

- **`record_settlement_cascades_to_linked_sanctions`** (mig 20260528050718): al settlear obligation con `source_entity_kind='sanction'`, marca sanction status.
- **`dispute_resolution_releases_sanction_status`** (mig 20260528052112): al resolve dispute con sanction subject, libera status sanción según outcome.

## I.5 Appeal flow

```
issue_sanction(target)
  → target.dispute_sanction(sanction_id, summary)
    → open_dispute con subject_kind='sanction', subject_id=sanction_id
    → record_system_event('dispute.opened')
    → evaluate_rules_for_event(...)
  → mediator review OR escalate_dispute_to_vote → finalize_vote('sanction_appeal') (**[F]** handler no implementado)
  → record_dispute_resolution(...) → cascada releases sanction
```

## I.6 Arbitration future [F]

V3: `group_arbitrators` table + `escalate_dispute_to_arbitrator(p_arbitrator_id)`. Sin entidad hoy.

---

# J) MEMORY / AUDIT SYSTEM

## J.1 Append-only strategy verificada

| Tabla | Guard tipo | Mutability |
|---|---|---|
| `group_events` | full | none |
| `group_resource_transactions` | full | none |
| `group_votes` | full | none |
| `group_rsvp_actions` | full | none |
| `group_check_in_actions` | full | none |
| `group_resource_bookings` | partial | `status, reason, metadata` |
| `group_rule_versions` | partial | `effective_until` |
| `group_rule_evaluations` | full | none |
| `group_dispute_events` | full | none |
| `group_reputation_events` | partial | `status, visibility` |
| `group_membership_events` | full | none |
| `group_resource_asset_valuations` | full | none |
| `group_settlement_obligations` | full | none |
| `notifications_outbox` | partial | `dispatch_status, attempts, last_error, dispatched_at` |
| `group_decisions` | partial (conditional) | mutaciones bloqueadas si terminal |

Helper trigger functions: `atom_no_mutation_guard`, `atom_no_delete_guard`, partial-specific.

## J.2 Retention strategy

| Tabla | Retention | Strategy |
|---|---|---|
| `group_events` | indefinida hoy | **[F]** partición + archive cold storage cuando > 5M rows |
| `group_resource_transactions` | forever | sin archive (es contabilidad) |
| `group_rule_evaluations` | indefinida | **[F]** 90d hot + archive |
| `notifications_outbox` | drain by cron | **[F]** DELETE post-dispatch + N días aún bloqueado por `_no_delete` guard → revisar |
| `group_reputation_events` | forever | sin archive |

## J.3 Replay / causation chain

- **`group_rule_evaluations.parent_evaluation_id`** mantiene chain de causality.
- **`group_rule_evaluations.source_event_id`** apunta a `group_events.uuid_id` que disparó.
- **Replay actual**: ninguna RPC. Manual via `evaluate_rules_for_event` en mode dry-run sería ideal — **[F]** no implementado.

## J.4 Actor attribution

- `group_events.actor_user_id` → auth.uid (NULL si system).
- `group_resource_transactions.recorded_by` → membership-level actor.
- Cross-reference: `actor_user_id = auth.users.id`; mapping a membership via `group_memberships.user_id` JOIN.

## J.5 Timeline reconstruction

UI usa `group_events_recent(p_group_id, p_limit, p_before)` con cursor `(created_at DESC, id DESC)`. Realtime publication permite stream.

---

# K) NOTIFICATION SYSTEM

## K.1 Schema real [V]

### `notifications_outbox`
```
id, group_id, recipient_user_id, category, payload jsonb,
dispatch_status DEFAULT 'pending',  -- 'pending'|'dispatched'|'failed'
attempts DEFAULT 0,
last_error, dispatched_at,
created_at
```
**Partial guard** + **no_delete guard** (V3-A3a).
**Index**: partial `WHERE dispatch_status='pending'`.
**RLS**: `select_self`.

### `notification_tokens`
```
id, user_id, token (APNs), platform DEFAULT 'ios', ...
```
**RLS**: self only.

### `notification_preferences`
```
user_id, group_id, category, channel, enabled, ...
```
**RLS**: self only.

## K.2 RPCs reales [V]

- `register_my_notification_token(p_token, p_platform DEFAULT 'ios')` — upsert token, returns id.
- `set_notification_preference(p_group_id, p_category, p_channel, p_enabled)`.
- `my_notification_preferences(p_group_id)`.

## K.3 Cron drain [NV]

- Edge function `dispatch-notifications-every-minute` declarada en CLAUDE.md global. NO verificable desde SQL. Asumir externo.
- Edge function lee partial idx, dispatch APNs, marca `dispatched_at` + `dispatch_status='dispatched'`.

## K.4 Fanout / subscriptions

- Hoy es 1:N point-to-point por `recipient_user_id`. NO topic/channel model.
- Para "notify admins" → consequence handler debe iterar admins y crear N rows.
- Para "notify group" → similar.

## K.5 Delivery guarantees

- **At-least-once**: cron retry con `attempts++` y `last_error`.
- **Idempotency**: **[F]** no constraint UNIQUE en outbox. Dedup vía `(group_id, category, payload->>'idempotency_key')` queda al caller.

## K.6 Batching / dedup

**[F]** No implementado. Cada consequence inserta 1 row.

---

# L) FUTURE-PROOFING

## L.1 Múltiples grupos por usuario [V]

`group_memberships UNIQUE (group_id, user_id)` + index `(user_id)`. `list_my_groups()` escala sin scan. **OK**.

## L.2 Organizaciones complejas / subgrupos / federation [F]

Hoy `groups` no tiene `parent_group_id`. Para subgrupos: ALTER ADD + RLS tweaks. Diseño compatible (1 nivel de parent). Federation requiere `external_group_id` + protocol (out of V3 scope).

## L.3 Nested authority

Mandates NO encadenan hoy (locked). Si V4 quiere "mandate delegation transitiva": agregar `mandate.delegatable bool` + recursion guard en `_resolve_authority_path`. Cuidado con loops.

## L.4 AI agents

Compatible si:
1. Agregar `consequence.invoke_agent` al catalog.
2. `actor_user_id` puede ser NULL (ya lo es) con `payload.actor_kind='ai_agent'`.
3. Agent ejecuta vía edge function que llama RPC con service_role.

## L.5 Workflows multi-step [F]

Necesitaría `group_workflows` + state machine. Out of V3.

## L.6 Tokenización / portable reputation [F]

`group_reputation_events.metadata` puede cargar `external_signature` para portable. Si V5 quiere reputation portable cross-grupo, necesita firmar por user con clave persistente. Diseño compatible (sin score).

## L.7 Permissions marketplace [F]

`permissions` table es read-only seed. Si V5 quiere permissions custom: requiere lifecycle separado + governance approval. Out of scope.

## L.8 Plugins / external integrations

Edge functions + `notifications_outbox` ya soportan bridges (Slack/Email/WhatsApp). **OK**.

## L.9 Decisiones actuales que ayudan vs bloquean

✅ **Ayudan**:
- Atoms append-only + universal audit (`group_events`).
- Polimorfismo via `(entity_kind, entity_id)` en transactions/events.
- Rule shape catalog vocabulary (templates-only).
- Tri-role en ledger (recorded/paid/to).
- Mandate como entidad explícita (no inferencia).
- Realtime publication en events/decisions/disputes.

⚠️ **Bloquean (vigilar)**:
- `groups.settings/decision_rules/roles_catalog` jsonb sin versionado → cambios sin audit.
- `event_type text` libre sin catalog → drift naming.
- Cron externo (edge functions) sin observabilidad SQL → hard to debug.
- `_rule_eval_predicate` y `_rule_eval_dispatch` con ELSIF hardcoded — refactor a handler registry table-driven antes de > 20 atoms.
- `profiles_select_authenticated` cross-tenant leak risk.

---

# M) PLAN POR PARTES (PARTE 0 — PARTE 12)

> Cada PARTE deja el sistema funcionando, sin breaking. Foundation YA está + V2 G3 cerrado. El plan se concentra en deuda **operativa** (no en re-implementar lo que ya existe).
>
> Orden estricto: no avanzar a PARTE N+1 sin verde la PARTE N.

## PARTE 0 — Inventario real (este documento) ✅

**Hecho**. Evidencia: §FASE 0 completa. Drift map firme. Migraciones 96/96 confirmadas aplicadas; 4 SQL pendientes detectadas.

## PARTE 1 — Saneamiento de RLS profiles cross-tenant

**Revisar**: `profiles_select_authenticated` policy.
**Existe hoy**: policy permite leer TODOS los profiles authenticated.
**Evidencia**: §0.9.
**Falta**:
- Decidir doctrina: ¿`display_name` cross-tenant + `phone/email` self-only? O `profiles_select_self_or_group_member` con CTE.
**Modificar**:
- DROP policy actual; CREATE nueva: `USING (id = auth.uid() OR id IN (SELECT user_id FROM group_memberships WHERE group_id IN (SELECT group_id FROM group_memberships WHERE user_id = auth.uid() AND status IN ('active','provisional'))))`.
**NO tocar**:
- `profiles_insert_self`, `profiles_update_self`, `profiles_delete_self`.
**Riesgo**: rompe pantallas que asumen "puedo leer cualquier profile". Auditar usos de `LiveProfileRepository.fetchAny`.
**Migraciones**: 1 mig RLS swap.
**RPCs**: ninguna nueva.
**Eventos**: ninguno nuevo.
**Smoke**: `pgtap` test — autenticado en grupo A NO puede SELECT profile de user solo en grupo B.

## PARTE 2 — Aplicar las 4 migraciones pendientes en disco

**Revisar**: `supabase/migrations/20260529010000`-`20260529040000`.
**Existe hoy**: SQL files en disco. **[V]** Aplicadas: NO (verificado via `schema_migrations`).
**Evidencia**: §0.5.
**Falta**:
- `rule_evaluation_summary` RPC.
- `system_event_engine_provenance` (probablemente columna en `group_events.payload` para llevar `triggered_by_evaluation_id`).
- `sanction_payment_status` RPC.
- `sanction_payment_plans` tabla + RPCs.
**Acción**:
1. Leer cada SQL.
2. Verificar que no rompen idempotency / atom guards / RLS existente.
3. Aplicar vía `mcp__supabase__apply_migration` uno por uno.
4. Smoke después de cada uno.
**Riesgo**: si SQL escrito hace 1+ días y schema ya cambió → conflicto. Verificar columnas referenciadas existen.
**Smoke**: por mig — call RPC, verificar shape, verificar no afecta data existente.

## PARTE 3 — Cerrar eventos faltantes (sin rule.published, sin transaction.reversed, etc.)

**Revisar**: §0.6 + §E.3.
**Existe**: 31 event_types vivos.
**Falta**: `sanction.paid`, `sanction.voided`, `mandate.used`, `rule.published` (separado de `created`), `resource.ownership_transferred`, `dispute.event_added`, `dispute.escalated`, `transaction.reversed`, `dissolution.*`, `permission.granted/revoked`, `role.granted/revoked` per-member.
**Modificar**:
- RPCs `update_sanction_status`, `reverse_transaction`, `set_resource_ownership`, `grant_mandate`/`revoke_mandate`, `append_dispute_event`, `escalate_dispute_to_vote`, `propose_dissolution`/`finalize_dissolution`, `assign_role_to_member`/`revoke_role_from_member`: agregar `record_system_event(...)` al final.
- Cuando `update_sanction_status` cambia a `paid/voided`, emitir event_type adecuado.
**NO tocar**:
- Atoms; solo el inserter de events.
**Riesgo**: los downstream que filtran por event_type específico necesitan whitelisting. Verificar `group_events_recent` y `iOS group_events filters`.
**Migración**: una mig por RPC modificada.
**Smoke**: pgtap — exec RPC, SELECT FROM group_events WHERE event_type = '<nuevo>' return row.

## PARTE 4 — Outcome handlers faltantes para `finalize_vote`

**Revisar**: §H.5.
**Existe**: 3/11 decision_types con handler (membership, rule_change, pool_charge).
**Falta**: mandate, sanction_appeal, budget, resource_change, governance_change, dissolution, cultural_norm_promotion, purpose_change, free_form.
**Acción** (per type):
- Diseñar payload shape esperado en `group_decisions.metadata`.
- Implementar branch en `finalize_vote` que invoca RPC dominio.
- Emitir `record_system_event` post-handler.
- Smoke per type.
**Riesgo**: handler invoca RPC que valida permission con actor=system; verificar SECURITY DEFINER chain no leaks.
**Migraciones**: 8 migs separadas (una por type).
**Smoke**: pgtap por type — propose+vote+finalize → verificar mutación canónica + system_event.

## PARTE 5 — Money cleanup: `pay_sanction`, balance guard en `leave_group`, `obligation.overdue`

**Revisar**: §G.7 + §A.3 riesgos + §0.4.
**Existe**: `record_settlement` con cascade cierra sanción linked; `leave_group` no checa balance; `group_obligations` sin `due_at`.
**Falta**:
- `pay_sanction(p_sanction_id, p_amount, p_unit, p_client_id)` RPC dedicada (azúcar sobre `record_settlement` con FIFO obligation cierre).
- `leave_group` guard: `member_balance_in_group(group, member) != 0 → permission_denied:balance_pending`.
- `group_obligations.due_at timestamptz` column + `obligation.overdue` emitter (V3-A4a).
**Acción**:
1. Mig ALTER ADD COLUMN `due_at`.
2. Decidir doctrina: ¿se popula desde sanction.ends_at? ¿desde payment plan? ¿desde mandate?
3. Crear emitter `emit_obligation_overdue_events()` similar a `emit_mandate_expiring_events`.
4. Wire cron edge function.
**Riesgo**: agregar `due_at` quiebra UI que asume "obligaciones sin vencimiento". Backfill NULL.
**Smoke**: crear obligation due ayer → emitter inserta `obligation.overdue` con idempotency.

## PARTE 6 — Disputes / appeals deepening

**Revisar**: §I.
**Existe**: open/append/mediator/resolve/escalate; cascade settlement.
**Falta**: `sanction_appeal` outcome handler en `finalize_vote` (PARTE 4 lo cubre). Endorsements per-member en cultural norms si auditoría granular se necesita.
**No requiere mig nueva si PARTE 4 cubre.**

## PARTE 7 — Governance: versionado de `groups.decision_rules`

**Revisar**: §A.2 + §0.3 + §D.5.
**Existe**: `groups.decision_rules jsonb` mutable; `set_decision_rules` overwrites.
**Falta**: `group_governance_versions(group_id, snapshot jsonb, effective_from, effective_until, set_by, source_decision_id)` append-only.
**Acción**:
1. Mig CREATE TABLE + RLS + indexes.
2. ALTER `set_decision_rules` para insertar nueva row y marcar previous `effective_until=now()`.
3. Emit `governance_change.applied` event.
**Riesgo**: bajo (additive).
**Smoke**: mutación → versions tiene N+1 rows; query reverso devuelve snapshot histórico.

## PARTE 8 — Notifications dedup + retention

**Revisar**: §K.5/K.6 + §J.2.
**Existe**: outbox sin UNIQUE, sin cleanup.
**Falta**:
- UNIQUE `(group_id, category, (payload->>'idempotency_key'))` WHERE `payload ? 'idempotency_key'` (partial UNIQUE).
- Retention: relajar `_no_delete` guard con condición `dispatched_at < now() - interval '30 days'` permitido.
- Edge function cleanup separado.
**Riesgo**: backfill — outbox actual no carga `idempotency_key`. Aceptar drift histórico.

## PARTE 9 — Reputation: endorsers per-member

**Revisar**: §0.3 + §C.18.
**Existe**: `group_cultural_norms.endorsed_count integer` sin saber quién endorsó.
**Falta**: tabla `group_cultural_norm_endorsements(norm_id, membership_id, created_at)` append-only, **[F]** decisión doctrinal pendiente: ¿perdemos privacy si listamos endorsers?
**Acción**: si se quiere auditabilidad → mig CREATE TABLE + ALTER `endorse_*_norm` para insertar + incrementar count. Si no → diferir.

## PARTE 10 — Resources: ownership audit + group_documents subtype

**Revisar**: §0.3 + §C.8.
**Falta**:
- Emitter `resource.ownership_transferred` en `set_resource_ownership` (PARTE 3 lo cubre).
- Subtype `group_resource_documents`. Sin demanda hoy. Diferir.

## PARTE 11 — Future-proofing: workflows, AI, federation

**Diferir explícitamente**. No tocar hasta señal founder.

## PARTE 12 — Smoke tests end-to-end formales

Ver §N.

---

# N) SMOKE TESTS

> Cada test es un script `pgtap` ejecutable vía `SELECT * FROM _smoke_<scenario>()` con SECURITY DEFINER + cleanup automático. El existente `_smoke_money_flow()` (verificado en `pg_proc`) es el template.

## N.1 Identity + RLS

```sql
-- N.1.1: caller authenticated lee SU profile
-- N.1.2: caller authenticated NO lee profile de user en grupo aislado (post-PARTE 1)
-- N.1.3: caller authenticated SÍ lee profile de co-miembro
-- N.1.4: caller anon NO lee profiles
```

## N.2 Groups + Boundary

```sql
-- N.2.1: create_group → membership active del creator + emit group.created
-- N.2.2: invite_member → row en group_invites + group_events 'member.invited'
-- N.2.3: accept_invite → membership active + 'member.joined' emitido + 'member.invited' invite consumida
-- N.2.4: leave_group con balance != 0 → permission_denied (post-PARTE 5)
-- N.2.5: set_membership_state expelled → status='expelled' + 'member.state_changed'
```

## N.3 Authority

```sql
-- N.3.1: assert_permission con permission directo → OK
-- N.3.2: assert_permission sin permission → raises permission_denied:<perm>
-- N.3.3: assert_permission con mandate scope incluye permission → OK
-- N.3.4: assert_permission con mandate expirado → raises
-- N.3.5: assert_permission con mandate cross-grupo → raises (FK guard)
-- N.3.6: revoke_role_from_member para último admin → permission_denied:last_admin (post-fix)
```

## N.4 Rules

```sql
-- N.4.1: validate_rule_shape({trigger.money.expense_recorded + condition.amount_above + consequence.send_notification}) → OK
-- N.4.2: validate_rule_shape con shape_key inexistente → fail
-- N.4.3: create_engine_rule + publish_rule_version → group_rule_versions row 'active'
-- N.4.4: record_expense con monto > threshold + rule activa → group_rule_evaluations row matched=true + notifications_outbox row
-- N.4.5: record_expense con monto < threshold → group_rule_evaluations row matched=false (audit)
-- N.4.6: dual rule fire (mismo event, 2 rules activas) → 2 group_rule_evaluations rows
-- N.4.7: recursion: sanction.issued dispara otra rule que issue_sanction → depth=2, eventual abort en depth=5
-- N.4.8: idempotency: doble call evaluate_rules_for_event con mismo event → no duplica
-- N.4.9: cultural_norm.endorsed_count crosses threshold → trigger auto-promote → group_rules row + 'cultural_norm.promoted_to_rule'
```

## N.5 Money

```sql
-- N.5.1 (existe): _smoke_money_flow() — happy path
-- N.5.2: record_expense con client_id → 2da call retorna mismo transaction_id (idempotency)
-- N.5.3: record_expense con mandate inválido → raises
-- N.5.4: record_settlement FIFO cierra obligations correctamente (amount_outstanding decrementa)
-- N.5.5: reverse_transaction → nueva row con reversed_entry_id; balance neto = 0
-- N.5.6: split_breakdown jsonb roundtrip — V3-S1 picker scenarios
-- N.5.7: dispute_sanction → group_disputes opens con subject_kind='sanction'
-- N.5.8: record_settlement de sanction linked → cascade marca sanción
-- N.5.9: emit_mandate_expiring_events() idempotent — 2da call mismo día NO duplica
-- N.5.10: pay_sanction RPC (post-PARTE 5) — settle FIFO + status update
```

## N.6 Disputes

```sql
-- N.6.1: open_dispute + assign_mediator + record_dispute_resolution → status='resolved'
-- N.6.2: escalate_dispute_to_vote → group_decisions row creada + escalated_decision_id link
-- N.6.3: dispute resolution con outcome 'void_sanction' → cascada release
-- N.6.4: dispute_events atom guards — UPDATE/DELETE rejected
```

## N.7 Governance

```sql
-- N.7.1: start_vote → group_decisions status='open' + 'decision.started'
-- N.7.2: cast_vote 1 → seq=1; cast_vote 2 mismo voter → seq=2; current_vote_for retorna seq=2
-- N.7.3: cast_ranked_vote → múltiples rows con metadata.rank
-- N.7.4: finalize_vote 'membership' passed → set_membership_state invoked + member status mutado
-- N.7.5: finalize_vote 'rule_change' passed → publish_rule_version invoked
-- N.7.6: finalize_vote 'pool_charge' passed → record_pool_charge invoked + group_obligations row
-- N.7.7: group_decisions partial guard — UPDATE status='passed' bloquea cambio de title
-- N.7.8: cast_vote en decision con status='passed' → permission_denied (decision closed)
-- N.7.9: weighted vote — verify weight applied en tally
```

## N.8 Memory / Audit

```sql
-- N.8.1: record_system_event → row en group_events con uuid_id + cursor id
-- N.8.2: group_events atom guard — UPDATE rejected, DELETE rejected
-- N.8.3: group_events_recent paginated cursor by (created_at DESC, id DESC) — consistente
-- N.8.4: replay scenario (post-V3): re-eval rule contra event histórico no muta canónico
```

## N.9 Notifications

```sql
-- N.9.1: consequence.send_notification → notifications_outbox row pending
-- N.9.2: notifications_outbox partial guard — UPDATE de payload bloqueado
-- N.9.3: notifications_outbox DELETE pending bloqueado por _no_delete
-- N.9.4: dedup post-PARTE 8 — 2do send con mismo idempotency_key NO duplica
```

## N.10 Race conditions / locking

```sql
-- N.10.1: concurrent record_expense con mismo client_id en transacciones paralelas → 1 succeeds, otra fails con duplicate key
-- N.10.2: concurrent finalize_vote → solo una sucede (FOR UPDATE en decision)
-- N.10.3: concurrent settle FIFO → no double-spend (FOR UPDATE en obligation)
-- N.10.4: cast_vote concurrent del mismo voter → ambas insertan rows distintas con seq distintos; current_vote_for resuelve correctamente
```

## N.11 Replay tests (V3+)

Pendiente PARTE 11 si se implementa replay.

## N.12 RLS isolation

```sql
-- N.12.1: caller en grupo A ejecuta record_expense p_group_id=B → permission_denied (assert_member_of_group)
-- N.12.2: caller en grupo A SELECT group_events WHERE group_id=B → 0 rows (RLS qual)
-- N.12.3: mandate grupo A usado en RPC grupo B → assert_mandate_same_group raise
-- N.12.4: assign_role_to_member con membership grupo A + role grupo B → assert_member_role_same_group raise
```

---

# FIN DE ESPECIFICACIÓN

**Cierre del documento**:
- 25 primitivas mapeadas a 46 tablas reales + RPCs verificadas.
- 12 capas con boundaries, ownership e invariantes locked.
- Drift entre `PrimitivesArchitecture.md` y BD-real documentado punto por punto.
- 13 PARTES de plan (PARTE 0 — PARTE 12) con orden estricto + evidencia + smoke gate.
- Smoke tests por capa, incluyendo race + RLS isolation.

**Próximos pasos sugeridos** (orden):
1. Aplicar PARTE 1 RLS profiles (riesgo bajo, beneficio alto privacy).
2. Aplicar PARTE 2 (4 SQL en disco) tras revisión SQL.
3. Aplicar PARTE 3 (events faltantes) — desbloquea reglas con triggers nuevos.
4. PARTE 4 (outcome handlers restantes) — completa frontera engine↔voto.
5. PARTE 5 (money cleanup) — cierra V3-A4a.
6. Resto según señal founder.

**Reglas duras de la sesión**:
- NO crear `ledger_entries`, `system_events`, `vote_casts`, `group_governance_versions` sin doctrina firmada (varios ya son ficción).
- NO crear schema `ruul` (la convención `public._*` es la real).
- NO instalar `pg_cron`/`pg_net`/`pg_partman` sin discusión.
- Verificar con `mcp__supabase__execute_sql` ANTES de cualquier mig.
- Cada PARTE debe pasar su smoke antes de la siguiente.
