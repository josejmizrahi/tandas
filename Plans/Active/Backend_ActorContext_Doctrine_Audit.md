# Backend Audit — Actor-Centric / Context-Centric Doctrine Verification

**Status:** Audit-only. Cero DDL, cero drops, cero RPCs modificadas, cero Swift modificado.
**Fecha:** 2026-06-02.
**Verificado contra live DB** `wyvkqveienzixinonhum` (proyecto "ruul") vía MCP + 294 migrations en `supabase/migrations/` + código iOS en `ios/Packages/`.
**Docs previos consumidos:** `R0_ActorResourceRights.md`, `R0G_SupabaseHygiene_Audit.md`, `R0B0_LegacyResourceDependencyAudit.md`.

---

## 1. Resumen ejecutivo

**Pregunta final: ¿El backend actual de Ruul soporta la visión final (backend actor-centric, UX context-centric)?**

# Respuesta: **PARCIAL**

**Estructuralmente: SÍ.** Las 5 primitivas de la doctrina existen como tablas/RPCs canónicas, están pobladas, sincronizadas y verificadas en vivo:

- `actors` (232 rows: 154 person + 78 group + 0 legal_entity, **cero huérfanos en ambas direcciones**)
- `resources` única canónica (110 rows, `group_id` nullable, `canonical_owner_actor_id` 110/110 = 100% poblado)
- `resource_rights` universal (77 rows, whitelist de 15 kinds, shape doctrinal correcto)
- `actor_relationships` (tabla + constraints + RPCs correctos, whitelist de 14 types)
- Las 4 context views (`my_world_summary`, `group_world_summary`, `legal_entity_world_summary`, `actor_net_worth`) existen y delegan sin recalcular

**Operacionalmente: NO todavía.** Tres familias de problemas impiden declarar GREEN:

1. **Enforcement ausente (RED).** Los RPCs actor-céntricos nuevos (`grant_right`, `revoke_right`, `create_actor_relationship`, `end_actor_relationship`) solo chequean *autenticación*, no *autorización*: cualquier usuario logueado puede otorgarse OWN sobre cualquier recurso, revocar derechos ajenos o declararse shareholder de cualquier entidad. 3 de las 4 context views (`group_world_summary`, `legal_entity_world_summary`, `actor_net_worth`) son SECURITY DEFINER ejecutables por `anon` sin ningún gating — cualquier portador de la anon key puede volcar miembros, recursos, governance y net worth de cualquier grupo/entidad. `has_actor_authority` (doctrina D4) **no existe**.

2. **Integración incompleta (YELLOW).** Los flujos de producción no alimentan las primitivas nuevas: la creación de recursos (`create_group_resource`/`create_resource`) no genera rights → 33/110 resources tienen `canonical_owner_actor_id` sin OWN right activo que lo respalde. Las 77 rights existentes son 100% backfill (cero orgánicas, cero kinds distintos de OWN). `actor_relationships` tiene 0 filas. Persisten **3 write-paths de ownership paralelos vivos** (`resources.ownership_kind`/`owner_membership_id`, `resource_owners`, `resource_rights.OWN`) — solo el tercero es doctrina.

3. **Dominios group-centric por compat (YELLOW, aceptado por doctrina).** Memberships, Governance y Money siguen 100% acoplados a `group_id` + `membership_id` + `user_id`. La doctrina lo acepta explícitamente para esta fase; el audit documenta el costo de generalizarlos.

**El esqueleto es el correcto. Lo que falta no es re-arquitectura: es enforcement, cableado de flujos y migración de dominios — en ese orden.**

---

## 2. Tabla de estado por doctrina

| # | Doctrina | Estado | Evidencia clave |
|---|---|---|---|
| 1 | Actor como primitiva base (person/group/legal_entity, extensible) | ✅ **GREEN** | `actors` con CHECK whitelist de 3 kinds; UUIDs compartidos 1:1; forward-sync triggers activos; extensión a family/trust/company/dao = 1 ALTER del CHECK, sin modelo paralelo |
| 2 | Contexto como vista operativa (sin tabla `contexts`) | 🟡 **YELLOW** | Las 4 views existen y responden las 5 preguntas del contexto; pero 3/4 no tienen auth gating y `recent_activity` de legal entity es `[]` by design |
| 3 | Recursos únicos (una sola tabla canónica) | 🟡 **YELLOW** | `resources` es única tabla física ✅; `group_resources` es view compat ✅; pero ownership tiene 3 modelos vivos paralelos y la creación sigue group-gated |
| 4 | Rights como fuente de relevancia formal | 🟡 **YELLOW** | `resource_rights` universal con shape correcto ✅; pero sin autorización en grant/revoke, solo data de backfill (100% OWN), y los flujos de producción no la alimentan |
| 5 | Relationships como vínculos semánticos | 🟡 **YELLOW** | `actor_relationships` con shape correcto, exactly-one constraint, whitelist ✅; pero 0 rows, sin autorización, nada la consume excepto las views |
| 6 | Memberships ≠ Rights (no mezclar) | 🟡 **YELLOW** | La separación conceptual existe post-R.0C; pero los write-paths legacy de ownership-via-membership siguen vivos sin sincronizar a rights |
| 7 | Governance group-based aceptable, evolucionable | 🟡 **YELLOW** | 100% group-centric (aceptado); el costo de `actor_decisions` está acotado y documentado (§ H) |
| 8 | Money evolucionable a actor→actor | 🟡 **YELLOW** | 100% membership/group-coupled (aceptado, diferido a R.2 per doctrina D5); cero columnas actor en tablas money |

---

## 3. Inventario de tablas (clasificación)

Fuente: `list_tables` live DB (68 relations en `public`) + R0G audit.

### 3.1 CANONICAL — doctrina actor/context

| Tabla | Rows | Notas |
|---|---|---|
| `actors` | 232 | Parent table person/group/legal_entity. UUIDs compartidos. |
| `legal_entities` | 0 | 1:1 con actors. Schema validado por smoke; **sin uso en producción aún**. |
| `resources` | 110 | Única tabla física de recursos. `group_id` nullable, `canonical_owner_actor_id` 100%. |
| `resource_rights` | 77 | Universal, 15-kind whitelist. **Autoridad doctrinal de ownership.** |
| `actor_relationships` | 0 | Grafo semántico, 14-type whitelist, exactly-one object constraint. |
| `profiles` | 154 | Identity person (1:1 auth.users, 1:1 actors person). |
| `groups` | 78 | Identity group (1:1 actors group). |

### 3.2 COMPAT — views con INSTEAD OF triggers (drop candidato R.2)

| View | Redirige a | Dependencias |
|---|---|---|
| `group_resources` | `resources` (filtra `group_id IS NOT NULL`) | 74 funciones legacy |
| `group_resource_owners` | `resource_owners` | 5 funciones |
| `group_resource_rights` | `resource_right_subtype` | 11 funciones |
| `group_resource_capabilities` | `resource_capabilities` | 6 funciones |

### 3.3 LEGACY — preservadas, superseded por doctrina

| Tabla / columna | Rows | Estado |
|---|---|---|
| `resource_right_subtype` | 2 | Subtype rights-as-resources. Aislada ✅. Drop candidato R.1+. |
| `resource_owners` | 77 | Backfilled a `resource_rights.OWN`. **⚠️ Sigue recibiendo writes** vía `add_resource_owner`/`end_resource_owner` sin sincronizar a rights. |
| `resources.ownership_kind`, `resources.owner_membership_id`, `resources.ownership_metadata` | — | Columnas superseded; **⚠️ `set_resource_ownership` sigue escribiéndolas**. |
| `resource_capabilities` | 0 | Renombrada R.0B.1; decisión pendiente (metadata vs tabla). |

### 3.4 GROUP-DOMAIN — aceptables por doctrina #7 (compat), generalizables después

**Memberships/Roles:** `group_memberships` (155), `group_membership_events` (173), `group_roles` (226), `group_member_roles` (152), `group_role_permissions` (11,606), `group_role_assignment_events` (149), `permissions` (71), `group_mandates` (7), `group_mandate_events` (11), `membership_state_transitions_catalog` (14).

**Governance:** `group_decisions` (41), `group_decision_options` (5), `group_votes` (31), `group_rules` (141), `group_rule_versions` (145), `group_rule_evaluations` (381), `group_governance_versions` (10), `rule_shapes_catalog` (54), `decision_templates_catalog` (24), `action_catalog` (105), `group_rule_engine_quotas` (17), `group_purposes` (74).

**Money:** `group_resource_transactions` (101), `group_obligations` (72), `group_settlements` (27), `group_settlement_obligations` (22), `group_contributions` (1), `group_sanctions` (8), `group_sanction_payment_plans` (0).

**Social/Memoria:** `group_disputes` (7), `group_dispute_events` (18), `group_reputation_events` (34), `group_cultural_norms` (2), `group_dissolutions` (0), `group_events` (1,259), `group_invites` (73), `group_external_parties` (0), `group_comments` (0), `group_attachments` (0).

**Resource subtypes (FK a `resources`, polimorfía válida):** `group_resource_events` (2), `group_resource_funds` (2), `group_resource_slots` (2), `group_resource_spaces` (1), `group_resource_assets` (24), `group_resource_asset_valuations` (20), `group_resource_series` (1), `group_resource_bookings` (13), `group_rsvp_actions` (3), `group_check_in_actions` (0).

### 3.5 DEPRECATED — marcadas para drop

| Tabla | Rows | Notas |
|---|---|---|
| `group_calendar_events` | 1 | DEPRECATED D.24 PHASE 1 (comment en tabla). |
| `group_calendar_event_attendees` | 1 | DEPRECATED D.24. |
| `group_calendar_event_reminders` | 0 | DEPRECATED D.24. |

### 3.6 INFRA / AUDIT

`group_resources_direct_insert_audit` (25), `notifications_outbox` (282), `notification_tokens` (0), `notification_preferences` (0).

### 3.7 UNKNOWN

Ninguna — todas las relations quedaron clasificadas.

---

## 4. Inventario de RPCs clave

Verificado vía `pg_proc` en live DB (346 funciones públicas, 42 smokes).

### 4.1 Contrato actor-centric R.1 — existencia y estado

| RPC | Existe | Auth | **Autorización** | Notas |
|---|---|---|---|---|
| `my_world_summary()` | ✅ | ✅ `auth.uid()`-scoped | ✅ (self-scoped) | 10 secciones, LIMIT 20, delega net worth. **Único RPC de contexto completo.** |
| `group_world_summary(p_group_id)` | ✅ | ❌ **ninguno** | ❌ **ninguna** | SECDEF + EXECUTE a `anon`/PUBLIC. Vuelca members/resources/governance de cualquier grupo. |
| `legal_entity_world_summary(p_actor_id)` | ✅ | ❌ **ninguno** | ❌ **ninguna** | SECDEF + `anon`. Vuelca shareholders/beneficiaries/obligations. |
| `actor_net_worth(p_actor_id)` | ✅ | ❌ **ninguno** | ❌ **ninguna** | SECDEF + `anon`. Net worth de cualquier actor consultable por cualquiera. |
| `grant_right(9-arg, p_holder_actor_id)` | ✅ | ✅ | ❌ **ninguna** | Cualquier authenticated puede otorgar OWN/SELL/TRANSFER de cualquier recurso a cualquier actor. |
| `revoke_right(p_right_id)` | ✅ | ✅ | ❌ **ninguna** | Cualquier authenticated puede revocar cualquier right por id. |
| `actor_has_right(actor, resource, kind)` | ✅ | — (STABLE read) | n/a | Usa solo rights activos (revoked/expired/starts/ends) ✅. EXECUTE a `anon`. |
| `create_actor_relationship(7-arg)` | ✅ | ✅ | ❌ **ninguna** | Cualquier authenticated puede declarar relaciones a nombre de cualquier subject actor. |
| `list_actor_relationships(actor, direction, include_inactive)` | ✅ | — | n/a | Soporta in/out/both ✅. EXECUTE a `anon`. |
| `end_actor_relationship(p_relationship_id)` | ✅ | ✅ | ❌ **ninguna** | Cualquier authenticated puede terminar cualquier relación. |
| `create_legal_entity(5-arg)` / `update_legal_entity(6-arg)` | ✅ | ✅ | ⚠️ sin ownership check en update | — |

### 4.2 RPCs de doctrina que NO existen

| RPC | Doctrina | Impacto |
|---|---|---|
| `has_actor_authority(actor, action)` | D4 (governance ortogonal a rights) | Sin ella, ningún RPC puede componer "autoridad interna + right". Es el building block de la autorización faltante. |
| `list_actor_resources(actor_id)` | R.0B §6 | iOS no puede listar recursos por actor sin pasar por `my_world_summary` completo. |
| `transfer_resource` | D4 (ejemplo canónico SELL+authority) | Sin path de transferencia actor→actor. |
| `create_resource` personal (sin group) | D2 | **No hay forma de crear un recurso personal**: `create_resource(p_group_id,…)` y `create_group_resource` exigen `group_id` + `assert_permission(group_id, 'resources.create')`. El único resource personal en DB (1) fue insertado por smoke vía SQL directo. |

### 4.3 Overloads ambiguos / peligrosos

| Función | Overloads | Riesgo |
|---|---|---|
| `revoke_right` | `(p_right_id uuid)` vs `(p_resource_id uuid, p_reason text, p_client_id text)` | **Ambiguo real** para llamadas con 1 uuid posicional. iOS usa JSON nombrado (no afecta hoy), pero PL/pgSQL interno debe usar named params. |
| `grant_right` | 9-arg universal (actor) vs 8-arg legacy (membership) | Coexistencia intencional R.0C.2b. iOS llama la legacy. |
| `create_group_resource` | 8-arg vs 10-arg | Fragmentación D.24. |
| `set_decision_rules` | 4-arg vs 6-arg vs 10-arg | Fragmentación; consolidar en R.1+. |

### 4.4 Acoplamiento legacy en funciones (live DB)

| Métrica | Valor |
|---|---|
| Funciones que aún referencian `group_resources` (nombre legacy) en su prosrc | **77** |
| Funciones que referencian `membership_id` | **162** |
| Funciones que referencian `public.actors` | **16** |
| Funciones que referencian la universal `public.resource_rights` | **15** |

El centro de gravedad operativo del backend sigue siendo membership/group; la capa actor es minoría absoluta (16/346 ≈ 5%).

---

## 5. Trabajo ejecutado (secciones A–J)

### A. Inventario canónico

Ver § 3. Resultado: **0 tablas UNKNOWN**, 7 CANONICAL, 4 COMPAT, ~6 LEGACY (tablas+columnas), ~45 GROUP-DOMAIN, 3 DEPRECATED.

### B. Verificación Actor-Centric — ✅ GREEN

Verificado en vivo (2026-06-02):

| Check | Resultado |
|---|---|
| ¿Todas las personas tienen actor? | ✅ 154/154 profiles → actor person (0 sin actor) |
| ¿Todos los grupos tienen actor? | ✅ 78/78 groups → actor group (0 sin actor) |
| ¿Todas las legal_entities tienen actor? | ✅ 0/0 (vacío — schema validado por smoke, sin uso real) |
| ¿Hay actores huérfanos? | ✅ 0 (person sin profile: 0, group sin group: 0, legal_entity sin row: 0) |
| ¿Hay actors sin correspondencia esperada? | ✅ 0 |
| Forward-sync activo | ✅ triggers `trg_sync_actor_from_profile` / `trg_sync_actor_from_group` (R.0A.1) |
| ¿Evoluciona a family/trust/company/dao sin modelo paralelo? | ✅ Solo requiere ampliar el CHECK `actor_kind` + (opcional) tabla subtype 1:1 estilo `legal_entities` |

**Caveat:** el sync es solo de *existencia* (AFTER INSERT). `display_name` drift entre profiles/groups y actors es aceptado por diseño (R.0A.1). No hay sync de DELETE (no aplica: groups/profiles no se borran físicamente).

### C. Verificación Resources — 🟡 YELLOW

| Check | Resultado |
|---|---|
| ¿`resources` es tabla canónica? | ✅ Sí — única tabla física, renombrada de `group_resources` (R.0B.1) |
| ¿`group_resources` es view compat? | ✅ Sí — con 3 INSTEAD OF triggers, filtra `group_id IS NOT NULL` |
| ¿`resource_owners` es autoridad o histórico? | ⚠️ **Ambiguo**: doctrinalmente histórico (backfilled R.0C.2a), pero `add_resource_owner`/`end_resource_owner`/`set_resource_ownership` **siguen vivas y escriben ahí sin sincronizar a `resource_rights`** |
| ¿`resources.group_id` sigue requerido en algún flujo? | ⚠️ Sí — **todos** los flujos de creación (`create_group_resource` ×2, `create_resource`) lo exigen + RLS de la tabla es 100% group-based |
| ¿`canonical_owner_actor_id` está 100% poblado? | ✅ 110/110 |
| ¿`canonical_owner_actor_id` se sincroniza desde OWN rights? | ⚠️ **Parcial**: el trigger `trg_resource_rights_sync_canonical_owner` existe y funciona, pero **33/110 resources tienen canonical owner sin ningún OWN right activo que lo respalde** (poblados por el trigger defensivo R.0B.2 = group_id, no por rights). Solo 77/110 están respaldados por rights. |

**Hallazgo central:** existen **3 modelos vivos paralelos de ownership** —

1. `resources.ownership_kind` + `owner_membership_id` (escrito por `set_resource_ownership`)
2. `resource_owners` (escrito por `add_resource_owner` / `end_resource_owner`)
3. `resource_rights.OWN` (universal, doctrina, escrito por `grant_right` 9-arg)

Solo (3) sincroniza `canonical_owner_actor_id`. Los flujos (1) y (2) son los que usa producción/iOS hoy. Esto viola "no deben existir modelos vivos paralelos" a nivel *ownership* (la tabla resources sí es única).

### D. Verificación Rights — 🟡 YELLOW (shape) / 🔴 RED (enforcement)

| Check | Resultado |
|---|---|
| ¿`resource_rights` universal tiene shape correcto? | ✅ Sí — holder_actor_id FK actors, 15-kind whitelist (OWN/USE/MANAGE/VIEW/SELL/TRANSFER/GOVERN/BENEFICIARY/PLEDGE/LIEN/LEASE/COLLECT_INCOME/PAY_EXPENSES/AUDIT/APPROVE), percent CHECK [0..100], temporal bounds, source_decision_id FK |
| ¿`resource_right_subtype` legacy está aislada? | ✅ Sí — 2 rows, compat view la cubre, cero contaminación de la universal |
| ¿Permite múltiples derechos por resource? | ✅ Estructuralmente sí (unique parcial por resource+holder+kind). **En producción: 0 resources con >1 right** |
| ¿`actor_has_right` usa solo active rights? | ✅ Sí — revoked_at/expired_at NULL + ventana starts/ends (verificado en prosrc + smoke R.0C.2b casos 5-6) |
| ¿`grant_right`/`revoke_right` operan sobre universal? | ✅ Los overloads nuevos sí; los legacy operan sobre subtype vía compat (intencional) |
| ¿Hay overloads ambiguos? | ⚠️ Sí — `revoke_right(uuid)` vs `revoke_right(uuid, text, text)` (ver § 4.3) |

**Gaps críticos:**
- ❌ `grant_right`/`revoke_right` universales **no tienen autorización** — solo `auth.uid() IS NOT NULL`. Cualquier usuario puede otorgarse OWN de cualquier recurso o revocar rights ajenos.
- ⚠️ Las 77 rights son 100% backfill (`right_kind='OWN'`, metadata.legacy_owner_id). **Cero rights orgánicas** creadas por flujo de producto.
- ⚠️ La creación de recursos NO otorga OWN right → todo recurso nuevo nace sin rights (drift creciente: ya hay 33).
- ⚠️ RLS de `resource_rights`: SELECT `qual=true` para todo authenticated → cualquier usuario ve todos los rights (y por ende el patrimonio) de todos.

### E. Verificación Relationships — 🟡 YELLOW

| Check | Resultado |
|---|---|
| ¿Soporta actor→actor? | ✅ Sí (`object_actor_id`) |
| ¿Soporta actor→resource? | ✅ Sí (`object_resource_id`) |
| ¿Exactly-one object constraint existe? | ✅ Sí — CHECK constraint + mirror en RPC con mejor error |
| ¿Relationship_type whitelist existe? | ✅ Sí — 14 types (owns, controls, member_of, admin_of, beneficiary_of, leased_to, managed_by, employed_by, guarantor_of, trustee_of, shareholder_of, custodian_of, debtor_to, creditor_of) |
| ¿`list_actor_relationships` permite in/out/both? | ✅ Sí + `include_inactive` |

**Gaps:**
- ❌ `create_actor_relationship`/`end_actor_relationship` sin autorización (cualquier authenticated declara/termina cualquier relación de cualquier subject).
- ⚠️ **0 rows en producción.** El grafo existe pero nadie lo ha usado fuera de smokes.
- ⚠️ Nada lo consume excepto `my_world_summary` (controlled_entities/obligations) y `legal_entity_world_summary` (shareholders/beneficiaries). Governance/money/rule engine lo ignoran.
- ⚠️ La doctrina pide `member_of` como relationship — hoy la membresía vive solo en `group_memberships`; no hay sync membership → relationship `member_of`.

### F. Verificación Context Views — 🟡 YELLOW (estructura) / 🔴 RED (auth)

| Check | `my_world_summary` | `group_world_summary` | `legal_entity_world_summary` | `actor_net_worth` |
|---|---|---|---|---|
| ¿Consume rights/relationships correctamente? | ✅ | ✅ | ✅ | ✅ (solo OWN/BENEFICIARY activos) |
| ¿Recalcula lógica duplicada? | ✅ No — delega a `actor_net_worth` | ✅ No — delega | ✅ No — delega | n/a (es la fuente) |
| ¿Devuelve secciones vacías estables? | ✅ `[]` | ✅ `[]` | ✅ `[]` (recent_activity `[]` by design) | ✅ |
| ¿Tiene LIMITs? | ✅ LIMIT 20/sección | ✅ LIMIT 20 | ✅ LIMIT 20 | n/a (agregación) |
| ¿Tiene auth checks? | ✅ `auth.uid()` scoped | ❌ **NO** | ❌ **NO** | ❌ **NO** |
| EXECUTE grants | authenticated | **anon + PUBLIC** | **anon + PUBLIC** | **anon + PUBLIC** |

**Las 4 views responden las 5 preguntas de la doctrina de contexto** (qué actor veo, qué recursos le son relevantes, qué derechos explican la relevancia, qué relaciones lo conectan, qué decisiones/reglas/actividad le pertenecen). La estructura es correcta.

**Pero 3 de 4 son volcado público:** al ser SECURITY DEFINER (bypassean RLS) + EXECUTE a `anon`, exponen a cualquier portador de la anon key: lista de miembros de cualquier grupo, sus recursos con valores, governance, shareholders y obligaciones de cualquier legal entity, y net worth de cualquier persona. **Esto es un blocker de lanzamiento, no de arquitectura.**

**Limitación adicional:** `actor_net_worth` lee `resources.metadata->>'estimated_value'` — 0 resources lo tienen poblado en producción → net worth siempre retorna 0. Estructuralmente correcto, funcionalmente vacío.

### G. Verificación Memberships — 🟡 YELLOW

Schema (`canonical_schema_01`): `group_memberships(id, group_id NOT NULL FK groups, user_id FK profiles [nullable solo para placeholders post-mig 20260529210833], status, membership_type, …)` + `UNIQUE(group_id, user_id)`.

| Pregunta | Respuesta |
|---|---|
| ¿Qué depende de `membership_id`? | ~162 funciones + FKs desde: `group_member_roles`, `group_mandates`, `group_sanctions`, `group_votes` (voter_membership_id), `group_obligations` (owed_by/owed_to), `group_settlements` (paid_by/paid_to), `group_contributions`, `group_resource_transactions` (from/to/paid_by), `resource_owners`, `resource_right_subtype.holder_membership_id` |
| ¿Qué depende de `group_id`? | Todo el dominio group (45+ tablas con `group_id NOT NULL`) + RLS (`is_group_member`, `has_group_permission`) + `assert_permission` |
| ¿Qué depende de `user_id`? | `group_memberships.user_id` → profiles; `group_decisions.created_by/executed_by`; `group_events.actor_user_id`; RLS por `auth.uid()` |
| ¿Qué habría que cambiar para `actor_memberships`? | (1) `member_actor_id FK actors` en `group_memberships` (o tabla nueva + compat view); (2) repoint de la cadena de FKs (8+ tablas); (3) rewire de RPCs de membership (~12-15); (4) decidir semántica de "grupo miembro de grupo" en quorum/votos |
| ¿Qué se debe mantener en R.1? | Todo tal cual. `group_memberships` user-based funciona para personas; los actores no-persona pueden vincularse vía `actor_relationships.member_of` (camino barato, sin tocar governance) |

**Mezclas detectadas (doctrina #6 — membership ownership vs resource ownership vs permissions vs rights):**

1. `resources.owner_membership_id` + `ownership_kind` — ownership expresado como membership (legacy vivo).
2. `resource_owners.membership_id` — ownership via membership (legacy vivo).
3. `resource_right_subtype.holder_membership_id` — rights subtype via membership (aislado, compat).
4. `grant_right` legacy 8-arg (`p_holder_membership_id`) — **es el que iOS llama hoy**.
5. Permissions (governance: `group_role_permissions`) correctamente separadas de rights ✅ — la confusión es solo del lado ownership.

### H. Verificación Governance — 🟡 YELLOW (aceptable por doctrina)

| Pregunta | Respuesta |
|---|---|
| ¿Qué tan group-centric sigue siendo? | 100%. `group_decisions.group_id NOT NULL`, `created_by/executed_by → profiles`, `group_votes.voter_membership_id NOT NULL FK group_memberships`, rule engine evalúa `WHERE group_id = event.group_id`, `execute_decision` hace `assert_permission(group_id, 'decisions.execute')` y despacha consecuencias a membership_ids |
| ¿Qué puede quedarse así? | Todo, para R.1. La doctrina acepta governance group-based. Los grupos son actors (R.0A), así que "decisiones de un grupo" ya son "decisiones de un actor group" semánticamente |
| ¿Qué debe generalizarse después? | (1) `proposer_actor_id`/`executor_actor_id` en decisions; (2) `voter_actor_id` en votes (para que legal entities voten); (3) rule engine con scope actor (no solo group); (4) `decision_templates_catalog` ya es global ✅ — solo necesita aplicarse a actores no-grupo |
| ¿Qué rompería si intentamos `actor_decisions` hoy? | `execute_decision` (dispatch a obligations/memberships group-scoped), `finalize_vote` (quorum sobre group_memberships activos), `cast_vote` (FK voter_membership_id), todo el rule engine (d14-d16: predicados sobre membership), realtime publications, y el contrato iOS completo de Decisions |

**Nota positiva:** `action_catalog` + `resolve_action_governance` + `request_or_execute_action` (D.22) son un layer de governance *por acción* que ya es independiente del actor-type del ejecutor — es el mejor punto de enganche futuro para `has_actor_authority`.

### I. Verificación Money — 🟡 YELLOW (aceptable, diferido a R.2)

Columnas de partes verificadas en vivo:

| Tabla | Identificación de partes | actor_id |
|---|---|---|
| `group_obligations` | `owed_by_membership_id NOT NULL`, `owed_to_membership_id`, `owed_to_kind` (member/pool/vendor/group), `group_id NOT NULL` | ❌ ninguna |
| `group_settlements` | `paid_by_membership_id NOT NULL`, `paid_to_membership_id`, `paid_to_kind`, `group_id NOT NULL` | ❌ |
| `group_resource_transactions` | `from_membership_id`, `to_membership_id`, `paid_by_membership_id`, `group_id NOT NULL` | ❌ |
| `group_contributions` | `membership_id NOT NULL`, `group_id NOT NULL` | ❌ |
| `group_sanctions` | `target_membership_id NOT NULL`, `issued_by_membership_id`, `group_id NOT NULL` | ❌ |

| Pregunta | Respuesta |
|---|---|
| ¿Money usa actor_id? | ❌ No, en ninguna tabla ni RPC |
| ¿Money usa group_id? | ✅ Sí, NOT NULL en todas |
| ¿Money usa membership_id? | ✅ Sí, todas las partes son membership_id |
| ¿Qué bloquea actor→actor ledger? | (1) NOT NULL `group_id` + FKs a `group_memberships`; (2) RPCs (`record_expense`, `record_settlement`, `record_pool_charge`, `record_payout`) reciben membership_ids; (3) RLS y `assert_permission` son group-scoped; (4) FIFO settlement itera `group_obligations` por membership; (5) auditoría va a `group_events` (group-scoped) |
| ¿Qué puede esperar a R.2? | Todo lo anterior — consistente con doctrina D5 ("R.0 NO toca money"). El camino: columnas `debtor_actor_id`/`creditor_actor_id` nullable + backfill desde membership.user_id + overloads de RPCs |

### J. Verificación iOS Contract — 🟡 YELLOW

**Backend para R.1: COMPLETO en lectura.** Los 10+ RPCs del contrato existen en la DB (ver § 4.1). **El gap de R.1A–R.1F está mayormente del lado iOS, no del backend** — con las excepciones de abajo.

| RPC | Backend | Binding iOS |
|---|---|---|
| `my_world_summary` | ✅ | ✅ Completo: `RuulRPCClient.myWorldSummary()` → `CanonicalMyWorldRepository` → `MyWorldStore` → `PersonalHomeView` + `CurrentContextStore`/`ContextSwitcherView` (R.0H.1–4, R.1A) |
| `actor_net_worth` | ✅ | ✅ Implícito (embebido en my_world_summary.net_worth) |
| `group_world_summary` | ✅ | ❌ Sin protocol method, repository, store ni view |
| `legal_entity_world_summary` | ✅ | ❌ Sin binding |
| `actor_has_right` | ✅ | ❌ Sin binding (necesario para gatear botones de UI) |
| `grant_right` universal (actor) | ✅ | ❌ iOS llama el **legacy 8-arg** (`GrantRightParams.pHolderMembershipId`) |
| `revoke_right(p_right_id)` | ✅ | ❌ iOS llama el **legacy** (`RevokeRightParams.pResourceId`) |
| `create/list/end_actor_relationship` | ✅ | ❌ Sin binding |
| `create_legal_entity` / `update_legal_entity` | ✅ | ❌ Sin binding |

**¿R.1A–R.1F puede avanzar sin backend nuevo?**

- **R.1A (Personal Home + Context Switcher):** ✅ SÍ — ya shipped (R.0H + R.1A iOS).
- **R.1B (Group context view):** ✅ SÍ con backend actual *si se acepta el gap de auth* — el RPC existe; falta solo binding iOS. ⚠️ Recomendado NO exponer en producción hasta agregar auth gating al RPC.
- **R.1C (Legal entity view + CRUD):** ✅ SÍ — RPCs existen; falta binding iOS.
- **R.1D (Rights management UI):** ⚠️ PARCIAL — grant/revoke/actor_has_right existen, pero (a) **sin autorización backend** (blocker de seguridad), (b) falta `list_actor_resources` o un RPC de "rights por resource/actor" para listar (hoy habría que parsear my_world_summary).
- **R.1E (Relationships UI):** ⚠️ PARCIAL — CRUD existe pero sin autorización backend (mismo blocker).
- **R.1F (Money actor-aware):** ❌ NO — requiere backend nuevo (R.2 per doctrina).

**Dónde SÍ falta backend (para R.1 completo):**
1. Autorización en `grant_right`/`revoke_right`/`create_actor_relationship`/`end_actor_relationship` (= crear `has_actor_authority` y componerla).
2. Auth gating en `group_world_summary`/`legal_entity_world_summary`/`actor_net_worth`.
3. `list_actor_resources(actor_id)` o equivalente.
4. RPC de creación de recurso personal (sin group_id).
5. Wiring: creación de recursos → OWN right automático.

---

## 6. Riesgos

| # | Riesgo | Severidad | Detalle |
|---|---|---|---|
| R1 | **Escalada de privilegios en rights** | 🔴 CRÍTICA | `grant_right`(universal) sin autorización: cualquier usuario autenticado puede auto-otorgarse OWN/SELL/TRANSFER de cualquier recurso. SECDEF bypassea RLS. |
| R2 | **Information disclosure vía context views** | 🔴 CRÍTICA | `group_world_summary`/`legal_entity_world_summary`/`actor_net_worth` ejecutables por `anon`: members, recursos, valores, shareholders y net worth de cualquiera son públicos para quien tenga la anon key. |
| R3 | **Falsificación de relaciones** | 🔴 ALTA | `create_actor_relationship` sin autorización: cualquiera puede declararse shareholder/trustee/creditor de cualquier actor. Cuando las views/decisiones consuman el grafo, esto se vuelve vector de fraude. |
| R4 | **RLS deshabilitado** | 🔴 ALTA | `group_rule_engine_quotas` y `action_catalog` tienen RLS **disabled** — expuestas completas a anon/authenticated vía PostgREST (advisory crítico de Supabase). |
| R5 | **Drift de ownership** | 🟡 MEDIA | 3 write-paths paralelos (legacy ownership, resource_owners, rights). Cada recurso nuevo aumenta la divergencia (ya 33/110 sin OWN right). El día que se quiera hacer rights la única autoridad, habrá que re-backfillear. |
| R6 | **Privacidad de rights/relationships** | 🟡 MEDIA | RLS SELECT `qual=true` en `actors`/`resource_rights`/`actor_relationships`/`legal_entities`: todo usuario autenticado ve el patrimonio y vínculos de todos. |
| R7 | **Overload ambiguo `revoke_right`** | 🟡 BAJA | Llamadas posicionales con 1 uuid son ambiguas. Mitigado con named params. |
| R8 | **net_worth vacío** | 🟡 BAJA | 0/110 resources con `estimated_value` → toda la UX de net worth muestra 0. Riesgo de percepción, no técnico. |

---

## 7. Gaps

1. **`has_actor_authority` no existe** (doctrina D4) — es el prerequisito de toda la autorización actor-céntrica.
2. **Autorización ausente** en los 6 RPCs de escritura actor-céntricos (rights ×2, relationships ×2, legal entity update, y `grant_right` legacy no valida holder coherente).
3. **Auth gating ausente** en 3 de 4 context views.
4. **No hay path de creación de recursos personales** (sin grupo): ni RPC ni RLS lo permiten.
5. **La creación de recursos no otorga rights** → la fuente de relevancia formal no se alimenta sola.
6. **No hay sync membership → `actor_relationships.member_of`** — el grafo no refleja la participación real.
7. **`list_actor_resources` / `transfer_resource` no existen.**
8. **iOS no tiene bindings** para 8 de los 10 RPCs del contrato actor-céntrico.
9. **Money/Governance/Memberships sin columnas actor** (aceptado por doctrina, pero es el gap estructural más grande pendiente).
10. **`legal_entities` sin uso real** (0 rows) — toda la rama legal_entity de la doctrina está validada solo por smokes.

---

## 8. Qué está correcto (GREEN)

- **`actors` como parent table real** con UUIDs compartidos, forward-sync, cero huérfanos, extensible a nuevos kinds sin modelo paralelo.
- **`resources` como única tabla física** con compat layer impecable (96 funciones legacy siguen funcionando sin tocar prosrc).
- **`resource_rights` universal con el shape doctrinal exacto** (15 kinds, percent, temporal, source_decision_id) y `actor_has_right` con semántica de "active right" correcta.
- **`actor_relationships` con el shape doctrinal exacto** (exactly-one object, 14 types, in/out/both).
- **`my_world_summary`** — el patrón de referencia: auth-scoped, delega, LIMIT, secciones estables.
- **Separación conceptual rights vs permissions** (governance) — son sistemas ortogonales como pide D4.
- **canonical_owner como cache, no autoridad** — naming explícito (`canonical_` prefix) y trigger de sync respetan D3.
- **El pipeline iOS de My World** (R.0H.1–4 + R.1A context switcher) — el patrón para los demás contexts ya existe y funciona.

## 9. Qué está provisional (YELLOW)

- Las 4 compat views + 96 funciones legacy que dependen de ellas (plan de migración por olas ya documentado en R0G).
- `resource_owners` y las columnas `ownership_kind`/`owner_membership_id` (legacy vivo, pendiente de congelar).
- `resource_right_subtype` (aislada, 2 rows).
- Governance/Money/Memberships group-centric (aceptado explícitamente por doctrina #7/#8 — generalizables en R.2+).
- Los datos de rights (100% backfill OWN) y relationships (0 rows) — el modelo existe pero la realidad operativa aún no pasa por él.
- iOS llamando los RPCs legacy de rights.

## 10. Qué está mal (RED)

1. **Autorización inexistente en la capa actor-céntrica de escritura** (rights, relationships). Contradice D4 ("RPCs sensibles chequean ambos") y bloquea cualquier lanzamiento real.
2. **Context views públicas** (anon-executable, SECDEF, sin gating) — `group_world_summary`, `legal_entity_world_summary`, `actor_net_worth`.
3. **RLS deshabilitado en `group_rule_engine_quotas` y `action_catalog`.**
4. **Los write-paths de ownership de producción no alimentan la fuente de verdad doctrinal** — si esto no se corrige, `resource_rights` se vuelve una tabla muerta de backfill y la doctrina queda en papel.

---

## 11. Recomendación de fases correctivas

### R.1-SEC — Hardening de autorización (PRIMERO, antes de cualquier UI nueva)

1. Crear `has_actor_authority(p_actor_id, p_action)`:
   - person actor → `auth.uid() = actor_id`
   - group actor → `has_group_permission(actor_id, p_action)` (los groups ya son actors)
   - legal_entity actor → `actor_relationships` type `controls`/`trustee_of` activo, o metadata de governance de la entity
2. Componer autorización en los 6 RPCs de escritura: `grant_right` exige (caller controla al holder actual del OWN, o caller tiene `resources.transfer` en el grupo scope, o resource sin rights → caller es creador); `revoke_right` exige (caller = holder, o caller controla al granter); `create_actor_relationship` exige caller controla al subject_actor.
3. Auth gating en views: `group_world_summary` → exigir membership activa o group visibility public; `legal_entity_world_summary`/`actor_net_worth` → exigir `caller controla/es el actor` (vía `has_actor_authority`).
4. REVOKE EXECUTE FROM anon/PUBLIC en las 4 views + `actor_has_right` + `list_actor_relationships`.
5. `ENABLE ROW LEVEL SECURITY` en `group_rule_engine_quotas` y `action_catalog` (con policies read-only para authenticated).
6. Endurecer RLS de privacidad: `resource_rights`/`actor_relationships` SELECT solo para holder/subject/object o co-members.

### R.1-WIRE — Cableado de flujos a la fuente de verdad

1. `create_group_resource`/`create_resource`/wrappers → otorgar OWN right automático al actor dueño (group actor o owner_membership→person actor) en el mismo INSERT.
2. `add_resource_owner`/`end_resource_owner`/`set_resource_ownership` → dual-write a `resource_rights` (o deprecarlas redirigiendo a `grant_right`).
3. Backfill one-shot de los 33 resources sin OWN right.
4. Sync `group_memberships` activas → `actor_relationships.member_of` (trigger AFTER INSERT/UPDATE).
5. RPC `create_personal_resource` (group_id NULL, OWN right al creador) + RLS owner-based en `resources` para `group_id IS NULL`.
6. `list_actor_resources(actor_id)` + `transfer_resource`.

### R.1-iOS — Bindings de contexto (puede ir en paralelo con R.1-WIRE, después de R.1-SEC)

1. Bindings de `group_world_summary` / `legal_entity_world_summary` (+ stores + views).
2. Migrar `GrantRightParams`/`RevokeRightParams` a la firma universal (holder_actor_id / right_id).
3. Bindings de `actor_has_right` + relationships CRUD + legal entity CRUD.

### R.2-MONEY — Ledger actor→actor (per doctrina D5)

1. `debtor_actor_id`/`creditor_actor_id` nullable en obligations/settlements/transactions + backfill desde membership.user_id.
2. Overloads actor-aware de `record_expense`/`record_settlement`/`record_pool_charge`/`record_payout`.
3. Ledger personal (group_id NULL) con RLS por actor.

### R.2-GOV — Governance generalizable (opcional, según necesidad de producto)

1. `proposer_actor_id`/`voter_actor_id` columnas nullable.
2. `execute_decision` branch por scope (group vs actor).

### R.3-CLEANUP — Hygiene (ya documentado en R0G)

Drops de compat views, overloads, columnas legacy — solo después de que R.1-WIRE estabilice.

---

## 12. Clasificación final

| Área | Calificación | Justificación |
|---|---|---|
| **Actors** | 🟢 **GREEN** | Primitiva real, poblada, sincronizada, cero huérfanos, extensible sin modelo paralelo |
| **Resources** | 🟡 **YELLOW** | Tabla única canónica ✅, pero ownership con 3 write-paths paralelos vivos + creación 100% group-gated + sin path personal |
| **Rights** | 🟡 **YELLOW** | Shape doctrinal correcto ✅, pero sin autorización (RED de seguridad), 100% backfill, flujos de producción no la alimentan |
| **Relationships** | 🟡 **YELLOW** | Shape doctrinal correcto ✅, pero sin autorización, 0 uso, nada la consume operativamente |
| **Context Views** | 🟡 **YELLOW** | Estructura y delegación correctas ✅, my_world_summary GREEN; pero 3/4 sin auth (RED de seguridad) |
| **Memberships** | 🟡 **YELLOW** | Person-only por diseño (aceptable R.1); mezclas membership-ownership legacy vivas |
| **Governance** | 🟡 **YELLOW** | 100% group-centric — aceptado por doctrina #7; camino de generalización acotado y documentado |
| **Money** | 🟡 **YELLOW** | 100% membership/group-coupled — aceptado por doctrina D5/#8; cero bloqueos imprevistos para R.2 |
| **iOS Contract** | 🟡 **YELLOW** | Backend de lectura completo; iOS solo tiene binding de my_world_summary; 8/10 RPCs sin consumir; aún llama rights legacy |
| **Supabase Hygiene** | 🔴 **RED** | 2 tablas con RLS disabled, SECDEF views anon-executable sin gating, RPCs de escritura sin autorización, 4 familias de overloads, 96 funciones sobre compat views |

**Resumen: 1 GREEN, 8 YELLOW, 1 RED.**

---

## 13. Respuesta a la pregunta final

> ¿El backend actual de Ruul soporta la visión final?
> Backend actor-centric. UX context-centric. Resources únicos. Rights explican relevancia. Relationships explican vínculos. Memberships explican participación. Governance y Money generalizables después.

# **PARCIAL** — con esqueleto correcto y enforcement pendiente

**Evidencia a favor (la visión ES alcanzable sobre este backend, sin re-arquitectura):**

1. Actor es primitiva base real: 232 actors, 1:1 con profiles/groups, forward-sync, cero huérfanos, extensible por CHECK whitelist.
2. Resources es tabla única: el rename R.0B fue físico, no cosmético; las 96 funciones legacy operan vía compat views sin tablas duplicadas.
3. Rights universal existe con el shape exacto de la doctrina (15 kinds, percent, temporal, multi-right por resource).
4. Relationships existe con el shape exacto (actor→actor, actor→resource, exactly-one, 14 types).
5. Las 4 context views responden las 5 preguntas del contexto delegando a rights/relationships sin lógica duplicada.
6. Governance y Money son group-centric *como la doctrina acepta* — y como los grupos ya son actors, su generalización es additive (columnas nullable + overloads), no destructiva.

**Evidencia en contra (por qué no es "Sí" todavía):**

1. **La doctrina dice "rights explican relevancia" — pero hoy rights no gobiernan nada:** ningún flujo de producción crea/consulta rights para decidir acceso; la autorización real sigue siendo `has_group_permission` + membership; las 77 rights son backfill estático y 33 resources ya divergieron.
2. **La doctrina D4 exige componer authority + rights en RPCs sensibles — `has_actor_authority` no existe** y los RPCs actor-céntricos no componen nada: cualquier usuario autenticado puede reescribir la realidad patrimonial (grant/revoke/relationship sin autorización).
3. **La capa de contexto es hoy un canal de fuga de datos** (anon-executable, sin gating) — incompatible con exponer el backend a usuarios reales.
4. **Relationships explican vínculos... que nadie ha creado** (0 rows) y memberships no se proyectan al grafo.

**Conclusión operativa:** el trabajo R.0 construyó la *estructura* correcta y completa de la doctrina. Lo que falta para pasar de PARCIAL a SÍ es la fase de **enforcement + cableado** (R.1-SEC y R.1-WIRE de § 11): hacer que los flujos reales pasen por las primitivas nuevas y que las primitivas nuevas se defiendan solas. Nada de eso requiere romper o re-modelar lo que existe.
