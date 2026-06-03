# R.0B.0 — Legacy Resource Dependency Audit

**Status:** Discovery-only. Cero DDL ejecutado. Cero cambios iOS.
**Verified against live DB** `wyvkqveienzixinonhum` 2026-06-01 vía MCP.
**Plan parent:** `R0_ActorResourceRights.md` §R.0B (Unified Resources).
**Pre-requisito:** R.0A + R.0A.1 cerrados ✅.

---

## 0. Pregunta operativa

> ¿Qué se rompe exactamente si mañana renombramos `group_resources → resources`?

**Respuesta corta:** **96 funciones referencian las 4 tablas por nombre en su cuerpo.** Postgres NO actualiza `prosrc` en un `ALTER TABLE … RENAME`, así que sin compat layer las 96 funciones se rompen. **Con compat layer (view + INSTEAD OF triggers), cero RPCs se rompen, cero iOS se rompe, cero edge functions se rompen.** Go con condiciones.

---

## 1. Inventario backend — totales

| Tabla | Funcs totales | Writers | Inserters | Updaters | Deleters | Pure readers | FKs entrantes | Triggers | RLS policies | Views dependientes |
|---|---|---|---|---|---|---|---|---|---|---|
| `group_resources` | **74** | 17 | 5 | 11 | 2 ⚠️* | 47 | **14** (10 child tables, 4 dupes) | 2 | 3 | 1 (`group_event_calendar_view`) |
| `group_resource_owners` | 5 | 2 | 1 | 1 | 0 | 3 | 0 | 3 (incl. append-only guard) | 1 | 0 |
| `group_resource_rights` | 11 | 7 | 3 | 4 | 0 | 4 | 0 | 3 (incl. type whitelist) | 3 | 0 |
| `group_resource_capabilities` | 6 | 4 | 2 | 3 | 0 | 2 | 0 | 1 | 3 | 0 |

\* Los 2 DELETE sobre `group_resources` son ambos **smoke functions** (`_smoke_global_search`, `_smoke_action_governance_full`). **NO hay deleters de producción** — `group_resources` está efectivamente append-only modulo archivado vía `archived_at`.

---

## 2. Detalle writers — todas las funciones que mutan

### group_resources

| Función | Op | Notas |
|---|---|---|
| `create_group_resource(p_group_id, …)` (overload A) | **I** | Chokepoint legacy. **2 overloads activos** (D.24 P2B-1 audit doc). |
| `create_group_resource(p_group_id, …)` (overload B) | **I** | Segunda overload. |
| `create_resource(p_group_id, …)` | **I** | Generic P2A atomic wrapper. También INSERTa en `group_resource_rights` (baseline OWN). |
| `create_event(p_group_id, …)` | **I** | P2A event-specific wrapper. |
| `_smoke_global_search` | **I D** | Smoke (no producción). |
| `archive_resource` | U | `archived_at = now()` |
| `revert_archive_resource` | U | `archived_at = NULL` |
| `update_resource` | U | metadata, name, etc. |
| `update_resource_value` | U | valuation update |
| `set_resource_ownership` | U | Ownership v2 (D.24 P3A) |
| `archive_event` | U | Event lifecycle |
| `cancel_event` | U | Event lifecycle |
| `update_event` | U | Event detail |
| `add_event_attendee` | U | RSVP path |
| `remove_event_attendee` | U | RSVP path |
| `respond_event` | U | RSVP path |
| `_smoke_action_governance_full` | D | Smoke (no producción). |

### group_resource_owners

| Función | Op | Notas |
|---|---|---|
| `add_resource_owner(p_resource_id, …)` | I | Ownership v2 — append-only insert |
| `end_resource_owner(p_owner_id)` | U | Sets `ends_at` (append-only modelo) |

### group_resource_rights

| Función | Op | Notas |
|---|---|---|
| `grant_right(p_resource_id, …)` | I | Right granting |
| `create_resource(p_group_id, …)` | I | Cross-table: también escribe a `group_resources`. Crea baseline OWN. |
| `create_right_resource(p_group_id, …)` | I | P2A wrapper para right resource type |
| `expire_right(p_resource_id, …)` | U | `expired_at = now()` |
| `revoke_right(p_resource_id, …)` | U | `revoked_at = now()` |
| `transfer_right(p_resource_id, …)` | U | Holder change |
| `_smoke_resources_b4_right` | U | Smoke (no producción) |

### group_resource_capabilities

| Función | Op | Notas |
|---|---|---|
| `enable_resource_capability(p_resource_id, p_key)` | I | Opt-in capability |
| `disable_resource_capability(p_resource_id, p_key)` | U | Disable (sets `enabled=false`) |
| `add_event_reminder(p_event_id, …)` | I U | Reminder = capability row. Upserts. |
| `remove_event_reminder(p_reminder_id)` | U | Disable reminder |

### Wrappers que NO escriben directo (delegan a `create_group_resource`)

Verificado: las 7 wrappers `create_*_resource` recién shipped (P2A + P2B-1.y) **todas delegan**:
- `create_asset_resource` → `create_group_resource`
- `create_event_resource` → `create_group_resource`
- `create_fund_resource` → `create_group_resource`
- `create_generic_resource` → `create_group_resource`
- `create_right_resource` → `create_group_resource` (+INSERT a `group_resource_rights`)
- `create_slot_resource` → `create_group_resource`
- `create_space_resource` → `create_group_resource`

**Implicación:** el chokepoint real de INSERT a `group_resources` está concentrado en `create_group_resource` (2 overloads) + `create_event` + `create_resource`. Esto **simplifica** el compat layer.

---

## 3. Triggers, FKs, RLS, Views

### Triggers definidos ON las 4 tablas (sobreviven rename — Postgres re-asocia por OID)

| Tabla | Trigger | Tipo | Propósito |
|---|---|---|---|
| `group_resources` | `group_resources_set_updated_at` | BEFORE UPDATE | Generic timestamp |
| `group_resources` | `trg_log_group_resources_direct_insert` | **AFTER INSERT** | D.24 P2B-1 audit trigger — loga al insert directo (sin wrapper) |
| `group_resource_owners` | `trg_resource_owner_no_delete` | BEFORE DELETE | Append-only guard |
| `group_resource_owners` | `trg_resource_owner_same_group` | BEFORE INSERT/UPDATE | Invariante "owner mismo grupo que resource" |
| `group_resource_rights` | `group_resource_rights_set_updated_at` | BEFORE UPDATE | Timestamp |
| `group_resource_rights` | `group_resource_rights_type_check` | BEFORE INSERT/UPDATE | Whitelist de `right_kind` |
| `group_resource_capabilities` | `group_resource_capabilities_set_updated_at` | BEFORE UPDATE | Timestamp |

### FKs INCOMING a `group_resources` (10 child tables distintas)

```
group_check_in_actions        (2 FKs — id + same-group invariant)
group_contributions           (source_resource_id)
group_obligations             (source_resource_id)
group_resource_assets         (subtype)
group_resource_bookings       (2 FKs — id + same-group)
group_resource_capabilities   (subtype — incluida en scope)
group_resource_events         (subtype)
group_resource_funds          (subtype)
group_resource_owners         (subtype — incluida en scope)
group_resource_rights         (subtype — incluida en scope)
group_resource_slots          (subtype)
group_resource_spaces         (subtype)
group_resource_transactions   (3 FKs — id + source + same-group)
group_rsvp_actions            (2 FKs — id + same-group)
```

**FKs no se rompen con rename.** Postgres re-asocia el constraint vía OID. Lo único que cambia es el nombre del target en el catálogo.

### RLS Policies (sobreviven rename)

- `group_resources`: 3 policies (select_visible, insert_permission, update_permission)
- `group_resource_owners`: 1 policy (resource_owners_read)
- `group_resource_rights`: 3 policies (select_via_parent, write_via_parent, update_via_parent)
- `group_resource_capabilities`: 3 policies (select_via_parent, write_via_parent, update_via_parent)

### Views

- **`group_event_calendar_view`** depende de `group_resources` (referencias múltiples para agregación de eventos). Sobrevive rename (view se almacena con OIDs).

---

## 4. iOS — superficie de impacto

**Cero acceso directo a tablas.** Toda lectura/escritura va por RPC.

### Archivos que referencian "group_resource*" (11 total)

| Archivo | Tipo de referencia | ¿Se rompe con rename? |
|---|---|---|
| `Stores/ResourcesStore.swift` | Llama a `repository.*` métodos → RPCs `group_resources_active`, `group_resource_detail`, wrappers | NO — RPCs siguen existiendo |
| `Repositories/CanonicalResourcesRepository.swift` | Adaptador a RPC client | NO |
| `API/SupabaseRuulRPCClient.swift` | `client.rpc("group_resources_active")`, `client.rpc("group_resource_detail")` | NO — RPC names (no table names) |
| `API/RuulRPCClient.swift` | Protocol con method signatures | NO |
| `Features/Resources/ResourceDetailView.swift` | `descriptor.subtypeTable != nil` flag check (no query) | NO |
| `Domain/ResourceDetailSummary.swift` | String literal in JSON decoding key | NO |
| `Domain/RightSubtypeData.swift` | String literal en descriptor | NO |
| `Domain/ResourceTypeDescriptor.swift` | Strings `"group_resource_events"`, `"group_resource_funds"`, etc. usadas SOLO como **boolean flag** (`subtypeTable != nil`) | NO |
| `Domain/GroupResource.swift` | Domain model name | NO (cosmético) |
| `Tests/RuulCoreTests/API/RPCInputsEncodingTests.swift` | `@Test("group_resources_active encodes …")` test name | NO |
| `Tests/RuulCoreTests/Domain/GroupResourceTests.swift` | Domain model test | NO |

**Conclusión iOS:** 0 archivos se rompen por rename de tablas, **siempre que las RPCs (`group_resources_active`, `group_resource_detail`, wrappers) sigan existiendo y funcionando**. El nombre de la RPC NO necesita renombrarse en R.0B — puede mantenerse como alias o renombrarse después en una fase cosmética separada.

### Edge functions

**Cero referencias directas** a las 4 tablas en `supabase/functions/` (20+ edge functions revisadas). Todas las edge functions usan RPCs server-side. Cero impacto por rename.

### Cron jobs / pg_cron

`pg_cron` **no está instalado**. Scheduling se hace vía Supabase Cron externo invocando edge functions. Cero referencias directas a tablas. Cero impacto.

---

## 5. SAFE-TO-RENAME vs BLOCKERS

### ✅ SAFE — Postgres maneja transparente

- Renombrar la tabla con `ALTER TABLE … RENAME TO`:
  - **FKs entrantes** (14) re-asocian por OID
  - **Triggers ON la tabla** (2-3 por tabla) re-asocian
  - **RLS policies** re-asocian
  - **Indexes** re-asocian
  - **Views dependientes** re-asocian
- **iOS no se ve afectado** (consume RPCs, no tablas directas)
- **Edge functions no se ven afectadas**
- **Cron no aplica**

### ⚠️ BLOCKERS — requieren compat layer ANTES del rename

1. **96 funciones referencian las 4 tablas por nombre en su `prosrc`.** Sin compat layer, todas fallan al primer call post-rename. **Solución:** crear VIEW `group_resources` (y similares para las otras 3) con INSTEAD OF INSERT/UPDATE/DELETE triggers que redirijan al nuevo nombre `resources`. Las 96 funciones siguen funcionando sin tocar su `prosrc`.

2. **2 overloads de `create_group_resource`** (fragmentación conocida — D.24 P2B). El compat view debe aceptar ambas firmas vía INSTEAD OF INSERT (no problema técnico — el trigger captura cualquier INSERT al view).

3. **Audit trigger `trg_log_group_resources_direct_insert`** (D.24 P2B-1 soft block). Decisión doctrinal pendiente:
   - **Opción A:** El audit aplica solo a INSERTs directos a `resources` (la tabla renombrada). Los INSERTs vía compat view `group_resources` NO disparan el AFTER INSERT en `resources` (Postgres: INSERT vía view con INSTEAD OF trigger no dispara los triggers de la tabla subyacente, solo si la view es UPDATABLE/redirige via DO INSTEAD). Eso significa que el audit deja de loggear cualquier writer legacy → **se pierde la señal P2B-1**.
   - **Opción B:** Replicar el audit trigger sobre el view (INSTEAD OF INSERT trigger que loggea Y redirige). Mantiene tracking pero duplica lógica.
   - **Recomendación:** Opción B durante R.0B (mantener señal P2B-1 viva). Re-evaluar en R.0B fase final cuando todos los writers hayan migrado a nombres nuevos.

4. **Cross-table writer `create_resource`** escribe a 2 tablas (`group_resources` + `group_resource_rights`). Si el compat layer es por-tabla independiente (4 views, 4 sets de triggers), la función sigue funcionando porque ambos INSERTs son interceptados independientemente. **No es blocker, pero requiere verificación en smoke.**

5. **Verificación post-rename:** correr smokes existentes (`_smoke_action_governance_full`, `_smoke_global_search`, `_smoke_resources_b4_right`, smokes de fund/space/slot/asset/right) tras el rename + compat layer para confirmar cero regresión.

---

## 6. Estrategia técnica recomendada para R.0B.1 (Rename + Compat Layer)

**Orden estricto (no reordenar):**

```
Mig 1 — Pre-flight snapshot
  - Snapshot conteos por tabla pre-rename para diff post-rename
  - Snapshot lista de funciones que referencian las 4 tablas (locked)

Mig 2 — Crear nuevas tablas como ALIAS (CREATE TABLE … (LIKE … INCLUDING ALL) + COPY)
  ❌ NO — más simple es RENAME directo (sin COPY = cero data movement, instant)

Mig 2 — ALTER TABLE RENAME:
  - group_resources               → resources
  - group_resource_owners         → resource_owners
  - group_resource_rights         → resource_rights
  - group_resource_capabilities   → resource_capabilities
  (los triggers + FKs + policies + indexes + view group_event_calendar_view se re-asocian automaticamente)

Mig 3 — Crear compat views + INSTEAD OF triggers:
  CREATE VIEW public.group_resources AS SELECT * FROM public.resources;
  + INSTEAD OF INSERT trigger:
    - Inserta a resources, retorna NEW
    - Si decisión doctrinal = Opción B (mantener audit): emite log de "direct insert vía legacy view" antes de redirigir
  + INSTEAD OF UPDATE trigger: UPDATE resources SET … WHERE id = OLD.id
  + INSTEAD OF DELETE trigger: DELETE FROM resources WHERE id = OLD.id
  (idem para owners/rights/capabilities)

Mig 4 — Smoke comprehensive:
  - Correr todos los _smoke_resources_* + _smoke_action_governance_full + _smoke_global_search
  - Verificar: 96 funciones legacy siguen funcionando vía compat view
  - Verificar: las wrappers P2A/P2B-1.y siguen funcionando (`create_group_resource` invocado vía wrapper hace INSERT a la view, INSTEAD OF redirige a `resources`)

Mig 5 — Smoke específico R.0B.1:
  - Verificar audit trigger sigue loggeando (si Opción B)
  - Verificar cross-table writer `create_resource` sigue creando OWN right en `resource_rights`
```

**Cero cambios iOS en R.0B.1.** iOS sigue consumiendo `group_resources_active` / `group_resource_detail` RPCs — esas RPCs ahora leen de `resources` directo (vía SELECT … FROM resources) pero el nombre del RPC no cambia.

**Próximas fases R.0B.2+** (NO en R.0B.1):
- R.0B.2: migrar las 96 funciones legacy a SELECT/INSERT/UPDATE de `resources` directo (cosmético, ola por ola: 17 writers primero, luego 47 readers, después drop compat views).
- R.0B.3: `ALTER TABLE resources ALTER COLUMN group_id DROP NOT NULL` + `ADD COLUMN canonical_owner_actor_id uuid REFERENCES actors(id)` + backfill.
- R.0B.4: smoke nueva — crear resource sin `group_id` (personal), confirmar wrappers + readers no rompen.

---

## 7. Go / No-Go para R.0B.1

### Condiciones de Go

| # | Condición | Estado |
|---|---|---|
| 1 | Inventario completo | ✅ |
| 2 | Cero FK rotos en rename | ✅ Postgres maneja |
| 3 | Cero edge functions impactadas | ✅ |
| 4 | Cero direct table access iOS | ✅ |
| 5 | Estrategia compat documentada | ✅ §6 |
| 6 | Decisión doctrinal sobre audit trigger (Opción A vs B) | ⏳ **PENDIENTE FOUNDER** |
| 7 | Verificar que `d24_p2b1y` no introdujo writers no contemplados | ✅ Verificado — `create_generic_resource` delega, no inserta directo |
| 8 | Smokes existentes que validan el contrato post-rename | ✅ Hay 8+ smokes que cubren las RPCs writer principales |

### Recomendación

**GO con 1 condición pendiente:** decisión founder sobre `trg_log_group_resources_direct_insert` (Opción A = perder señal D.24 P2B-1 durante R.0B; Opción B = replicar audit en compat view, mantener señal).

**Riesgo bajo si Opción B.** Sin esa decisión, recomendado bloquear R.0B.1.

### NO-Go conditions

- ❌ NO arrancar R.0B.1 si la decisión sobre audit trigger no se toma.
- ❌ NO arrancar si en las próximas horas alguna otra sesión paralela está modificando RPCs en `group_resources*` (verificar git log antes).

---

## 8. Salida operativa (resumen estructurado)

### Dependencias encontradas
- 96 funciones DB (74 + 5 + 11 + 6) referencian las 4 tablas
- 14 FKs entrantes a `group_resources`
- 1 view dependiente (`group_event_calendar_view`)
- 11 archivos iOS (todos vía RPC, cero direct access)
- 0 edge functions con referencia directa
- 0 cron jobs

### Writers encontrados
- `group_resources`: 5 INSERTers + 11 UPDATErs + 2 DELETErs (ambos smokes)
- `group_resource_owners`: 1 I + 1 U
- `group_resource_rights`: 3 I + 4 U
- `group_resource_capabilities`: 2 I + 3 U
- **Total writers de producción: 26 funciones** (excluyendo 3 smokes)

### Blockers encontrados
1. 96 funciones referencian tablas por nombre en `prosrc` → require compat view + INSTEAD OF triggers.
2. Audit trigger D.24 P2B-1 — decisión doctrinal pendiente founder.

### Recomendación técnica
Compat-view-first approach. RENAME tabla, CREATE view con INSTEAD OF triggers (Opción B replicando audit), smoke comprehensive. iOS intacto. Funciones legacy intactas. Migración cosmética de funciones diferida a R.0B.2+.

### Go / No-Go
**GO con 1 condición pendiente** (decisión audit trigger). Sin esa decisión, **No-Go**.

### Commit hash
(pendiente — committee al cerrar)
