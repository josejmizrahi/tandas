# R.0G — Supabase Hygiene / Schema Consolidation Audit

**Status:** Audit-only. **NO drops, NO renames, NO behavior changes, NO iOS.**
**Verified against live DB** `wyvkqveienzixinonhum` 2026-06-01 vía MCP.
**Founder lock:** ordenar sin romper. Solo después de R.0G estable: R.0H iOS PersonalHomeView pivot.

---

## 0. Executive summary

R.0 backend está 100% completo. La hygiene revela 5 categorías que necesitan documentación o limpieza eventual:

| Categoría | Hallazgo | Acción |
|---|---|---|
| **Tablas legacy preservadas** | 1 (`resource_right_subtype`, 2 rows) | Drop candidate R.1+ |
| **Compat views activas** | 4 views con 12 INSTEAD OF triggers | Drop candidate R.1+ tras migrar 78 funciones legacy |
| **Columnas deprecated** | 2 en `resources` (`group_id`, `ownership_kind`/`owner_membership_id`) + 1 en `resource_rights_subtype` (`holder_membership_id`) | Drop candidate R.1+ |
| **Function overloads peligrosos** | 4 (grant_right, revoke_right, create_group_resource, set_decision_rules) | 2 son R.0C.2b coexistencia esperada; 2 son legacy fragmentation |
| **Smoke residue patterns** | 1 leak conocido (smoke_groups → append-only guard) | Aceptado, documentado |

**Blockers para iOS pivot (R.0H):** NINGUNO. Backend es funcional + idempotente. Hygiene es cosmética y diferible a R.1+.

**Recomendación:** GO R.0H después de revisar este audit. Drops esperan R.1+ con plan de migración explícito por función.

---

## 1. Tabla inventory — 66 relations en `public`

### 1.1 R.0 canonical (8 tablas + 4 compat views)

| Nombre | Kind | Rows | Status doctrinal | Notas |
|---|---|---|---|---|
| `actors` | table | 232 | ✅ canonical R.0A | Parent table, person/group/legal_entity |
| `legal_entities` | table | 0 (smoke creates+cleans) | ✅ canonical R.0A | 1:1 con actors |
| `actor_relationships` | table | 0 (smoke residue) | ✅ canonical R.0D | Grafo semántico, 14-type whitelist |
| `resources` | table | 99 | ✅ canonical R.0B.1 (renamed from `group_resources`) | Universal, group_id nullable |
| `resource_owners` | table | 77 | ⚠️ deprecated R.0C.2a | Backfilled a `resource_rights` OWN; preservada como histórico |
| `resource_rights` | table | 77 | ✅ canonical R.0C.2a | Universal con 15-kind whitelist |
| `resource_capabilities` | table | 0 | ⚠️ deprecated en favor de metadata? | Renamed from `group_resource_capabilities` R.0B.1. Aún no se ha decidido. |
| `resource_right_subtype` | table | 2 | ⚠️ legacy preservado R.0C.2a | Subtype de `resource_type='right'`. Sub-semantica polimórfica preservada por compat. |
| `group_resources` | **view** | 92 (filtered) | ✅ R.0B.1+R.0B.2 compat | INSTEAD OF triggers redirigen a `resources` filtrando `group_id IS NOT NULL` |
| `group_resource_owners` | **view** | 77 | ✅ R.0B.1 compat | INSTEAD OF redirigen a `resource_owners` |
| `group_resource_rights` | **view** | 2 | ✅ R.0B.1+R.0C.2a compat | INSTEAD OF redirigen a `resource_right_subtype` (legacy) |
| `group_resource_capabilities` | **view** | 0 | ✅ R.0B.1 compat | INSTEAD OF redirigen a `resource_capabilities` |

### 1.2 Pre-R.0 group_* (47 tables + 1 view)

Conservadas tal cual. Incluyen subtype tables (`group_resource_funds`, `group_resource_assets`, `group_resource_events`, `group_resource_slots`, `group_resource_spaces`, `group_resource_transactions`, `group_resource_bookings`, `group_resource_asset_valuations`, `group_resource_series`) que dependen de `resources` vía FK.

Notable: `group_resources_direct_insert_audit` (D.24 P2B-1) — append-only audit donde se registra cada INSERT a `resources`.

### 1.3 Identity + catalogs (8 otras)

- `profiles` (154 rows, FK to auth.users)
- `action_catalog`, `decision_templates_catalog`, `membership_state_transitions_catalog`, `rule_shapes_catalog` (D.22+)
- `notification_preferences`, `notification_tokens`, `notifications_outbox`
- `permissions`

---

## 2. Function overload inventory (4 peligrosos + 1 extension)

| Función | Overloads | Razón | Riesgo |
|---|---|---|---|
| `set_decision_rules` | 3 | Evolución D.24 (4 args → 6 args → 10 args). Latest = canonical. | ⚠️ Bajo. Las 3 coexisten; callers podrían hit cualquiera. **Acción R.1+:** consolidar a single canonical y dropear las 2 intermedias. |
| `create_group_resource` | 2 | D.24 P2B fragmentation (8 args + 10 args con `p_metadata, p_client_id`). Documentado en R.0B.0 audit. | ⚠️ Medio. Smart router en iOS usa específicamente la 10-arg. **Acción R.1+:** drop 8-arg después de confirmar zero callers vía monitoring. |
| `grant_right` | 2 | Legacy subtype (8 args) + Universal R.0C.2b (9 args). **Coexistencia INTENCIONAL.** | ✅ Bajo. iOS hit legacy, R.0+ callers hit universal. Diferenciados por signature. |
| `revoke_right` | 2 | Legacy (3 args) + Universal R.0C.2b (1 arg). **Coexistencia INTENCIONAL.** | ⚠️ Medio. **Ambigüedad para 1-uuid calls** — callers PL/pgSQL deben usar named params. iOS usa JSON nombrado, no afecta. |
| `unaccent` | 2 | Postgres extension `unaccent`. | ✅ N/A. |

---

## 3. Trigger inventory (62 totales relevantes)

### 3.1 R.0 forward-sync (2 triggers)

- `trg_sync_actor_from_profile` (AFTER INSERT on profiles) — R.0A.1
- `trg_sync_actor_from_group` (AFTER INSERT on groups) — R.0A.1

### 3.2 R.0 derive/canonical (3 triggers)

- `trg_resources_derive_canonical_owner_actor_id` (BEFORE INSERT on resources) — R.0B.2 defensive
- `trg_resource_rights_derive_holder_actor_id` (BEFORE INSERT on `resource_right_subtype`) — R.0C.1. **Nota:** trigger sobrevivió rename R.0C.2a; function name todavía dice `_resource_rights_*` pero opera sobre subtype. **Cosmetic drift, sin impacto funcional.**
- `trg_resource_rights_sync_canonical_owner` (AFTER I/U/D on resource_rights) — R.0C.2a

### 3.3 R.0 compat views (12 INSTEAD OF triggers)

4 views × 3 ops (INSERT/UPDATE/DELETE) — todos redirigen a la tabla canónica correspondiente.

`trg_compat_group_resources_insert` preserva intent_marker o marca `'legacy_view_write'` (R.0B.1 audit Option B).

### 3.4 Audit/touch (varios)

- `trg_log_group_resources_direct_insert` (AFTER INSERT on `resources`) — D.24 P2B-1 audit, sigue funcionando post-rename
- 4× `*_touch_updated_at` triggers — R.0 housekeeping
- `_assert_resource_owner_same_group`, `_assert_role_event_same_group`, `_assert_mandate_event_same_group` — cross-tenant guards

### 3.5 Append-only guards (atom_* — 25+ triggers)

Aplican a tablas `group_*_events`, `group_votes`, `group_attachments`, `group_comments`, `group_governance_versions`, `group_rule_evaluations`, `group_rule_versions`, `group_settlement_obligations`, `group_resource_bookings`, `group_resource_transactions`, `group_resource_asset_valuations`, `group_check_in_actions`, `group_rsvp_actions`, `group_dispute_events`, `group_role_assignment_events`, `group_membership_events`, `group_reputation_events`, `group_mandate_events`.

**Críticos para smoke residue:** `atom_no_delete_guard` en `group_role_assignment_events` (FOR EACH STATEMENT) bloquea cualquier DELETE statement contra `groups` que cascade — por eso smokes que crean groups leakeen.

---

## 4. RLS policies inventory

- **63 tables con RLS habilitada**
- **116 policies totales**
- Mayoría de policies legacy del esquema canónico pre-R.0
- **R.0 nuevas:** `actors_select_authenticated`, `legal_entities_select_authenticated`, `resource_rights_select_authenticated`, `actor_relationships_select_authenticated`

**Naming inconsistencies detectadas:** N/A explícito desde la consulta. **R.1+** podría hacer una pasada de naming para alinear: `<table>_select_authenticated`, `<table>_insert_*`, etc.

---

## 5. Smoke inventory (41 totales)

### 5.1 R.0 smokes (11 — todos verdes)

`_smoke_r0a_actor_registry`, `_smoke_r0a1_forward_sync`, `_smoke_r0b1_compat_layer`, `_smoke_r0b2_nullable_group_canonical_owner_cache`, `_smoke_r0c1_holder_actor_retrofit`, `_smoke_r0c2a_universal_rights`, `_smoke_r0c2b_rights_rpcs`, `_smoke_r0d_relationship_graph`, `_smoke_r0e1_actor_net_worth`, `_smoke_r0e2_my_world_summary`, `_smoke_r0f_world_summaries`.

### 5.2 Pre-R.0 smokes (30)

Cubrir governance, money, disputes, rules engine, identity RLS, etc.

### 5.3 Residue patterns documentados

| Smoke | Leak | Causa |
|---|---|---|
| `_smoke_r0a_actor_registry`, `_smoke_r0a1_forward_sync` | 1 auth.user + 1 profile + 1 actor por corrida | `session_replication_role='replica'` requiere superuser; cleanup interno cae a `insufficient_privilege` |
| `_smoke_r0a1_forward_sync` | 1 group (+ relacionados) | `atom_no_delete_guard` FOR EACH STATEMENT en `group_role_assignment_events` impide DELETE cascade desde groups |
| `_smoke_membership_boundary`, `_smoke_inbox`, `_smoke_r0d_relationship_graph` | Similar patrón | Mismo append-only guard |

**Convención aceptada:** smokes leakeen 1 group + relacionados por corrida; cleanup manual con SQL surgical si es necesario.

---

## 6. Columnas deprecated por tabla

| Tabla | Columna | Status | Drop candidate |
|---|---|---|---|
| `resources` | `group_id` | nullable post-R.0B.2, scope/cache legacy | R.1/R.2 cuando navegación iOS no la use |
| `resources` | `ownership_kind` | superseded por `canonical_owner_actor_id` + `resource_rights.OWN` | R.1+ |
| `resources` | `owner_membership_id` | superseded | R.1+ |
| `resources` | `ownership_metadata` | rara vez usado | Mantener (jsonb low-cost) |
| `resource_right_subtype` | `holder_membership_id` | superseded por `holder_actor_id` post-R.0C.1 | R.1/R.2 |
| `resource_right_subtype` | `right_kind` whitelist | legacy {access, membership, seat, benefit, other} | R.1+ si se decide consolidar con universal |
| `resource_owners` | toda la tabla | superseded por `resource_rights.OWN` | R.1+ tras confirmar sync trigger es robusto |

---

## 7. Compat view dependencies — qué se rompe si dropeamos

| Compat view | Dependencias (RPCs legacy referenciándola) | Bloqueo drop hasta |
|---|---|---|
| `group_resources` | 74 funciones (R.0B.0 audit) | Migrar 17 writers + 47 readers a `resources` directo |
| `group_resource_owners` | 5 funciones | Migrar 2 writers (`add_resource_owner`, `end_resource_owner`) |
| `group_resource_rights` | 11 funciones (incluye legacy grant_right, revoke_right operando sobre subtype) | Migrar legacy RPCs o dropearlas |
| `group_resource_capabilities` | 6 funciones (`enable_resource_capability`, `disable_resource_capability`, `add_event_reminder`, `remove_event_reminder`) | Migrar a `resource_capabilities` directo |

**Total: 96 funciones referencian las 4 compat views.** Cero pueden migrarse en R.0G (audit-only). R.1+ requiere plan de ola por ola.

---

## 8. Drop candidates por fase

### R.1 (early candidates — bajo riesgo)

- 2 `create_group_resource` 8-arg overload (después de monitoring confirme zero callers)
- 2 `set_decision_rules` overloads intermedios (4-arg + 6-arg)
- `resource_right_subtype.holder_membership_id` columna (después de migrar las 2 filas a usar holder_actor_id como única referencia)
- Smoke leak: refactor `_smoke_r0a*` + `_smoke_r0d*` para NO crear group nuevo (reusar existente)

### R.2 (mid risk — requiere plan de migración)

- `resources.group_id` columna (después de UI/RPCs migradas a actor-based scoping)
- `resources.ownership_kind`, `resources.owner_membership_id` (cuando rights sea fuente única)
- `resource_owners` table (after triple-confirm OWN backfill consistency)
- Compat views `group_resource_*` (4 views — after 96 functions migran a canonical names en su prosrc)
- `resource_right_subtype` table (after subtype semantics migran a metadata o se decide deprecation)

### R.3 (high risk — fundamental architecture)

- `group_resources_direct_insert_audit` (después de R.2 cleanup — si ya no hay writes via compat view, no hay legacy_view_write)
- Atom append-only guards si modelo de auditoría cambia
- 50+ pre-R.0 `group_*` tables que aún no se decidió cómo encajan en Actor/Resource doctrine

---

## 9. Blockers para iOS pivot (R.0H)

**Resultado del audit: NINGÚN blocker técnico.**

- ✅ Backend foundation 100% funcional
- ✅ R.0E.2 my_world_summary + R.0F group/legal_entity views funcionando
- ✅ Compat layer transparente para iOS legacy (ningún archivo iOS llama `from('group_resources')` directo; todo via RPC)
- ✅ Forward-sync `profiles/groups → actors` activo
- ✅ Sync trigger canonical_owner_actor_id activo
- ✅ Cero RPCs preexistentes modificadas durante R.0 (preserva contratos iOS)

**Riesgos documentados (aceptables):**
- ⚠️ `metadata->>'estimated_value'` no está populado en producción → net_worth retorna 0 hasta data ingestion. iOS debe manejar gracefully empty state.
- ⚠️ Smoke residue acumulado (~1 group + actors por corrida de varios smokes). No afecta producción, sí afecta cleanup en sesiones de dev.
- ⚠️ `revoke_right(uuid)` overload ambiguity en PL/pgSQL si caller usa positional args. iOS usa named JSON — no afecta.

---

## 10. Recomendación operativa

1. **GO R.0H** (iOS PersonalHomeView pivot) — backend está listo.
2. R.1+ first wave: consolidar overloads peligrosos no-coexistencia (set_decision_rules 4-arg/6-arg drops, create_group_resource 8-arg drop) y refactor smokes para reducir leak.
3. R.2+ second wave: migrar 96 funciones de compat names → canonical names en su prosrc (ola por ola por dominio). Solo entonces drop compat views.
4. R.3+ tercera wave: decisión arquitectural sobre 50+ `group_*` tables pre-R.0 — qué se mueve a actor model y qué se queda como subtype semantics.

**No requiere migración de hygiene en R.0G.** El sistema funciona; este audit es documentación durable para futuras fases.

---

## 11. Resumen ejecutivo final

| Métrica | Valor |
|---|---|
| Tablas totales | 66 (8 R.0 + 49 pre-R.0 + 8 catalogs/identity + 1 audit) |
| Views compat R.0 | 4 (con 12 INSTEAD OF triggers) |
| Vistas dependientes | 1 (`group_event_calendar_view`) |
| Funciones con overloads peligrosos | 4 |
| Triggers críticos R.0 (forward-sync + derive + sync + audit) | 8 |
| Append-only guards (`atom_*`) | 25+ |
| RLS policies | 116 (sobre 63 tablas) |
| Smokes totales | 41 (11 R.0 + 30 pre-R.0) |
| **Blockers iOS pivot** | **0** |

**Conclusión:** GO R.0H. Hygiene cleanup difírido a R.1/R.2/R.3 según matriz de riesgo arriba.
