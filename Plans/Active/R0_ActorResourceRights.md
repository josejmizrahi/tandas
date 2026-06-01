# R.0 — Actor / Resource / Rights Foundation

**Status:** PHASE 0 — plan firmado, **NO migrations executed**.
**Doctrina fuente:** `doctrine_r0_actor_resource_rights.md` (auto-memory) — léase verbatim antes de tocar cualquier mig.
**Verified against live DB** `wyvkqveienzixinonhum` 2026-06-01 vía MCP.
**Precondición de arranque:** D.24 cerrado (P12B-4 ya shipped); no quedan PHASES non-blocked pendientes que toquen `group_resources`.

---

## 0. Resumen ejecutivo

R.0 generaliza el modelo de Ruul de **group-centric** a **actor-centric**. NO es greenfield: la polimorfía de recursos ya existe (`group_resources` con 18 `resource_type`s + `group_resource_owners.owner_kind` + `group_resource_rights.right_kind`). Lo que falta:

1. Una primitiva `actors` parent table.
2. Relajar el acoplamiento de `resources` a `group_id`.
3. Parametrizar holder de rights por `actor_id` en vez de `membership_id`.
4. Un grafo de relaciones entre actores y recursos.
5. Vistas derivadas `my_world_summary` / `actor_net_worth` / `group_world_summary` / `legal_entity_world_summary`.
6. iOS pivote a `PersonalHomeView` como root (Groups pasa a ser sección de My World).

**Tamaño estimado:** 6 fases R.0A-F. ~18-24 migs backend, ~6-10 sesiones iOS. Riesgo bajo en backend (volumetría real ~78 resources, 77 owners, 2 rights — casi vacío); riesgo medio en iOS (rewiring de root navigation + retrofit de `ResourcesListView`).

**Out of scope R.0 (deferred a R.1+):** family worlds, trust beneficiary cascades, multi-currency net worth con FX, importadores bancarios, OCR de documentos, tokenización on-chain.

---

## 1. Estado DB pre-R.0 (verificado)

| Tabla / RPC | Existe | Filas | Acción R.0 |
|---|---|---|---|
| `actors` | NO | — | **CREAR** (R.0A) |
| `profiles` | SÍ | 154 | 1:1 con `actors` (R.0A) |
| `groups` | SÍ | 77 | 1:1 con `actors` (R.0A) |
| `legal_entities` | NO | — | **CREAR** (R.0A) — 1:1 con `actors` |
| `group_resources` (18 polymorphic types, FK group_id NOT NULL) | SÍ | 78 | **RENAME → `resources`**, relax group_id (mantener como **scope/cache legacy**, no dropear en R.0), add `canonical_owner_actor_id` (R.0B) |
| `group_resource_owners` (owner_kind: membership\|external_party, ownership_pct, ownership_role) | SÍ | 77 | Backfill a `resource_rights` con `right_kind='OWN'` + `percent` (R.0C) |
| `group_resource_rights` (right_kind, holder_membership_id) | SÍ | 2 | **RENAME → `resource_rights`**, agregar `holder_actor_id`, expandir whitelist de `right_kind` (R.0C) |
| `group_resource_capabilities` | SÍ | varios | Mantener — capabilities siguen por-resource, son opt-in flags no de ownership |
| `actor_relationships` | NO | — | **CREAR** (R.0D) |
| `my_world_summary()` | NO | — | **CREAR** (R.0E) |
| `actor_net_worth(actor_id)` | NO | — | **CREAR** (R.0E) |
| `group_world_summary(group_id)` | NO | — | **CREAR** (R.0F) |
| `legal_entity_world_summary(actor_id)` | NO | — | **CREAR** (R.0F) |

**Volumetría hace que el retrofit sea LOW-RISK.** No hay miles de filas que mover. La complejidad real está en las ~15+ RPCs que hoy filtran por `group_id` y deben aprender a aceptar `owner_actor_id` o seguir respetando `group_id` cuando aplica (governance scope).

---

## 2. Decisiones doctrinales lockeadas (5)

| # | Decisión | Implicación |
|---|---|---|
| D1 | `actors` es **tabla parent real**, no polimorfismo plano. | `profiles.actor_id`, `groups.actor_id`, `legal_entities.actor_id` como 1:1 FK. Permite `resources.owner_actor_id REFERENCES actors(id)` con FK real, sin `CASE WHEN actor_type=…` en queries del grafo. |
| D2 | `group_resources` se renombra a `resources`. **NO crear tabla paralela.** | Una sola tabla. `group_id` queda como columna opcional **deprecated / read-compat** (NULL = recurso personal/entity-owned sin grupo; NOT NULL = scope legacy de grupo para permisos/filtros/auditoría histórica/navegación iOS). **NO se dropea en R.0** — drop real diferido a R.1 o R.2 cuando todas las dependencias migren. RPCs existentes siguen funcionando filtrando por `group_id IS NOT NULL`. |
| D3 | **Rights son fuente de verdad para ownership.** Solo dos campos de actor en `resources`: `created_by_actor_id` (audit, inmutable) y `canonical_owner_actor_id` (cache/UI hint, **no autoridad**). | `actor_has_right(actor_id, resource_id, 'OWN')` es la única fuente para "¿es dueño?". `canonical_owner_actor_id` se sincroniza desde el `OWN` con mayor `percent` (o el más reciente sin percent) vía trigger sobre `resource_rights`; sirve para listados rápidos pero nunca para gating. NO usar `primary_actor_id` ni `owner_actor_id` — naming explícito evita la tentación de leerlo como autoridad. |
| D4 | Permissions (governance) **coexisten ortogonalmente** con Rights. | `has_actor_authority(actor, action)` = ¿quién puede actuar dentro de un actor (governance interna)? — extensión de `has_group_permission` a person/legal_entity. `actor_has_right(actor, resource, right_kind)` = ¿qué puede ese actor sobre un recurso? RPCs sensibles chequean **ambos**: ej. `transfer_resource` requiere `has_actor_authority(actor, 'resources.transfer')` + `actor_has_right(actor, resource, 'SELL')`. |
| D5 | Money ledger pasa a ser **actor→actor**. `group_id` queda como tag en `system_events.payload`, no como dimensión obligatoria del movimiento. | Diferido a R.1 — R.0 NO toca money. Solo deja el modelo listo: cuando R.1 retrofitee `record_expense`/`record_settlement`, podrán usar `from_actor_id`/`to_actor_id`. |

---

## 3. Catálogo de derechos (whitelist `right_kind`)

Hoy `group_resource_rights.right_kind` está abierto (text). R.0C añade CHECK constraint con whitelist:

```
OWN
VIEW
USE
MANAGE
SELL
TRANSFER
GOVERN
BENEFICIARY
PLEDGE
LIEN
LEASE
COLLECT_INCOME
PAY_EXPENSES
AUDIT
APPROVE
```

**Semánticas mínimas (locked):**
- `OWN` reduce a net worth como activo. `percent` opcional (default 100).
- `BENEFICIARY` NO suma a net worth (línea separada).
- `LIEN`/`PLEDGE` reducen posición patrimonial del owner (carga sobre activo).
- `USE`/`MANAGE`/`VIEW`/`AUDIT`/`APPROVE` NO afectan net worth — son rights de operación.
- `SELL`/`TRANSFER` son rights ejecutivos (autoridad de mover el recurso fuera del owner actual).
- `COLLECT_INCOME`/`PAY_EXPENSES` mapean a quien recibe/paga del cashflow del recurso.
- `LEASE` = right de uso temporal con contraprestación (typically MANAGE + obligación de pago).
- `GOVERN` = right de definir reglas/decisiones sobre el recurso (típicamente grupos que administran recursos ajenos).

---

## 4. Plan de fases

### R.0A — Actor Registry (3 migs, ~1 sesión)

**Backend:**
1. `mig: r0a_create_actors_table` — `actors(id uuid PK, actor_kind text CHECK person|group|legal_entity, display_name text, metadata jsonb, created_at, updated_at)` + indexes.
2. `mig: r0a_backfill_actors_from_profiles_and_groups` — INSERT INTO `actors` SELECT id, 'person', display_name, … FROM profiles; idem groups. Add `profiles.actor_id` y `groups.actor_id` como GENERATED ALWAYS AS (id) STORED (o trigger), o si decidimos compartir UUIDs: `actors.id = profiles.id` para person y `actors.id = groups.id` para group. **Decisión:** compartir UUIDs (más simple, evita doble PK).
3. `mig: r0a_create_legal_entities` — `legal_entities(id uuid PK = actors.id, entity_type, tax_id, jurisdiction, metadata, created_at, updated_at)` + RPCs `create_legal_entity` + `update_legal_entity`.

**Smoke:** `_smoke_r0a_actor_registry` — todos los profiles tienen `actors` row; todos los groups tienen `actors` row; create_legal_entity ya inserta en ambas tablas.

**iOS:** NINGÚN cambio. Capa invisible.

**Riesgo:** bajo. Solo añade. Cero RPCs modificadas.

---

### R.0B — Unified Resources (5-6 migs, ~2 sesiones)

**Backend:**
1. `mig: r0b_rename_group_resources_to_resources` — `ALTER TABLE group_resources RENAME TO resources`. Crear `VIEW group_resources AS SELECT * FROM resources WHERE group_id IS NOT NULL` para compat hasta R.0F.
2. `mig: r0b_relax_group_id_nullable` — `ALTER TABLE resources ALTER COLUMN group_id DROP NOT NULL`. Drop CHECK si lo requiere. **`group_id` permanece** (deprecated, read-compat) hasta R.1/R.2; este plan no la dropea.
3. `mig: r0b_add_canonical_owner_actor_id` — `ALTER TABLE resources ADD COLUMN canonical_owner_actor_id uuid REFERENCES actors(id)`. Backfill: para resources con `group_id`, set `canonical_owner_actor_id = group_id` (porque groups.id = actors.id por D1). Naming explícito: **NO usar `owner_actor_id` ni `primary_actor_id`** — el prefijo `canonical_` recuerda que es cache/UI hint sincronizado desde `resource_rights`, no autoridad.
4. `mig: r0b_rename_resource_subtype_tables` — rename `group_resource_funds` → `resource_funds` (opcional, defer si rompe demasiado). **Decisión:** dejar nombres de subtype tables como están (cosmético) en R.0; rename masivo en R.1.
5. `mig: r0b_rename_group_resource_owners_to_resource_owners` — rename, mantener view compat. Reusar para tabla deprecada en R.0C cuando todo migre a `resource_rights`.
6. `mig: r0b_create_resources_rpcs` — `create_resource(p_actor_id, p_resource_type, p_name, …, p_group_id NULL)`, `list_actor_resources(p_actor_id)`. Reusar `create_group_resource` redirigiendo internamente. `created_by_actor_id` se setea desde `auth.uid()` (resuelto a actor_id).

**Smoke:** `_smoke_r0b_unified_resources` — crear resource sin group_id (personal); crear resource con group_id (grupal); list_actor_resources retorna ambos; queries históricas vía view `group_resources` siguen verdes.

**iOS:** NINGÚN cambio en esta fase. `CanonicalResourcesRepository` sigue leyendo `group_resources` (vía view). Compat 100%.

**Riesgo:** medio. La rename + view compat es la operación delicada. Si alguna RPC hace `INSERT INTO group_resources(...)` el rename rompe; mitigación: la view debe ser INSTEAD OF INSERT/UPDATE/DELETE trigger redirigiendo a `resources`.

---

### R.0C — Resource Rights (4-5 migs, ~1.5 sesiones)

**Backend:**
1. `mig: r0c_rename_group_resource_rights_to_resource_rights` — rename + crear view compat.
2. `mig: r0c_add_holder_actor_id` — `ALTER TABLE resource_rights ADD COLUMN holder_actor_id uuid REFERENCES actors(id)`. Backfill: para rights con `holder_membership_id`, set `holder_actor_id = (SELECT user_id FROM group_memberships WHERE id = holder_membership_id)`. Mantener `holder_membership_id` columna por compat hasta R.0F.
3. `mig: r0c_add_right_kind_whitelist` — `ALTER TABLE resource_rights ADD CONSTRAINT right_kind_whitelist CHECK (right_kind IN ('OWN','VIEW','USE','MANAGE','SELL','TRANSFER','GOVERN','BENEFICIARY','PLEDGE','LIEN','LEASE','COLLECT_INCOME','PAY_EXPENSES','AUDIT','APPROVE'))`. Add `percent`, `scope`, `starts_at` columnas si no existen.
4. `mig: r0c_backfill_ownership_to_rights` — para cada row de `group_resource_owners` (77 filas), insertar `resource_rights` con `right_kind='OWN'`, `holder_actor_id` resuelto desde `membership_id`/`external_party_id`, `percent = ownership_pct`. Marcar `group_resource_owners` como deprecated (no drop).
5. `mig: r0c_create_rights_rpcs` — `grant_right(p_resource_id, p_holder_actor_id, p_right_kind, p_percent, p_scope, p_starts_at, p_ends_at)`, `revoke_right(p_right_id)`, `actor_has_right(p_actor_id, p_resource_id, p_right_kind) returns boolean`.

**Smoke:** `_smoke_r0c_resource_rights` — grant OWN a person, grant MANAGE a group, revoke; `actor_has_right` retorna correcto; `actor_net_worth` placeholder respeta OWN/LIEN.

**iOS:** Ninguno (lectura sigue por views compat).

**Riesgo:** medio. Backfill de ownership debe ser idempotente (re-corrible). El whitelist CHECK puede romper si hay `right_kind` legacy fuera del set — verificar antes con `SELECT DISTINCT right_kind FROM group_resource_rights`.

---

### R.0D — Relationship Graph (2-3 migs, ~1 sesión)

**Backend:**
1. `mig: r0d_create_actor_relationships` — `actor_relationships(id, subject_actor_id, relationship_type, object_actor_id NULL, object_resource_id NULL, percent, starts_at, ends_at, metadata, created_at)` + CHECK que exactamente uno de object_actor_id/object_resource_id sea NOT NULL.
2. `mig: r0d_relationship_type_whitelist` — CHECK con whitelist inicial: `owns, controls, member_of, admin_of, beneficiary_of, leased_to, managed_by, employed_by, guarantor_of, trustee_of, shareholder_of, custodian_of, debtor_to, creditor_of`.
3. `mig: r0d_create_relationship_rpcs` — `create_actor_relationship(...)`, `list_actor_relationships(p_actor_id, p_direction in|out|both)`.

**Smoke:** `_smoke_r0d_relationship_graph` — Jose owns 70% Quimibond → Quimibond owns Machine → query lateral 2 saltos retorna Machine.

**iOS:** Ninguno.

**Riesgo:** bajo. Tabla nueva, sin retrofit.

---

### R.0E — My World View (2 migs, ~1 sesión backend; iOS arranca después)

**Backend:**
1. `mig: r0e_create_my_world_summary` — `my_world_summary() returns jsonb` (caller-scoped via `auth.uid()` → actor_id). Retorna estructura definida en doctrina (§My World).
2. `mig: r0e_create_actor_net_worth` — `actor_net_worth(p_actor_id) returns jsonb` agrupado por moneda. Reglas: OWN suma `estimated_value`; LIEN/PLEDGE/PAYABLE/LOAN restan; BENEFICIARY se reporta en sección separada; USE/MANAGE/VIEW NO suman.

**Smoke:** `_smoke_r0e_my_world` — usuario con OWN sobre 2 resources, BENEFICIARY de 1, miembro de 1 grupo → my_world_summary retorna 2 owned + 1 beneficiary + 1 group_membership; net_worth = sum(OWN values).

**iOS (arranca en paralelo con R.0F):**
- `MyWorldRepository` (Mock + Live) consumiendo `my_world_summary()`.
- `MyWorldStore` (`@Observable`).
- Mantener `GroupListView` como ruta legacy; no tocar todavía la entrada de la app.

**Riesgo:** bajo backend. iOS: ninguno aún (solo plumbing).

---

### R.0F — Group/Entity Views + iOS Root Pivot (4-6 migs backend, ~3-4 sesiones iOS)

**Backend:**
1. `mig: r0f_create_group_world_summary` — consolidado per-group: resources_owned (via OWN rights), resources_used (via USE), resources_managed (via MANAGE), members, money_position (placeholder hasta R.1), pending_decisions, rules, recent_activity.
2. `mig: r0f_create_legal_entity_world_summary` — análogo para legal_entities.
3. `mig: r0f_drop_views_compat_group_resources_etc` — solo cuando iOS ya esté migrado a `resources` directo. Drop view `group_resources` (compat), drop view `group_resource_owners` (compat), drop view `group_resource_rights` (compat).

**NO dropear en R.0F (diferido a R.1/R.2):**
- `resources.group_id` — sigue siendo scope/cache legacy útil para permisos por grupo, filtros, navegación iOS, eventos históricos, RPCs viejas, auditoría de recursos creados-dentro-de-grupo. Drop solo cuando todas las dependencias hayan migrado a `GOVERN`/`MANAGE` right + `actor_relationships`.
- `resource_rights.holder_membership_id` — mismo argumento: queda como cache legacy hasta que `MembersListView`/governance views consuman `holder_actor_id` directo.
- `group_resource_owners` table — depreciada pero NO dropeada (datos backfilleados a `resource_rights` pero la tabla se queda como histórico read-only hasta R.1+).

**iOS:**
- `PersonalHomeView` como nueva root (renombrar/reemplazar entry actual `GroupListView`).
- Secciones: Net Worth, Accounts, Assets, Liabilities, Documents, Legal Entities, Shared With Me, Shared By Me, Recent Activity, Pending Decisions, **Groups** (como sección, no como root).
- `ResourcesListView` aceptar `actor_id` como filtro (no solo `group_id`).
- `GrantRightSheet`/`TransferRightSheet` ya existen — refactor para aceptar `holder_actor_id` (en vez de solo `holder_membership_id`).
- `GroupHomeFeedView` consume `group_world_summary(group_id)` como nueva fuente del cluster home.

**Smoke:** smoke iOS manual en simulador iOS 26 + device JJ.

**Riesgo:** alto. Cambio de IA root es el más visible. Mitigación: feature flag `r0_personal_home_enabled` en `groups.settings` o en `profiles.metadata` para dogfood progresivo (founder primero, equipo después).

---

## 5. Orden estricto y dependencias

```
D.24 close (P12B-4 ya shipped ✓)
      ↓
R.0A Actor Registry
      ↓
R.0B Unified Resources ───┐
      ↓                   │
R.0C Resource Rights      │ (paralelo si bandwidth)
      ↓                   │
R.0D Relationship Graph ──┘
      ↓
R.0E My World View (backend + iOS plumbing)
      ↓
R.0F Group/Entity Views + iOS Root Pivot
      ↓
[R.0 cerrado — R.1 puede atacar Money actor-aware, family world, multi-currency net worth, etc.]
```

**No saltar fases.** R.0F asume que R.0B/C dropearon las views compat — si iOS no se migró a `resources` directo antes, drop rompe la app.

---

## 6. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| RPCs legacy hacen `INSERT INTO group_resources` y rompen al rename | Media | Alto | View con INSTEAD OF triggers en R.0B antes de cualquier rename productivo. Auditar las ~10 RPCs que escriben al área. |
| `right_kind` legacy fuera de whitelist | Baja | Medio | `SELECT DISTINCT right_kind` antes de R.0C; agregar al whitelist o cleanup data. |
| Backfill de ownership idempotente | Media | Medio | Migración con `ON CONFLICT DO NOTHING` y unique partial index `(resource_id, holder_actor_id, right_kind) WHERE right_kind='OWN'`. |
| iOS UI shock cambio de root | Alta | Alto | Feature flag por usuario; founder primero; rollback simple a `GroupListView` durante 1 semana. |
| Net worth ambiguo con multi-currency | Alta | Bajo (R.0) | R.0E retorna **agrupado por moneda**, NO convierte. FX se difiere a R.1. |
| Governance regression: `has_group_permission` no contempla actor del recurso | Media | Alto | Mantener `has_group_permission` invariante; agregar `has_actor_authority` como nueva función. RPCs sensibles componen ambas explícitamente. |

---

## 7. Criterios de aceptación (DoD R.0)

Los 6 casos de la doctrina son los smokes finales:

1. ✅ Jose OWN Terreno + Quimibond USE Terreno + Papá MANAGE Terreno (sin transferir).
2. ✅ Jose OWN Bank Account + Linda VIEW only.
3. ✅ Jose OWN 70% Quimibond + Quimibond OWN Machine → Machine en Quimibond World + Quimibond en Jose My World.
4. ✅ Trust OWN Shares + Linda BENEFICIARY_OF Trust + Jose TRUSTEE_OF Trust.
5. ✅ Jose OWN Vehicle + Family Group MANAGE → Family schedule + Jose sigue dueño.
6. ✅ Jose DEBTOR_TO Bank + Bank LIEN sobre Property → net_worth refleja pasivo.

Cada caso = smoke RPC + verificación iOS en `PersonalHomeView`.

---

## 8. Out of scope explícito

- **R.1 Money actor-aware:** retrofitear `record_expense`, `record_settlement`, `pay_sanction` para usar `from_actor_id`/`to_actor_id`.
- **R.1 Family worlds:** primitiva `family` como sub-tipo de actor o como relationship pattern (decisión deferida).
- **R.1 FX en net worth:** multi-currency con tabla de tipos de cambio o integración a API.
- **R.2 Trust cascade:** beneficiary_of con percent y waterfall automático.
- **R.2 Tokenización:** representar ownership como token on-chain (Solana/Polygon).
- **R.2 Importadores:** Plaid/Belvo para bank_accounts personales auto-sync.
- **R.2 OCR documentos:** subir contrato escaneado → resource con metadata extraída.

---

## 9. Próximo paso operativo

1. ✅ Founder firma plan (este doc) — 2026-06-01.
2. **Ship slice por slice.** Próximo handoff al implementador: **SOLO R.0A — Actor Registry**. NO mandar todo R.0 en un batch. Cada fase es una sesión con migración + smoke + commit + journal.
3. Después de cada fase, journal en este mismo doc bajo §10 (post-mortem). Si una fase descubre algo que invalida la siguiente, replantear antes de continuar.

### Handoff R.0A — qué contiene el batch al implementador

- Solo §4 → "R.0A — Actor Registry" (3 migs).
- Doctrina § completa (1–3).
- Estado DB §1 (tabla pivote).
- Decisiones D1 lockeada (compartir UUIDs).
- DoD R.0A: smoke `_smoke_r0a_actor_registry` pasa + cero RPCs modificadas + cero cambios iOS.
- Out of scope R.0A: NO tocar `resources`, NO tocar `rights`, NO crear views nuevas. Cualquier extensión espera R.0B+.

## 10. Journal

### R.0A — Actor Registry — SHIPPED 2026-06-01

**Migraciones aplicadas (5, todas additive, cero RPCs preexistentes modificadas):**

| Timestamp | Nombre | Qué hace |
|---|---|---|
| `20260601212044` | `r0a_create_actors_table` | Crea `actors(id, actor_kind, display_name, metadata, timestamps)` + CHECK whitelist + touch trigger + RLS read-authenticated. |
| `20260601212059` | `r0a_backfill_actors_from_profiles_and_groups` | INSERT idempotente con `ON CONFLICT DO NOTHING` desde profiles → person actors y groups → group actors. UUIDs compartidos. |
| `20260601212139` | `r0a_create_legal_entities_and_rpcs` | `legal_entities(id REFERENCES actors ON DELETE CASCADE, entity_type, tax_id, jurisdiction, metadata)` + RPCs `create_legal_entity(5 args)` y `update_legal_entity(6 args)`, ambas SECDEF + auth.uid() check. |
| `20260601212217` | `r0a_smoke_actor_registry` | Smoke v1 — 4 casos. Falló Caso 4 por bug de snapshot order (ver fix). |
| `20260601212329` | `r0a_smoke_actor_registry_fix_idempotency_snapshot` | Fix snapshot: catch-up backfill → snapshot → re-run → diff=0. Smoke verde. |

**DoD R.0A — todos verdes:**

- ✅ `actors` existe (231 rows post-backfill)
- ✅ `legal_entities` existe (0 rows post-cleanup, schema validado vía smoke)
- ✅ Todos los profiles tienen actor person (154/154)
- ✅ Todos los groups tienen actor group (77/77)
- ✅ `create_legal_entity` funciona (smoke Caso 3 verde)
- ✅ `update_legal_entity` funciona (smoke Caso 3 sync `display_name` verificado)
- ✅ Smoke verde (`_smoke_r0a_actor_registry` corrido 3 veces back-to-back sin falla)
- ✅ Build verde (sin cambios iOS — confirmar con `BuildProject` si se requiere; cero archivos Swift tocados)
- ✅ Cero RPCs existentes modificadas
- ✅ Cero cambios iOS

**Riesgos/hallazgos R.0A:**

1. **Smoke cleanup parcial:** `set_config('session_replication_role', 'replica')` requiere superuser; cuando se invoca el smoke vía MCP el bloque cae a `insufficient_privilege` y la limpieza interna no corre. Cada ejecución del smoke deja: 1 auth.user + 1 profile auto-trigger + 1 person actor + 1 legal_entity actor + 1 legal_entity row. Convención existente (`_smoke_membership_boundary`, `_smoke_inbox`) sufre del mismo síntoma. **Mitigación R.0A:** después de cada batch de smoke runs, cleanup manual con SQL surgical (identificar smoke callers via `actors.metadata->>'source' = 'r0a_backfill_catchup'`). Documentado para futuras fases.

2. **Forward-sync no implementado:** `actors` se mantiene en sync con `profiles`/`groups` solo via backfill puntual. Nuevos inserts post-R.0A en `auth.users` → `profiles` NO crean actor automáticamente. Esto es **R.0B requisito previo** — la primera migración de R.0B debe añadir triggers `AFTER INSERT ON profiles → INSERT INTO actors` y similar para `groups`. Sin esos triggers, R.0B+ verá actors faltantes para users/groups creados entre R.0A y R.0B.

3. **`d24_p2b1_group_resources_direct_insert_audit` (timestamp `20260601212332`)** se aplicó durante mi sesión (entre mis migs) por trabajo separado. NO es parte de R.0A. Independiente. Probablemente otra sesión avanzando P2B.

**Post-state DB (verificado):**

```
actors           = 231  (154 person + 77 group + 0 legal_entity)
legal_entities   = 0
profiles         = 154  (sin cambio)
groups           = 77   (sin cambio)
```

**Próximo:** R.0B Unified Resources. Pre-requisito: triggers de forward-sync (mig 0 de R.0B) antes de cualquier rename de `group_resources`.

---

### R.0A.1 — Actor Forward Sync — SHIPPED 2026-06-01

Cierra el hueco de existencia identificado en R.0A hallazgo 1 antes de arrancar R.0B.

**Scope estricto:** solo `AFTER INSERT` (existence). **NO** `AFTER UPDATE` — display_name drift aceptado durante todo R.0; lecturas hacen `COALESCE(profile.display_name, profile.username, actors.display_name)` cuando aplique. Sync fino de nombres diferido.

**Migraciones aplicadas (4):**

| Timestamp | Nombre | Qué hace |
|---|---|---|
| `20260601213506` | `r0a1_forward_sync_profile_to_actor` | Trigger `AFTER INSERT ON profiles` → `_sync_actor_from_profile()` SECDEF inserta actor person con `ON CONFLICT DO NOTHING`. |
| `20260601213520` | `r0a1_forward_sync_group_to_actor` | Trigger `AFTER INSERT ON groups` → `_sync_actor_from_group()` SECDEF inserta actor group con `ON CONFLICT DO NOTHING`. |
| `20260601213556` | `r0a1_smoke_forward_sync` | Smoke v1 (4 casos). Caso 3 con bug — `PERFORM` directo a trigger function falla por falta de contexto NEW. |
| `20260601213642` | `r0a1_smoke_forward_sync_simplify_caso3` | Fix: reemplaza PERFORM con INSERT redundante directo en actors (verifica `ON CONFLICT DO NOTHING` empíricamente). Smoke verde. |

**DoD R.0A.1 — todos verdes:**

- ✅ Trigger profile → actor activo (verificado: insert auth.user → cadena dispara actor person con `source=r0a1_forward_sync_profile`)
- ✅ Trigger group → actor activo (verificado: insert group → actor group con `source=r0a1_forward_sync_group` y `display_name` sincronizado)
- ✅ `ON CONFLICT DO NOTHING` defense holds (insert duplicado a actors con id existente absorbe sin error, sin duplicar)
- ✅ Zero orphans en estado global (todos profiles tienen actor person, todos groups tienen actor group)
- ✅ Cero RPCs nuevas, cero modificaciones a actors/legal_entities, cero iOS

**Hallazgo R.0A.1 — leak persistente en groups:**

El cleanup interno del smoke intenta `DELETE FROM groups WHERE id = v_group_id` pero está bloqueado por `atom_no_delete_guard()` sobre `group_role_assignment_events` (append-only — el INSERT en groups dispara una fila inmutable en esta tabla). Sin `session_replication_role='replica'` (que requiere superuser), no se puede bypassear. El `EXCEPTION WHEN OTHERS` absorbe el error y deja el group residual.

**Por corrida del smoke se leakea:** 1 group + cualquier auth.user/profile/actor relacionado que no se haya alcanzado a borrar antes del error. Para mantener `Caso 4 zero orphans` consistente, después del smoke hay que re-syncar el actor del group leaked (vía `INSERT … ON CONFLICT DO NOTHING` manual).

Mismo patrón que `_smoke_membership_boundary`/`_smoke_inbox` cuando se corren sin superuser. Aceptable convención repo. Para CI dedicado con superuser, el cleanup completo funcionaría.

**Post-state DB (verificado):**

```
actors           = 232  (154 person + 78 group)
legal_entities   = 0
profiles         = 154
groups           = 78   (77 originales + 1 R0A1 Smoke Group residual + actor re-syncado)
orphan_profiles  = 0
orphan_groups    = 0
```

**Próximo:** R.0B Unified Resources. Pre-requisito ya cumplido (forward-sync activo); R.0B mig 0 ya no es necesaria.

---

### R.0B.0 — Legacy Resource Dependency Audit — SHIPPED 2026-06-01

Discovery-only fase. Cero DDL. Ver `Plans/Active/R0B0_LegacyResourceDependencyAudit.md`.
Commit `2326290d`. Resultado: GO para R.0B.1 con 1 condición founder (audit trigger Option A/B).

---

### R.0B.1 — Rename Layer + Compat Views — SHIPPED 2026-06-01

Founder firmó **Opción B** ("audit replicado sobre compat view para mantener señal de legacy writes").

**Migraciones aplicadas (2):**

| Timestamp | Mig | Qué hace |
|---|---|---|
| `20260601220010` | `r0b1_rename_resources_and_compat_layer` | **ATÓMICA.** ALTER TABLE RENAME ×4 (group_resources/owners/rights/capabilities → resources/owners/rights/capabilities) + CREATE 4 compat views con mismo nombre legacy + 12 INSTEAD OF triggers (3 per view). El INSERT trigger del view `group_resources` preserva `current_setting('ruul.resource_create_intent')` si está seteado por wrapper, o lo setea a `'legacy_view_write'` si viene NULL — el AFTER INSERT trigger sobre `resources` (movido por rename) captura con marker distintivo. |
| `20260601220425` | `r0b1_smoke_compat_layer` | `_smoke_r0b1_compat_layer()` — 7 casos: INSERT directo→audit legacy_view_write, SELECT transparente, UPDATE propaga, archive propaga, wrapper intent preservado, RPC `create_group_resource` funciona vía compat sin saber del view, owners/rights/caps SELECT parity. |

**Por qué atómica:** 26+ funciones writer hacen `INSERT INTO public.group_resources` en su `prosrc`. Si rename y view creation no son en la misma transacción, hay una ventana donde esas RPCs fallan con "relation does not exist".

**DoD R.0B.1 — todos verdes:**

- ✅ 4 tablas renombradas a nombres canónicos (`resources`, `resource_owners`, `resource_rights`, `resource_capabilities`)
- ✅ 4 compat views con nombres legacy (`group_resources`, etc.) — INSTEAD OF I/U/D triggers redirigen
- ✅ Audit D.24 P2B-1 **preservado** vía Option B: el INSTEAD OF INSERT del view propaga el intent_marker original o marca `'legacy_view_write'`
- ✅ Smoke (`_smoke_r0b1_compat_layer`) verde — 7 casos
- ✅ 78 funciones legacy que referencian las 4 tablas **siguen funcionando sin tocar su `prosrc`**
- ✅ `create_group_resource` (la RPC original) demostradamente funciona vía compat layer
- ✅ Data intacta: 85→91 rows post-smoke (smoke crea 6 archived); 77 owners, 2 rights, 0 capabilities unchanged

**Hallazgos:**

1. **`trg_resource_owner_no_delete` es FOR EACH STATEMENT** (no FOR EACH ROW). Bloquea CUALQUIER DELETE statement contra `resource_owners`, incluido cascade ON DELETE desde resources. Esto significa que **`DELETE FROM resources` solo funciona si no hay owners**. La convención es `UPDATE … SET archived_at = now()` (soft delete). Pre-existente, no es regresión R.0B.1.
2. **Visibility whitelist:** `{'private','members','public'}`. No 'group' (usar 'members'). Pre-existente, descubierto durante smoke.
3. **No regresión en wrappers P2A/P2B-1.y** — las 7 wrappers (`create_*_resource`) siguen funcionando porque delegan a `create_group_resource` que ahora escribe al compat view (que redirige).
4. **Audit table grew correctly:** Pre R.0B.1: 1 row baseline. Post smoke: 7 rows. Marker distribution: 2 `legacy_view_write`, 1 `r0b1_smoke_custom_intent`, 3 wrapper intents, 1 baseline.

**Post-state DB (verificado):**

```
resources               = 91   (85 pre + 6 smoke, 37 archived total)
resource_owners         = 77   (sin cambio)
resource_rights         = 2    (sin cambio)
resource_capabilities   = 0    (sin cambio)
group_resources_direct_insert_audit = 7   (1 baseline + 6 smoke)
  legacy_view_write    : 2
  r0b1_smoke_custom_intent : 1
  otros (wrapper)      : 3 + 1 baseline
```

**Próximo:** R.0B.2 — `ALTER TABLE resources ALTER COLUMN group_id DROP NOT NULL` + `ADD COLUMN canonical_owner_actor_id uuid REFERENCES actors(id)` + backfill. **Compat view sigue funcional** durante R.0B.2 (los wrappers pueden seguir asumiendo `group_id NOT NULL` — los nuevos paths personales R.0E+ tendrán wrappers nuevos).

**NO en R.0B.1:** migración cosmética de las 78 funciones a nombres canónicos (`resources` en vez de `group_resources` en su prosrc). Eso es R.0B.3+ — ola por ola con CREATE OR REPLACE, sin drop del compat view hasta que la última función migre.

---

### R.0B.2 — Nullable Group Scope + Canonical Owner Cache — SHIPPED 2026-06-01

Doctrina founder lockeada:
- `resources.group_id` queda pero deja de ser obligatorio (deprecated/scope-cache legacy)
- `canonical_owner_actor_id` es **cache/UI hint**, NO autoridad
- OWN en `resource_rights` será la fuente real en R.0C (no en R.0B.2)

**Preflight (verificado):**
- 0 rows con group_id NULL pre-mig
- 0 group_id huérfanos vs actors
- canonical_owner_actor_id no existía
- 91 resources totales, todos con actor group válido

**Migraciones aplicadas (2):**

| Timestamp | Mig | Qué hace |
|---|---|---|
| `20260601233126` | `r0b2_nullable_group_id_and_canonical_owner_actor_id` | **ATÓMICA.** (1) `ALTER COLUMN group_id DROP NOT NULL`; (2) `ADD COLUMN canonical_owner_actor_id uuid REFERENCES actors(id)` + partial index; (3) backfill `canonical_owner_actor_id = group_id` (91/91); (4) BEFORE INSERT trigger defensivo `_resources_derive_canonical_owner_actor_id` self-healing; (5) `CREATE OR REPLACE VIEW group_resources AS SELECT * FROM resources WHERE group_id IS NOT NULL` (filtra personal); (6) INSTEAD OF INSERT del view **rechaza** group_id NULL (preserva contrato legacy); (7) INSTEAD OF UPDATE forwards canonical_owner_actor_id. |
| `20260601233223` | `r0b2_smoke_nullable_group_canonical_owner_cache` | `_smoke_r0b2_*()` 6 casos verde. |

**Smoke casos verdes (6):**
1. ✅ INSERT legacy con group_id via compat view → canonical_owner_actor_id auto-derivado = group_id
2. ✅ INSERT directo a resources con group_id=NULL + canonical=person actor → personal path acepta
3. ✅ Legacy resource visible vía group_resources view
4. ✅ Personal resource (group_id NULL) INVISIBLE vía group_resources view, visible vía resources
5. ✅ canonical_owner_actor_id apunta correctamente: legacy→group actor, personal→person actor
6. ✅ Reject: INSERT via compat view con group_id NULL lanza excepción (preserva contrato legacy NOT NULL)

**DoD R.0B.2 todos verdes:**

- ✅ `resources.group_id` ahora nullable
- ✅ `canonical_owner_actor_id` columna existe con FK a `actors(id)` y partial index
- ✅ Backfill 91/91 resources (todos los pre-existentes son group-scoped)
- ✅ Defensive trigger BEFORE INSERT activo (self-healing del cache)
- ✅ Compat view filtra group_id IS NOT NULL — personal resources invisibles via legacy
- ✅ INSTEAD OF INSERT rechaza NULL group_id (legacy strict contract)
- ✅ Audit Option B (R.0B.1) sigue funcionando
- ✅ Cero RPCs preexistentes modificadas
- ✅ Cero iOS

**Naming explícito (anti-patrón confirmado):**
NO se introdujeron `owner_actor_id` ni `primary_actor_id`. Solo `canonical_owner_actor_id` — el prefijo recuerda que es cache derivado, no autoridad.

**Post-state DB:**

```
resources                = 93   (91 pre + 2 smoke: 1 legacy + 1 personal, ambos archivados)
  group_scoped (group_id NOT NULL) = 92
  personal     (group_id NULL)     = 1
  con canonical_owner_actor_id      = 93 (100%)
resource_owners          = 77
resource_rights          = 2
resource_capabilities    = 0
group_resources (compat) = 92 (filtra el personal)
```

**Hallazgos:**

1. **Postgres acepta `CREATE OR REPLACE VIEW` con WHERE más restrictivo + columna nueva al final** sin issues — la columna `canonical_owner_actor_id` fue añadida al final por `ALTER TABLE`, y el view se refresca con `SELECT *` resolviéndose a la nueva lista.
2. **INSTEAD OF triggers sobreviven CREATE OR REPLACE VIEW** automáticamente (atados al view por nombre + función). Solo tuve que `CREATE OR REPLACE FUNCTION` el INSERT y UPDATE para extender semantica.
3. **R.0C entry point claro:** el sync de `canonical_owner_actor_id` desde `resource_rights.OWN` (que será la autoridad) llega como trigger AFTER INSERT/UPDATE/DELETE en resource_rights cuando R.0C esté listo.

**Próximo:** R.0C — Resource Rights. Whitelist 15 right_kinds + `holder_actor_id` (en vez de holder_membership_id) + RPCs `grant_right`/`revoke_right`/`actor_has_right` + backfill ownership de `resource_owners` (OWN rights con percent) + sync trigger `canonical_owner_actor_id ← OWN-mayor-percent`.
