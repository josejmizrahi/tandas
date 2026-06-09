# R.7 — Governance Orchestration Engine

**Fecha:** 2026-06-08
**Status:** 🟡 DRAFT — founder firmó doctrina + 7 huecos (2026-06-08), implementación pendiente
**Companions:**
- `Plans/Active/R6_RuleEngineArchitecture.md` (Rule Engine 2.0 — Engine vecino)
- `Plans/Doctrine/F2X_IntentFirst_ContextualActions.md` (descriptor `available_actions[]`)
- `Plans/Active/MVP2_iOS_Contract.md` (RPCs canónicos + Decision Engine)
- `Plans/Active/R5V_UXDoctrine.md` (§0.4 action states canónicos)

**Antecedente:** Founder propuso 2026-06-08 unificar acciones gobernables bajo modelo
`Action → Decision → Execution → Activity → Attention`. Primera versión chocaba con
R.6.A Rule Engine 2.0 ya shipped, con F.2X `available_actions[]`, con Decision Engine
canónico, y con catálogo de consequence types existentes. Founder firmó re-framing
**additive** como **R.7** (no R.6A) — Governance Engine es **capa de orquestación**
para acciones gobernables, no el nuevo path universal de toda acción.

---

## §0 — Por qué este doc existe ahora

Founder firmó 2026-06-08:

> *"Sí mejora el modelo, pero solo si entra como R.7. No debe reemplazar lo que ya existe:
> `available_actions[]`, `execute_resource_action`, `execute_decision`, rule consequences,
> RPCs canónicos. Debe ser una capa de orquestación para acciones gobernables, no el nuevo
> camino universal de toda acción."*

R.7 **no reemplaza** nada. Es additive. Coexiste con:

- R.6 Rule Engine consequence types (`emit_attention`, `create_obligation`, `create_fine`, etc.)
- F.2X `available_actions[]` (single source of truth de qué se muestra en UI)
- Decision Engine (`create_decision` / `vote_decision` / `close_decision` / `execute_decision`)
- RPCs canónicos (`record_expense`, `record_fine`, `create_resource`, `grant_right`, etc.)

R.7 únicamente **orquesta** acciones gobernables que requieren:
- aprobación colectiva (vía decision)
- ejecución diferida controlada
- auditoría centralizada de quién propuso / quién aprobó / quién ejecutó

---

## §1 — Modelo conceptual

```
Action
↓
(opcional) Decision
↓
Approval (vote close / direct execute)
↓
Execution (RPC canónico real)
↓
Activity Event
↓
Attention / Notifications
```

### 1.1 Acción ≠ Decisión

**Incorrecto (estado anterior):**
```
Crear multa = Crear votación = Ejecutar multa
```

**Correcto (R.7):**
```
Action     sanction.create_fine
Decision   ¿Aprobamos?
Execution  record_fine() RPC canónico
Activity   fine.created
```

### 1.2 Governance Engine no ejecuta negocio

El engine únicamente:
- **valida** (permisos, catálogo, payload)
- **decide** (¿requiere decision? ¿ya hay una abierta?)
- **orquesta** (crea decision o invoca RPC canónico)
- **audita** (`governance_execution_log`)

Nunca ejecuta lógica de negocio directamente. Cobrar, vender, reservar, transferir, etc.
siguen viviendo en los RPCs canónicos actuales.

### 1.3 Una acción puede requerir decisión o no

| Action | requires_decision |
|---|---|
| `member.invite` | no |
| `member.ban` | sí |
| `resource.sell` | sí |
| `resource.check_in` | no (sigue directo, ni entra a governance) |

### 1.4 Rule Engine y Governance Engine comparten lenguaje

Las reglas R.6 ya **no insertan SQL** (doctrina R.6.0). En R.7, una regla puede emitir
un consequence nuevo:

```json
{ "kind": "request_governance_action", "action_key": "fine.create", "payload": { "amount": 500 } }
```

R.6 mantiene sus consequence types existentes (`emit_attention`, `create_obligation`,
`create_fine`). El nuevo es **adicional**, no reemplazo.

---

## §2 — Compatibilidad firmada con sistemas existentes

### 2.1 Compat con R.6 Rule Engine

**Decisión firmada:** coexistencia, no reemplazo.

R.6 mantiene los consequence types directos shipped:
- `emit_attention` (R.6.A)
- `create_obligation` (R.6.B)
- `create_fine` (R.6.F seed Familia Mizrahi)
- futuros `create_conflict`, `pause_rule`, etc.

R.7 agrega un nuevo consequence type:
- `request_governance_action` → invoca `request_governance_action()` RPC

**Seeds existentes NO se migran.** Palco (gasto > $5000 → `emit_attention`) y Familia
(check-in tarde → `create_fine`) siguen funcionando como están. Migración a governance
es opt-in cuando convenga (ej. si el founder decide que `create_fine` automático debe
pasar a votación en algún contexto, se reemplaza el consequence en esa rule específica).

### 2.2 Compat con F.2X `available_actions[]`

**Decisión firmada:** `available_actions[]` sigue siendo single source de truth para UI.

El descriptor de Context / Resource / Document / etc. sigue devolviendo
`available_actions[]` y la UI sigue gateándose por ahí.

`governance_action_catalog` **no es** la fuente UI. Es el catálogo de orquestación que
dice "si una acción se invoca, ¿requiere decision? ¿qué RPC se ejecuta?".

Una action puede aparecer en `available_actions[]` con un nuevo campo opcional
`mode`:
- `mode: "direct"` (default) → tap → invoca RPC canónico directo (comportamiento actual)
- `mode: "request_decision"` → tap → invoca `request_governance_action()` que crea decision

Si la action no tiene entry en `governance_action_catalog`, se asume `mode: "direct"`
(zero break con todas las actions actuales).

### 2.3 Compat con Decision Engine

**Decisión firmada:** `execute_decision` sigue siendo entrypoint canónico.

Nuevo flujo:
```
execute_decision(decision_id)
↓
si decision.metadata.governance_action_key existe
  → execute_governance_action(decision_id)  [nuevo R.7]
  → lookup catalog
  → execution_rpc(payload)
↓
en caso contrario → comportamiento legacy de execute_decision
```

`execute_decision` NO se deprecia. `create_decision` / `vote_decision` / `close_decision`
NO se tocan.

### 2.4 Operaciones directas (NO pasan por governance)

**Decisión firmada:** estas operaciones siguen siendo path directo. NO entran al engine.

- RSVP a evento
- Check-in en evento
- Ver documento
- Subir documento
- Editar perfil
- Reservar recurso cuando el usuario tiene derecho automático
- Pagar cuando no requiere aprobación
- Marcar tarea completada

Son **operaciones**, no gobernanza. El engine no debería verlas.

### 2.5 Qué SÍ pasa por governance

Solo acciones que afectan:
- membresía (ban, suspend, promote)
- derechos sobre recursos (grant/revoke right cuando está restringido)
- propiedad (transfer, sell, change_owner)
- dinero relevante (multas, gastos extraordinarios sujetos a aprobación)
- reglas (publish, archive de rule activa)
- governance misma (cambio de quórum, política, roles)
- resolución de conflictos escalada

### 2.6 Postura de migración

R.7 es **additive**.

- ❌ No migración de R.6 seeds existentes
- ❌ No deprecación de RPCs canónicos
- ❌ No reemplazo de `execute_resource_action`
- ❌ No reemplazo de `execute_decision`
- ❌ No reemplazo de `available_actions[]`
- ✅ Nuevo catálogo `governance_action_catalog`
- ✅ Nuevos RPCs `request_governance_action` / `execute_governance_action`
- ✅ Nuevo consequence type `request_governance_action` en R.6
- ✅ Nuevo campo opcional `mode` en `available_actions[]`
- ✅ Nuevo activity event family `governance.*`

---

## §3 — Catalog v1 firmado (8 acciones)

**Decisión firmada:** seed inicial mínimo. Todo lo demás queda backlog R.7.x.

| action_key | domain | requires_decision | execution_rpc | dangerous |
|---|---|---|---|---|
| `member.ban` | membership | true | `remove_member` | true |
| `member.suspend` | membership | true | `assign_role` (role=suspended) | true |
| `member.promote` | membership | true | `assign_role` (role=admin) | false |
| `resource.transfer` | resources | true | `update_resource` (canonical_owner_actor_id) | true |
| `resource.sell` | resources | true | `archive_resource` + emit money intent | true |
| `fine.create` | money | true | `record_fine` | false |
| `fine.forgive` | money | true | `mark_settlement_paid` (override) | false |
| `rule.publish` | rules | true | `create_rule` (with active=true) | false |

Todo lo demás de la lista exploratoria del founder (member.invite, resource.reserve,
resource.grant_right, expense.approve, settlement.finalize, policy.change, quorum.change,
role.create, vote.delegate, rule.pause, rule.override, etc.) queda en **backlog R.7.x**
y se agrega cuando un flow concreto lo necesite.

---

## §4 — Schema

### 4.1 Tabla `governance_action_catalog`

```sql
create table public.governance_action_catalog (
  action_key text primary key,
  display_name text not null,
  domain text not null,             -- 'membership' | 'resources' | 'money' | 'rules' | 'governance' | ...
  requires_decision boolean not null default false,
  decision_template_key text,       -- referencia a decision template canónico (nullable si direct)
  execution_rpc text not null,      -- nombre del RPC canónico que ejecuta la acción
  dangerous boolean not null default false,
  request_permission text,          -- capability key requerido para proponer
  vote_permission text,             -- capability key requerido para votar (cuando requires_decision)
  execute_permission text,          -- capability key requerido para ejecución directa
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
```

### 4.2 Tabla `governance_execution_log`

```sql
create table public.governance_execution_log (
  id uuid primary key default gen_random_uuid(),
  action_key text not null references public.governance_action_catalog(action_key),
  context_actor_id uuid not null,
  requested_by_actor_id uuid not null,
  decision_id uuid,                 -- null si direct execution
  target_type text not null,
  target_id uuid not null,
  execution_rpc text not null,
  status text not null,             -- 'requested' | 'awaiting_decision' | 'executed' | 'rejected' | 'cancelled' | 'failed'
  requested_at timestamptz not null default now(),
  executed_at timestamptz,
  payload jsonb not null default '{}'::jsonb,
  result jsonb,
  idempotency_key text unique,      -- sha1(action_key || context_actor_id || target_id || client_id)
  client_id text                    -- opcional, suministrado por iOS para retry-safety
);

-- Anti doble ejecución (decisión firmada §7):
create unique index governance_execution_log_one_execution_per_decision
  on public.governance_execution_log (decision_id)
  where status = 'executed' and decision_id is not null;
```

### 4.3 Activity events seed (decisión firmada §5)

Nuevos `event_type` en `activity_events`:
- `governance.requested`
- `governance.decision_created`
- `governance.approved`
- `governance.rejected`
- `governance.executed`
- `governance.cancelled`
- `governance.failed`

Estos eventos son **subscribibles por R.6 Rule Engine** desde el primer día → permite
meta-reglas (ej. "alertar si hay 3 governance.rejected del mismo proponente en 30 días").

---

## §5 — RPCs

### 5.1 `request_governance_action()`

**Quién llama (decisión firmada §2):**
- iOS cuando una entry de `available_actions[]` tiene `mode: "request_decision"`
- R.6 Rule Engine cuando consequence `kind: "request_governance_action"`

**Nadie más.** Los RPCs canónicos NO auto-invocan governance. Evitamos magia invisible.

**Entrada:**
```json
{
  "action_key": "fine.create",
  "context_actor_id": "...",
  "target_type": "actor",
  "target_id": "...",
  "payload": { "amount": 500, "currency": "MXN" },
  "client_id": "uuid-from-ios-for-idempotency"
}
```

**Flujo:**
1. Lookup `governance_action_catalog` por `action_key`. Error si no existe.
2. Validar `request_permission` (decisión firmada §4 — 3 niveles).
3. Calcular `idempotency_key`. Si ya existe en `governance_execution_log` → return existing.
4. Si `requires_decision = false`:
   - Validar `execute_permission`.
   - Insert log status `requested`.
   - Invocar `execution_rpc` con `payload`.
   - Update log status `executed` + `result`.
   - Emitir `governance.executed`.
5. Si `requires_decision = true`:
   - Crear decision con `metadata.governance_action_key = action_key` + `metadata.governance_payload = payload`.
   - Insert log status `awaiting_decision` con `decision_id`.
   - Emitir `governance.requested` + `governance.decision_created`.
   - Return `{ decision_id, status: 'awaiting_decision' }`.

**Salida:**
```json
{ "execution_log_id": "...", "decision_id": "...", "status": "executed" | "awaiting_decision" | "noop_duplicate" }
```

### 5.2 `execute_governance_action()`

**Quién llama:** `execute_decision` cuando la decision aprobada tiene
`metadata.governance_action_key`. No se llama desde iOS directamente.

**Entrada:**
```json
{ "decision_id": "..." }
```

**Flujo:**
1. Lookup decision. Validar `status='approved'`.
2. Lookup `governance_execution_log` por `decision_id`.
3. Si ya existe row con `status='executed'` → return `{ noop: true }` (anti doble ejecución).
4. Lookup `governance_action_catalog` por `action_key` del decision metadata.
5. Invocar `execution_rpc` con `payload`.
6. Update log status `executed` + `executed_at` + `result`.
7. Emitir `governance.approved` + `governance.executed`.

**Anti doble ejecución (decisión firmada §7):** además del partial unique index
defensivo, el RPC valida explícitamente antes de invocar el RPC canónico.

---

## §6 — Permisos 3 niveles (decisión firmada §4)

Separar capability keys distintos para cada fase:

| Permiso | Significado | Almacenado en |
|---|---|---|
| `request_permission` | Puede proponer la acción | `governance_action_catalog.request_permission` |
| `vote_permission` | Puede votar la decision | `governance_action_catalog.vote_permission` |
| `execute_permission` | Puede ejecutar directo si NO requiere decision | `governance_action_catalog.execute_permission` |

**Razón doctrinal:** alguien puede tener derecho a **proponer** una sanción aunque
no tenga derecho a **ejecutarla** solo. El admin puede ejecutar directo `member.ban`
si la política lo permite; un miembro regular puede sólo proponer (que abre decision).

Mapping a capabilities existentes via `actor_capabilities` (R.5A descriptor) — no
inventar capability system nuevo.

---

## §7 — iOS surface (decisión firmada §6)

Cuando iOS encuentra un `available_action` con `mode: "request_decision"`:

1. Tap del usuario en la action row.
2. Sheet de confirmación:
   - Title: "Esta acción requiere aprobación"
   - Body: descripción del action_key (catalog `display_name`) + lista de quién aprueba.
   - CTA primario: "Crear decisión"
   - CTA secundario: "Cancelar"
3. Al confirmar:
   - iOS invoca `request_governance_action()` con `client_id` para idempotency.
   - Backend responde `{ decision_id, status: 'awaiting_decision' }`.
   - `ActionRouter` push `DecisionDetailView(decisionId:)`.
4. El usuario ve la decision recién creada, puede compartirla, otros pueden votar.

**No fire-and-forget.** El usuario siempre aterriza en la decision para ver el estado.

**Para `mode: "direct"`** (default) el comportamiento actual se preserva: ActionRouter
invoca el RPC canónico directo. R.7 no toca este path.

**AttentionItem nuevo (futuro, no v1):** kind `governance_pending` para que el
proponente vea decisions abiertas que él inició. Queda en backlog R.7.x.

---

## §8 — Idempotency (decisión firmada §3)

`request_governance_action()` debe recibir `client_id` desde iOS (UUID generado
client-side al abrir la sheet de confirmación, persistido hasta éxito).

Backend calcula `idempotency_key = sha1(action_key || context_actor_id || target_id || client_id)`
y lo persiste en `governance_execution_log.idempotency_key UNIQUE`.

Segundo request con mismo `client_id` → return existing log row con
`status: 'noop_duplicate'`. Evita doble decision si iOS retry-ea.

Patrón heredado de R.6.A (idempotency_key sha1 con `extensions.digest`).

---

## §9 — Slices de implementación

| Slice | Scope | DoD |
|---|---|---|
| **R.7.A** | Schema + catalog v1 seed + activity event types | 8 catalog rows + 7 event types + mig replay verde |
| **R.7.B** | `request_governance_action()` RPC + idempotency + log | Smoke: direct path (member.promote en demo) + decision path (member.ban en demo) |
| **R.7.C** | `execute_governance_action()` RPC + `execute_decision` delegation + partial unique index | Smoke: aprobación de decision → ejecuta RPC canónico → log status executed |
| **R.7.D** | F.2X extension — `available_actions[]` gana campo `mode` opcional | Descriptor de Context/Resource expone `mode: "request_decision"` para `member.ban`, `resource.transfer`, etc. |
| **R.7.E** | iOS surface — sheet confirmación + ActionRouter push DecisionDetailView | Build verde + install iPhone JJ + smoke flow member.ban en demo |
| **R.7.F** | R.6 consequence type `request_governance_action` | Mig + smoke: rule custom con consequence `request_governance_action` invoca RPC y crea decision |

Slices A-C son backend puro. D-E son cutover iOS. F integra con Rule Engine.

---

## §10 — Closure conditions

R.7 se considera CLOSED cuando:

1. ✅ Catalog v1 (8 acciones) seedado y consultable.
2. ✅ `request_governance_action()` shipped + idempotency verificada con retry.
3. ✅ `execute_governance_action()` shipped + partial unique index verificado con doble call.
4. ✅ `execute_decision` delegation shipped sin romper decision flows existentes.
5. ✅ `available_actions[]` con `mode` shipped backward-compatible (descriptor sin campo = direct).
6. ✅ iOS sheet de confirmación + push DecisionDetailView shipped.
7. ✅ R.6 consequence type `request_governance_action` shipped + smoke con regla custom.
8. ✅ Cero regresión: todos los flows actuales (RSVP, check-in, record_expense directo,
   create_resource, etc.) siguen funcionando sin tocar el engine.

---

## §11 — Anti-patrones prohibidos

- ❌ Hacer que `available_actions[]` se derive de `governance_action_catalog`. Son fuentes distintas.
- ❌ Reemplazar consequence types de R.6 con `request_governance_action`.
- ❌ Hacer que RPCs canónicos (`record_fine`, `remove_member`, etc.) auto-invoquen `request_governance_action`.
- ❌ Hacer que `execute_decision` siempre pase por `execute_governance_action` (solo cuando metadata lo indica).
- ❌ Saltarse `governance_execution_log` desde el RPC canónico (la auditoría depende de él).
- ❌ Migrar seeds R.6 existentes (Palco / Familia) a governance sin signal explícito del founder.
- ❌ Crear capability system nuevo para 3-level permissions — reusar `actor_capabilities`.

---

## §12 — Open questions para founder (post-implementación)

Estos no bloquean R.7.A-F pero se decidirán cuando el catálogo crezca:

1. **Quórum por action_key.** ¿Cada catalog row define su quórum (ej. `member.ban` requiere 75%, `resource.sell` requiere unanimidad)? ¿O el quórum vive en context settings?
2. **Auto-execute al aprobar.** ¿`execute_governance_action` corre auto cuando `close_decision` cierra con outcome `approved`? ¿O requiere tap explícito de un admin?
3. **Cancelación.** ¿Quién puede cancelar un governance request que ya tiene votos? ¿Solo el proponente? ¿Solo admin?
4. **Multi-step actions.** ¿Cómo se modela una acción que requiere 2 decisions secuenciales (ej. `resource.sell` → primero aprobar venta, luego aprobar precio)? Probablemente fuera de R.7 v1.
5. **Governance sobre governance.** ¿Cambios al `governance_action_catalog` mismo requieren governance? (probablemente sí, pero queda para R.7.x).

---

## §13 — Resumen ejecutivo

R.7 añade una capa de orquestación opt-in para ~8 acciones críticas que requieren
aprobación colectiva. Reusa Decision Engine (no lo reemplaza), reusa F.2X
`available_actions[]` (lo extiende con `mode`), reusa Rule Engine R.6 (le añade un
consequence type). Cero impacto en flows directos actuales (RSVP, check-in, gastos
normales, creaciones de recurso, etc.).

Auditoría centralizada vía `governance_execution_log`. Idempotency vía `client_id` +
sha1 hash. Anti doble ejecución vía partial unique index + lookup defensivo.

**Founder firmó:** doctrina additive, catalog v1 (8 acciones), 3-level permissions,
7 activity events, sheet confirmación + push DecisionDetailView, idempotency obligatoria,
`execute_governance_action` idempotente con noop si ya ejecutado.

Próximo paso: programador toma R.7.A (schema + catalog seed) y abre PR contra `main`.
