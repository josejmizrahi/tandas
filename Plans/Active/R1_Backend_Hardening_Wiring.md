# R.1-BE — Actor/Context Backend Hardening & Wiring

**Status:** SHIPPED 2026-06-02.
**Live DB:** `wyvkqveienzixinonhum` (proyecto "ruul") — todas las migrations aplicadas vía MCP.
**Insumo:** Audit PR #131 (`Backend_ActorContext_Doctrine_Audit.md`) — estado pre-R.1 = PARCIAL.
**Restricciones respetadas:** cero Swift, cero iOS, cero UI, cero drops agresivos, compat views intactas, `group_*` tables intactas.

---

## 1. Resumen ejecutivo

R.1 convirtió el backend R.0 de "estructura correcta pero provisional" a "backend
actor/context listo para producto". Las tres familias de problemas del audit quedaron resueltas:

1. **Enforcement (era RED)** → GREEN: `has_actor_authority` existe; los 6 write RPCs
   actor-céntricos componen autorización; las 3 context views sensibles tienen gating;
   anon no puede ejecutar nada del contrato; RLS habilitado y scoped en tablas críticas.
2. **Cableado (era YELLOW)** → GREEN: todo resource nuevo genera OWN right automático
   (trigger chokepoint); los write-paths legacy de ownership hacen dual-write a
   `resource_rights`; backfill de los 33+ resources sin OWN; `create_personal_resource`
   y `list_actor_resources` existen; memberships se proyectan a `member_of`.
3. **Governance/Money group-centric (YELLOW aceptado)** → sin cambios, diferido a R.2
   per doctrina (los grupos ya son actors, la generalización es additive).

---

## 2. Slices ejecutadas (orden obligatorio cumplido)

| Slice | Migration | Qué hace |
|---|---|---|
| R.1-SEC.1 | `r1sec1_has_actor_authority_and_summary_gating` | `has_actor_authority(actor, action)` (D4) + gating en `actor_net_worth` / `group_world_summary` / `legal_entity_world_summary` / `list_actor_relationships` (patrón rename a `*_unscoped` interna + wrapper gated) + REVOKE anon |
| R.1-SEC.2 | `r1sec2_harden_write_rpcs` | Autorización compuesta en `grant_right` (9-arg) / `revoke_right` (1-arg) / `create_actor_relationship` / `end_actor_relationship` / `update_legal_entity`; `create_legal_entity` crea `controls` creator→entity |
| R.1-SEC.3 | `r1sec3_rls_critical_cleanup` | ENABLE RLS en `action_catalog` + `group_rule_engine_quotas`; SELECT policies scoped en `resource_rights` / `actor_relationships` / `legal_entities`; REVOKE anon en las 5 tablas |
| R.1-SEC smoke | `r1sec_smoke_actor_authority` | `_smoke_r1sec_actor_authority()` — 10 casos |
| R.1-WIRE.1 | `r1wire1_backfill_missing_own_rights` | Backfill 35 OWN rights faltantes (33 del audit + 2 residuo smoke) con verificación inline |
| R.1-WIRE.2 | `r1wire2_auto_own_right_on_resource_insert` | Trigger AFTER INSERT en `resources` → OWN 100% automático al `canonical_owner_actor_id` (chokepoint que cubre TODOS los flujos de creación) |
| R.1-WIRE.3 | `r1wire3_legacy_ownership_dual_write` | `add_resource_owner` / `end_resource_owner` / `set_resource_ownership` hacen dual-write a `resource_rights.OWN` (Opción A — ver §4) |
| R.1-WIRE.3b | `r1wire3b_fix_compat_owners_capabilities_insert` | **Fix de bug pre-existente R.0B.1**: compat INSTEAD OF INSERT de owners/capabilities perdía defaults (`id` NULL) — `add_resource_owner` estaba roto en producción desde el rename |
| R.1-WIRE.4 | `r1wire4_personal_resource_and_list_actor_resources` | `create_personal_resource` (group_id NULL + OWN al caller) + `list_actor_resources` (gated) |
| R.1-WIRE smoke | `r1wire_smoke_resource_rights_wiring` | `_smoke_r1wire_resource_rights_wiring()` — 8 casos |
| R.1-REL.1 | `r1rel1_membership_member_of_projection` | Trigger en `group_memberships` proyecta `member_of` + backfill 148 memberships activas |
| R.1-REL.2 | `r1rel2_legal_entity_relationship_helpers` | `add_legal_entity_controller` / `_beneficiary` / `_shareholder` gated por `entity.manage` |
| R.1-REL smoke | `r1rel_smoke_relationship_wiring` | `_smoke_r1rel_relationship_wiring()` — 5 casos |
| R.1-CONTRACT.1 | `r1contract_smoke_backend_contract` | `_smoke_r1_backend_contract()` — contrato completo iOS |
| R.1-SEC.4 | `r1sec4_revoke_public_anon_write_rpcs` | REVOKE PUBLIC/anon residual en write RPCs + `my_world_summary` (default ACL de Postgres nunca revocado en R.0) con verificación inline |

**Todos los smokes verdes, corridos ≥2 veces back-to-back (idempotencia verificada).**

---

## 3. Modelo de autorización (locked)

### has_actor_authority(p_actor_id, p_action) → boolean

| Actor kind | Regla |
|---|---|
| `person` | `auth.uid() = actor_id` |
| `group` | `has_group_permission(actor_id, action)` directo, + mapping doctrina→catálogo: `context.view`→`group.read`, `finance.view`→`records.read`, `resources.view`→`resources.read`, `resources.manage`→`resources.manage_ownership`, `relationships.view`→`group.read`, `relationships.manage`→`group.update`, `entity.manage`→`group.update` |
| `legal_entity` | relación activa `controls`/`trustee_of`/`admin_of` del caller sobre la entity, o creator fallback (`actors.metadata.created_by_uid`) |

### Gating de lecturas

| RPC | Regla |
|---|---|
| `group_world_summary` | miembro activo OR `has_actor_authority(group, 'context.view')` |
| `legal_entity_world_summary` | `has_actor_authority(entity, 'context.view')` |
| `actor_net_worth` | self OR miembro activo (group actor) OR `has_actor_authority(actor, 'finance.view')` |
| `list_actor_relationships` | full si self/authority; si no, solo relaciones donde el caller participa |
| `list_actor_resources` | self OR `has_actor_authority(actor, 'resources.view')` |
| `actor_has_right` | authenticated only (solo retorna boolean) |

### Hardening de escrituras

| RPC | Regla |
|---|---|
| `grant_right` no-ejecutivo | caller MANAGE/OWN sobre resource OR `has_actor_authority(canonical_owner, 'resources.manage')` |
| `grant_right` ejecutivo (OWN/SELL/TRANSFER/LIEN/PLEDGE) | caller OWN OR `has_actor_authority(canonical_owner, 'resources.transfer')` |
| `revoke_right` | caller es holder OR MANAGE/OWN OR `resources.manage` authority |
| `create_actor_relationship` | subject=caller OR `relationships.manage` authority; tipos sensibles siempre requieren authority |
| `end_actor_relationship` | authority sobre subject u object, o creador (`metadata.created_by_uid`) |
| `update_legal_entity` | `has_actor_authority(entity, 'entity.manage')` |
| helpers `add_legal_entity_*` | `has_actor_authority(entity, 'entity.manage')` |

---

## 4. Decisiones tomadas

1. **Patrón rename + wrapper para gating de summaries.** En vez de copiar los cuerpos
   jsonb grandes, las funciones originales se renombraron a `_*_unscoped` (internas,
   sin grants) y los nombres públicos son wrappers gated. Cero riesgo de corromper la
   lógica de agregación; el contrato iOS no cambia.
2. **Dual-write (Opción A) para legacy ownership**, no delegación a `grant_right`
   (Opción B). Razón: la Opción B re-ejecutaría la autorización actor-céntrica con
   semántica distinta a la group-céntrica que los RPCs legacy garantizan a sus callers
   (iOS llama estos RPCs con `has_group_permission` gating); habría roto flujos existentes.
3. **Chokepoint de creación = trigger AFTER INSERT en `resources`**, no modificación de
   las ~26 RPCs writer. Cubre RPCs, wrappers, compat views e inserts directos de una sola vez.
4. **`paused` NO cierra `member_of`** — es participación temporalmente suspendida;
   `removed`/`left`/`banned`/`suspended` sí cierran.
5. **Mapping de acciones doctrina → permission keys existentes** para group actors,
   en vez de seedear keys nuevas en el catálogo `permissions` (menos invasivo; el seed
   de keys actor-céntricas queda para cuando governance se generalice en R.2).

---

## 5. Hallazgos / bugs encontrados

1. **`add_resource_owner` estaba roto en producción desde R.0B.1** (2026-06-01): el
   compat INSTEAD OF INSERT de `group_resource_owners` usaba `SELECT NEW.*` que pierde
   los defaults de la tabla (id → NULL → violación NOT NULL). Mismo bug en capabilities.
   Fix en `r1wire3b`. Descubierto por el smoke R.1-WIRE.
2. **PUBLIC EXECUTE residual**: las funciones R.0 hacían `GRANT EXECUTE TO authenticated`
   pero nunca `REVOKE FROM PUBLIC` → anon podía ejecutarlas vía PUBLIC (mitigado por los
   checks internos de `auth.uid()`). Fix en `r1sec4`.
3. **Los smokes R.0 (pre-R.1) que llaman `grant_right`/`create_actor_relationship` con
   usuarios sin autoridad ya no pasan** — esperado: la autorización nueva los bloquea.
   Eran validaciones one-shot de R.0; los smokes R.1 los reemplazan.

---

## 6. Clasificación post-R.1

| Área | Pre-R.1 (audit) | Post-R.1 |
|---|---|---|
| Actors | 🟢 GREEN | 🟢 GREEN |
| Resources | 🟡 YELLOW | 🟢 GREEN (ownership con fuente única + dual-write legacy + path personal) |
| Rights | 🟡 YELLOW / 🔴 enforcement | 🟢 GREEN (autorización + wiring + backfill completo) |
| Relationships | 🟡 YELLOW | 🟢 GREEN (autorización + member_of projection + helpers entity) |
| Context Views | 🟡 YELLOW / 🔴 auth | 🟢 GREEN (gating completo, anon revocado) |
| Memberships | 🟡 YELLOW | 🟢 GREEN para R.1 (proyectadas al grafo; generalización actor queda R.2) |
| Governance | 🟡 YELLOW (aceptado) | 🟡 YELLOW — **diferido a R.2** per doctrina |
| Money | 🟡 YELLOW (aceptado) | 🟡 YELLOW — **diferido a R.2** per doctrina |
| iOS Contract | 🟡 YELLOW | 🟢 GREEN backend (los 14+ RPCs existen y son seguros); bindings iOS = R.1-iOS (fuera de scope BE) |
| Supabase Hygiene | 🔴 RED | 🟡 YELLOW (RLS crítico resuelto; quedan compat views SECDEF + warnings legacy pre-existentes — ver §7) |

---

## 7. Qué queda YELLOW / diferido a R.2

1. **Governance actor-aware** (`proposer_actor_id`/`voter_actor_id`, decisiones de
   legal entities) — diferido per doctrina.
2. **Money actor→actor** (`debtor_actor_id`/`creditor_actor_id` en obligations/
   settlements/transactions + overloads de RPCs) — diferido per doctrina D5.
3. **Compat views SECURITY DEFINER** (4 views R.0B.1 + `group_event_calendar_view`):
   advisors los marcan ERROR pero son intencionales (compat layer); drop planificado
   para R.2/R.3 cuando las ~96 funciones legacy migren (plan en R0G audit).
4. **~112 funciones legacy group-céntricas ejecutables por anon** (warning advisors,
   pre-existente): todas tienen checks internos de auth/permission. Sweep masivo de
   REVOKE queda para R.2/R.3 hygiene (riesgo de romper flujos si se hace sin audit caso
   por caso).
5. **`resource_owners` / `resources.ownership_kind` / `owner_membership_id`**: siguen
   vivos como legacy con dual-write — el drop es R.2/R.3 (prohibido en R.1).
6. **Permission keys actor-céntricas** (`context.view`, `finance.view`, etc.) no
   seedeadas en el catálogo `permissions` — se resuelven vía mapping en
   `has_actor_authority`; seed real cuando governance se generalice.
7. **iOS bindings** del contrato actor-céntrico (R.1-iOS): `group_world_summary`,
   `legal_entity_world_summary`, `list_actor_resources`, rights/relationships CRUD,
   `create_personal_resource` — el backend está listo; el frontend es el siguiente ciclo.

---

## 8. Respuesta a la pregunta final

> ¿El backend ya soporta completamente la visión?
> Backend actor-centric. UX context-centric. Resources únicos. Rights explican
> relevancia. Relationships explican vínculos. Memberships explican participación.
> Governance y Money pueden generalizarse después.

# **Sí para R.1 backend.**

- **Backend actor-centric** ✅ — actors es la primitiva base; authority y rights se
  evalúan por actor; el contrato completo es actor-céntrico y seguro.
- **UX context-centric** ✅ (backend-ready) — las 4 context views existen, gated, y
  responden las 5 preguntas del contexto; falta solo el binding iOS.
- **Resources únicos** ✅ — una sola tabla física; ownership con fuente única
  (`resource_rights.OWN`) + dual-write legacy sin drift.
- **Rights explican relevancia** ✅ — todo resource tiene OWN; creación genera OWN;
  `list_actor_resources` explica relevancia por `right_kind`; la autorización de
  grant/revoke compone rights + authority.
- **Relationships explican vínculos** ✅ — grafo poblado (148 member_of + helpers para
  entity relationships), con autorización.
- **Memberships explican participación** ✅ — proyectadas automáticamente al grafo.
- **Governance y Money actor-aware** → **diferidos a R.2** (como la doctrina acepta;
  los grupos ya son actors, la generalización es additive, no destructiva).
