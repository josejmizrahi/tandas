# R.7 — Governance Orchestration Engine

**Fecha:** 2026-06-08 (rewrite tras descubrimiento R.5 governance shipped sin doc)
**Status:** 🟡 DRAFT — founder firmó camino A 2026-06-08, implementación pendiente
**Companions:**
- `Plans/Active/R6_RuleEngineArchitecture.md` (Rule Engine 2.0 — Engine vecino)
- `Plans/Doctrine/F2X_IntentFirst_ContextualActions.md` (descriptor `available_actions[]`)
- `Plans/Active/MVP2_iOS_Contract.md` (RPCs canónicos + Decision Engine)
- `Plans/Active/R5V_UXDoctrine.md` (§0.4 action states canónicos)

---

## §0 — Historia del documento

**Iteración 1 (2026-06-08 AM):** Founder propuso R.6A Governance Engine como capa
nueva con `governance_action_catalog` + `governance_execution_log`, modelo PUSH
(engine invoca el RPC canónico).

**Iteración 2 (2026-06-08 PM):** Tras revisión doctrinal, founder renombró a R.7
**additive** sobre F.2X, R.6 y Decision Engine. Plan congelado con catalog v1 8
acciones, modelo PUSH centralizado, idempotency obligatoria.

**Iteración 3 (2026-06-08 tarde, este doc):** Durante kickoff de R.7.A descubrimos
infraestructura **R.5 governance shipped sin documentación en `Plans/Active/`**:
tablas `governance_actions` + `governance_policies`, RPCs `request_governed_action()`
+ `_governance_action_approved()` + `governance_policy()`, modelo **PULL** (RPC
canónico consulta antes de ejecutar), 1 consumer (`remove_member`).

Founder firmó **camino A**: preservar R.5 como base productiva, R.7 evoluciona, no
reemplaza ni paraleliza. Este doc reescribe el plan acorde.

> *"Paramos la migración R.7 actual. Se firma camino A. Reescribe el plan R.7
> tomando R.5 como base productiva. Preserva `governance_actions` y `governance_policies`;
> agrega catálogo declarativo, idempotency, aliasing de action keys y eventos faltantes.
> PULL queda como modelo principal; PUSH solo opt-in. No crear sistema paralelo ni
> deprecar R.5."* — Founder, 2026-06-08

---

## §1 — Modelo conceptual

### 1.1 PULL es el modelo principal (heredado de R.5)

```
iOS o caller invoca RPC canónico (ej. remove_member)
↓
RPC consulta _governance_action_approved(action_key, target)
↓
si aprobado → ejecuta lógica de negocio
si no → falla con 'requires_decision' y devuelve action_key para que iOS proponga
```

**Razón:** el RPC canónico ya sabe qué validaciones de negocio aplicar. Centralizar
ejecución (modelo PUSH) duplicaría esas validaciones en el engine. R.5 ya tenía esto
correcto.

### 1.2 PUSH es opt-in (nuevo en R.7)

Para casos donde el caller NO quiere conocer el RPC canónico (ej. R.6 Rule Engine
consequence type `request_governance_action`, o iOS sheet "Esta acción requiere
aprobación" cuando no quiere pasar por el descriptor), R.7 agrega:

```
caller invoca request_governance_action(action_key, payload)
↓
si requires_decision=true → crea decision (R.5 lo hace ya)
↓
al aprobarse decision → close_decision invoca execute_governance_action(decision_id)
↓
execute_governance_action lookup catalog → invoca execution_rpc
↓
si execution_rpc falla → status='failed' + error_message
```

PUSH es **complementario**, no reemplazo. PULL sigue siendo default.

### 1.3 Catálogo declarativo nuevo (defaults globales)

R.5 tenía `_governance_action_policy_key()` IMMUTABLE — hardcoded mapping action_key
→ policy_key. Limitado: no expone display_name, dominio, execution_rpc para PUSH,
ni 3-level permissions.

R.7 agrega `governance_action_catalog`:
- Define defaults globales (`requires_decision` por default si no hay policy).
- Expone `display_name`, `domain`, `execution_rpc`, `dangerous`, 3-level permissions.
- Reemplaza el hardcoded mapping de `_governance_action_policy_key()` con data-driven lookup.

### 1.4 Policies por contexto siguen overrideando (R.5 doctrine preserved)

`governance_policies(context_actor_id, policy_key, policy_value)` queda intacto.
La regla de decisión sigue siendo:

```
1. ¿Hay policy en este contexto para este action_key? → usa esa.
2. ¿No hay policy? → usa default global del catalog.
```

Esto permite que la Cena Semanal NO requiera voto para `fine.create` mientras la
Familia Mizrahi SÍ. R.5 ya tenía la mecánica; R.7 la documenta y le da defaults.

### 1.5 Action keys canonical: `domain.verb` + aliases legacy

R.5 usó snake_case (`remove_member`, `member_ban`, `resource_transfer`). R.7
canoniza a `domain.verb` (`member.remove`, `member.ban`, `resource.transfer`).

**Alias map firmado por founder:**

| Legacy (R.5 existente) | Canonical (R.7) |
|---|---|
| `remove_member` | `member.remove` |
| `ban_member` / `member_ban` | `member.ban` |
| `resource_transfer` | `resource.transfer` |
| `resource_sale` | `resource.sale` |
| `large_expense` | `expense.large` |
| `rule_change` | `rule.change` |
| `ownership_change` | `ownership.change` |

R.7 mantiene ambos lados funcionales: `_governance_action_policy_key()` se reescribe
data-driven (lookup en catalog) y el catalog tiene `legacy_aliases text[]` para que
`request_governed_action('remove_member', …)` resuelva al mismo row de catalog que
`request_governed_action('member.remove', …)`.

---

## §2 — Estado heredado de R.5 (lo que ya existe, NO se toca)

### 2.1 Tablas

**`governance_actions`** — log de auditoría + state combinado.

Columnas existentes:
- `id` (uuid PK), `context_actor_id` (FK actors CASCADE), `action_key` (text)
- `target_type` (text, nullable), `target_id` (uuid, nullable)
- `payload` (jsonb), `requires_decision` (boolean)
- `decision_id` (uuid FK decisions SET NULL)
- `status` (text CHECK: `not_required` | `proposed` | `approved` | `rejected` | `executed` | `cancelled`)
- `proposed_by_actor_id` (uuid FK), `executed_by_actor_id` (uuid FK), `executed_at`
- `created_at`, `updated_at`

Indexes existentes:
- `governance_actions_pkey` on `(id)`
- `idx_governance_actions_context` on `(context_actor_id, action_key)`
- `idx_governance_actions_decision` partial `(decision_id) where decision_id is not null`
- `idx_governance_actions_target` on `(context_actor_id, action_key, target_id)`

**`governance_policies`** — override por contexto.

Sin cambios planeados.

### 2.2 RPCs

- `request_governed_action(p_context_actor_id, p_action_key, p_target_type, p_target_id, p_payload, p_title, p_closes_at)` → equivalente PULL del R.7 entrypoint. Crea row en `governance_actions` con status `proposed` (si policy=true) o `not_required` (si no requiere). Crea decision automáticamente. Emite `governance.action_requested`.
- `_governance_action_approved(p_context_actor_id, p_action_key, p_target_id)` → helper SQL STABLE. Devuelve `governance_action_id` cuando hay aprobación. Usado por RPCs canónicos en modelo PULL.
- `_governance_action_policy_key(p_action_key)` → IMMUTABLE. Hardcoded mapping. **R.7 lo reescribe data-driven** (ver §6.2).
- `create_governance_policy` / `update_governance_policy` / `list_governance_policies` / `governance_policy` → gestión policy.
- `_smoke_r5_governance()` → smoke test.

### 2.3 Consumers PULL existentes

Hoy: **solo `remove_member`** consume `_governance_action_approved`. R.7 expande a más
RPCs canónicos según el catalog v1 firmado.

### 2.4 Activity events ya emitidos

- `governance.action_requested` — request_governed_action proposed path
- `governance.policy_set` / `governance.policy_removed` — gestión policy
- `governance.vote_delegated` / `governance.delegation_revoked` — vote_delegations (sistema vecino)

---

## §3 — Schema diffs propuestos por R.7

### 3.1 ALTER `governance_actions`: gaps firmados

```sql
alter table public.governance_actions
  add column idempotency_key text,
  add column client_id text,
  add column error_message text,
  add column result jsonb;

create unique index governance_actions_idempotency_key_uniq
  on public.governance_actions (idempotency_key)
  where idempotency_key is not null;
```

Sin backfill — rows existentes legítimamente sin idempotency.

**Status enum:** se agrega `'failed'` al CHECK constraint (PUSH execute_governance_action
puede fallar en runtime distinto a rejected).

```sql
alter table public.governance_actions
  drop constraint governance_actions_status_check;

alter table public.governance_actions
  add constraint governance_actions_status_check
  check (status in (
    'not_required', 'proposed', 'approved',
    'rejected', 'executed', 'cancelled',
    'failed'
  ));
```

### 3.2 Nueva tabla `governance_action_catalog`

```sql
create table public.governance_action_catalog (
  action_key text primary key,
  display_name text not null,
  domain text not null,                       -- 'membership' | 'resources' | 'money' | 'rules' | …
  default_requires_decision boolean not null default false,
  policy_key text,                             -- override per-context lives en governance_policies
  execution_rpc text,                          -- nullable: PULL no lo necesita; PUSH sí
  push_supported boolean not null default false,  -- true si execute_governance_action puede invocarlo
  dangerous boolean not null default false,
  request_permission text references public.permission_catalog(permission_key),
  vote_permission text references public.permission_catalog(permission_key),
  execute_permission text references public.permission_catalog(permission_key),
  legacy_aliases text[] not null default '{}',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index governance_action_catalog_domain_idx
  on public.governance_action_catalog (domain);

create index governance_action_catalog_aliases_idx
  on public.governance_action_catalog using gin (legacy_aliases);
```

### 3.3 Helpers nuevos

- `_governance_action_resolve(p_action_key) returns text` — devuelve el `action_key` canonical resolviendo aliases. Reemplaza `_governance_action_policy_key()` como punto de lookup.
- `_governance_action_catalog_row(p_action_key) returns governance_action_catalog` — fetch row resuelto.
- `_governance_action_policy_key(p_action_key)` → **rewritten** para hacer lookup en catalog en vez de CASE hardcoded. Devuelve `coalesce(catalog.policy_key, p_action_key || '_requires_vote')`.

---

## §4 — RPCs nuevas y modificadas

### 4.1 `request_governance_action()` — alias canonical de `request_governed_action()`

```sql
create or replace function public.request_governance_action(
  p_context_actor_id uuid,
  p_action_key text,
  p_target_type text default null,
  p_target_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_title text default null,
  p_closes_at timestamptz default null,
  p_client_id text default null
) returns jsonb …
```

Diferencias con `request_governed_action()`:
- Acepta `p_client_id` para idempotency.
- Calcula `idempotency_key = sha1(action_key_canonical || context_actor_id || coalesce(target_id::text, '') || coalesce(client_id, ''))`.
- Resuelve aliases vía `_governance_action_resolve` antes de policy lookup.
- Lee `default_requires_decision` del catalog si no hay policy en contexto.
- Si `idempotency_key` colisiona → devuelve row existente con `idempotent_replay: true`.
- Internamente delega a `request_governed_action()` después de resolución para no duplicar lógica.

**Idempotency:** garantiza que iOS retry no cree decisions duplicadas.

### 4.2 `execute_governance_action()` — PUSH opt-in (nuevo)

```sql
create or replace function public.execute_governance_action(
  p_governance_action_id uuid
) returns jsonb …
```

Flujo:
1. Lookup row. Validar status='approved' (post-decision).
2. Lookup catalog. Validar `push_supported=true`. Si no → return `{noop:true, reason:'pull_only'}`.
3. Lookup catalog `execution_rpc`. Si null → fail con error_message.
4. EXECUTE format('select %I(...)', execution_rpc) con payload mapping.
5. Update row status='executed', result, executed_at, executed_by_actor_id.
6. Si raise exception → status='failed', error_message.
7. Emit `governance.executed` o `governance.failed`.

**Quién llama:** R.6 consequence type futuro `request_governance_action` + cierre
automático en `close_decision` (sólo si catalog.push_supported=true).

### 4.3 `close_decision` — extension PUSH-aware

Cuando `close_decision` resuelve outcome='approved' y la decision tiene un
`governance_action` ligado:
- Update governance_action status='approved'.
- Si catalog.push_supported=true → invoca `execute_governance_action(id)` (best-effort, errores van a status='failed' + log).
- Si catalog.push_supported=false → status queda en 'approved', RPC canónico futuro lo consume vía PULL (`_governance_action_approved`).

Cuando outcome='rejected' → governance_action status='rejected'. Emit `governance.rejected`.

### 4.4 `_governance_action_policy_key()` — rewritten

```sql
create or replace function public._governance_action_policy_key(p_action_key text)
returns text language sql stable as $$
  with canon as (
    select coalesce(
      (select action_key from public.governance_action_catalog
        where action_key = p_action_key
           or p_action_key = any(legacy_aliases)
        limit 1),
      p_action_key
    ) as k
  )
  select coalesce(
    (select policy_key from public.governance_action_catalog gac, canon
      where gac.action_key = canon.k),
    canon.k || '_requires_vote'
  );
$$;
```

Backwards compatible con todos los llamadores actuales (devuelve mismo policy_key para
los hardcoded cases si el catalog seed los incluye correctamente).

---

## §5 — Compatibilidad firmada con sistemas existentes

### 5.1 R.6 Rule Engine

R.7 agrega consequence type `request_governance_action` (no `request_governed_action`,
nombre canonical) que invoca `request_governance_action()` con `client_id` derivado
del `rule_evaluations.idempotency_key`.

Consequence types directos (`emit_attention`, `create_obligation`, `create_fine`) NO
se migran. Coexistencia. R.6.F seeds (Palco / Familia Mizrahi) intactos.

### 5.2 F.2X `available_actions[]`

`available_actions[]` sigue siendo single source de UI.

Extensión opcional: cada entry puede llevar `mode: "direct" | "request_decision"`. Si
ausente → `direct` (comportamiento actual). El descriptor lo calcula:
- ¿action_key existe en catalog? Y ¿(policy en contexto = true) OR (catalog.default_requires_decision = true)? → `mode=request_decision`.
- Si no → `mode=direct`.

UI: cuando `mode=request_decision`, ActionRouter intercepta y abre sheet "Esta acción
requiere aprobación" en vez de invocar el RPC canónico directo.

### 5.3 Decision Engine

`create_decision` / `vote_decision` / `close_decision` / `execute_decision` siguen
canónicos.

`close_decision` extiende (§4.3) para resolver el `governance_action` ligado.

`execute_decision` NO se toca. PUSH es via `execute_governance_action`, no via
`execute_decision`.

### 5.4 Operaciones directas (NO pasan por governance)

RSVP, check-in, ver doc, editar perfil, reservar con derecho automático, etc.
NO entran al engine. Sin entry en catalog.

### 5.5 Migration posture

- ❌ No tocar `governance_actions` columnas existentes (solo agregar nuevas).
- ❌ No deprecar `request_governed_action()`. `request_governance_action()` lo invoca internamente.
- ❌ No deprecar `_governance_action_approved()`. Sigue siendo el helper PULL.
- ❌ No migrar `governance_policies` (queda intacta).
- ❌ No migrar seeds R.6 (Palco / Familia).
- ❌ No reemplazar RPCs canónicos. `remove_member` (único PULL consumer hoy) sin cambio.
- ✅ Agregar columnas idempotency/result/error a `governance_actions`.
- ✅ Crear `governance_action_catalog` declarativo.
- ✅ Seedear catalog v1 con aliases legacy.
- ✅ Reescribir `_governance_action_policy_key` data-driven (backwards compat).
- ✅ Agregar `request_governance_action` + `execute_governance_action`.
- ✅ Agregar `'failed'` al status CHECK.
- ✅ Agregar `mode` opcional en `available_actions[]`.

---

## §6 — Catalog v1 firmado (8 acciones)

**Decisión firmada:** seed catalog v1 sólo con acciones cuyo execution_rpc semánticamente
correcto exista. Todo lo demás queda backlog R.7.x.

| action_key (canonical) | domain | default_requires_decision | execution_rpc | push_supported | dangerous | legacy_aliases |
|---|---|---|---|---|---|---|
| `member.remove` | membership | true | `remove_member` | false (PULL único consumer) | true | `remove_member` |
| `member.pause` | membership | true | _TBD_ R.7.x — no RPC canónico aún | false | true | (none) |
| `member.promote` | membership | true | `assign_role` (role=admin) | true | false | (none) |
| `resource.archive` | resources | false | `archive_resource` | true | false | (none) |
| `resource.transfer` | resources | true | _TBD_ R.7.x — update_resource no acepta owner | false | true | `resource_transfer` |
| `fine.create` | money | true | `record_fine` | true | false | (none) |
| `rule.create` | rules | true | `create_rule` | true | false | (none) |
| `rule.archive` | rules | true | _TBD_ R.7.x — no RPC canónico aún | false | false | `rule_change` |

**Deferidas a R.7.x** (founder firmó dejarlas fuera v1 hasta que existan RPCs limpios):
`member.ban` (necesita `set_membership_state(banned)`), `resource.sell` (compuesto),
`fine.forgive` (necesita `forgive_obligation`), `rule.publish` (semánticamente
duplicado con `rule.create`).

**Acciones legacy R.5 que entran al catalog con `_TBD_ execution_rpc`** (para que el
data-driven `_governance_action_policy_key` siga funcionando):
- `expense.large` ← alias `large_expense` — policy_key `large_expense_requires_vote`
- `ownership.change` ← alias `ownership_change` — policy_key `ownership_change_requires_vote`
- `resource.sale` ← alias `resource_sale` — policy_key `resource_transfer_requires_vote`
- `rule.change` ← alias `rule_change` — policy_key `rule_change_requires_vote`

Estos rows sirven sólo para resolución policy_key. `push_supported=false` y
`execution_rpc=null`.

---

## §7 — Permisos 3 niveles (firmados §4 iteración 2)

- `request_permission` → poder proponer la acción (`decisions.create` por default).
- `vote_permission` → poder votar la decision (`decisions.vote`).
- `execute_permission` → ejecutar directo si NO requiere decision (`decisions.execute` por default).

`governance_action_catalog` tiene los 3 como FK a `public.permission_catalog`.

`request_governance_action()` valida `request_permission` antes de crear row.
`execute_governance_action()` valida `execute_permission` antes de invocar RPC canónico
(y debería re-validar permisos de negocio del RPC canónico también — defensa en
profundidad).

---

## §8 — Activity events

R.7 agrega los faltantes al catálogo (events emitidos son free text, sin migración
de constraint):

| Event type | Cuándo | Existing? |
|---|---|---|
| `governance.action_requested` | request_governance_action proposed path | ✅ R.5 |
| `governance.decision_created` | request_governance_action requires_decision=true | ❌ R.7 nuevo |
| `governance.approved` | close_decision → governance_action.status='approved' | ❌ R.7 nuevo |
| `governance.rejected` | close_decision → governance_action.status='rejected' | ❌ R.7 nuevo |
| `governance.executed` | execute_governance_action éxito | ❌ R.7 nuevo |
| `governance.failed` | execute_governance_action raise exception | ❌ R.7 nuevo |
| `governance.cancelled` | cancelación de governance_action antes de decision close | ❌ R.7 nuevo |
| `governance.policy_set` / `governance.policy_removed` | create/update/delete policy | ✅ R.5 |
| `governance.vote_delegated` / `governance.delegation_revoked` | vote_delegations vecino | ✅ R.5 |

Decisión: NO emitir `governance.requested` (duplicaría con `governance.action_requested`).
R.7 respeta el nombre R.5 existente.

---

## §9 — iOS surface

Cuando `available_action.mode = 'request_decision'`:
1. Tap → sheet de confirmación con título del catalog `display_name`.
2. CTA primario: "Crear decisión".
3. iOS invoca `request_governance_action(action_key, target, payload, client_id=UUIDv4)`.
4. Backend devuelve `{ requires_decision: true, governance_action_id, decision_id }`.
5. ActionRouter push `DecisionDetailView(decisionId:)`.

Si backend devuelve `{ requires_decision: false }` (policy o catalog default = false):
- iOS invoca el RPC canónico directo después (modelo PULL — no requiere governance overhead).
- O ActionRouter ejecuta el flow `direct` igual que hoy.

`AttentionItem` futuro `governance_pending` (kind nuevo) para que el proponente vea
sus governance_actions abiertas. Queda en backlog R.7.x.

---

## §10 — Idempotency

`request_governance_action()`:
- iOS suministra `client_id` (UUID generado al abrir la sheet, persiste hasta éxito).
- Backend calcula `idempotency_key = encode(extensions.digest(action_key_canonical || '|' || context_actor_id::text || '|' || coalesce(target_id::text, '') || '|' || coalesce(client_id, ''), 'sha1'), 'hex')`.
- Si `idempotency_key` ya existe en `governance_actions` → return existing row con `{ idempotent_replay: true }`.

`execute_governance_action()`:
- Es idempotente por status: si row.status='executed' → return `{ noop: true }`.
- Si row.status='failed' y se reinvoca → permite retry, vuelve a intentar el RPC canónico.

R.6 consequence type usa `rule_evaluations.idempotency_key` como `client_id` →
re-evaluations no duplican governance_actions.

---

## §11 — Slices de implementación

| Slice | Scope | DoD |
|---|---|---|
| **R.7.A** | Schema diffs (ALTER governance_actions + new catalog + new status value `failed`) + seed catalog v1 con aliases | 8 catalog rows + 4 alias-only rows + columnas idempotency/client_id/error_message/result en governance_actions + smoke `_smoke_r5_governance()` sigue verde |
| **R.7.B** | `request_governance_action()` + `_governance_action_resolve()` + rewrite `_governance_action_policy_key()` data-driven | Smoke: invocar con action_key canonical Y con alias legacy ambos resuelven mismo policy + idempotency replay devuelve mismo row |
| **R.7.C** | `execute_governance_action()` + `close_decision` extension PUSH-aware | Smoke: aprobación de decision con catalog.push_supported=true → ejecuta RPC canónico → status='executed'; con push_supported=false → status='approved' (PULL pending) |
| **R.7.D** | F.2X extension: descriptor expone `mode` opcional en `available_actions[]` | ContextDetail / ResourceDetail incluyen `mode='request_decision'` para action_keys con catalog row + requires_decision resolved |
| **R.7.E** | iOS Domain + ActionRouter: sheet confirmación + push DecisionDetailView + client_id idempotency | Build verde + install iPhone JJ + smoke flow `member.remove` en demo Familia Mizrahi |
| **R.7.F** | R.6 consequence type `request_governance_action` | Mig + smoke: rule custom con consequence `request_governance_action` invoca RPC y crea decision |

---

## §12 — Closure conditions

R.7 se considera CLOSED cuando:

1. ✅ Catalog v1 (8 acciones + 4 alias-only) seedado.
2. ✅ Columnas `idempotency_key`/`client_id`/`error_message`/`result` agregadas a `governance_actions`.
3. ✅ `'failed'` agregado al status CHECK.
4. ✅ `request_governance_action()` shipped + idempotency verificada con retry.
5. ✅ `_governance_action_policy_key()` data-driven shipped backwards compat (aliases legacy resuelven mismo policy_key).
6. ✅ `execute_governance_action()` shipped + close_decision extension PUSH-aware.
7. ✅ `available_actions[]` con `mode` opcional shipped backward-compatible.
8. ✅ iOS sheet + push DecisionDetailView shipped.
9. ✅ R.6 consequence type `request_governance_action` shipped + smoke con regla custom.
10. ✅ Cero regresión: `_smoke_r5_governance()` sigue verde + `remove_member` PULL flow sigue funcionando + seeds R.6 (Palco / Familia) siguen funcionando.

---

## §13 — Anti-patrones prohibidos

- ❌ Crear nueva tabla `governance_execution_log` paralela a `governance_actions`. **R.5 ya es source of truth.**
- ❌ Deprecar `request_governed_action()` o `_governance_action_approved()`. R.7 evoluciona, no reemplaza.
- ❌ Migrar `_governance_action_policy_key()` a hardcoded CASE nuevo. Data-driven obligatorio.
- ❌ Hacer que `execute_governance_action()` sea el único path. PULL es default.
- ❌ Hacer que `available_actions[]` se derive 100% de `governance_action_catalog`. Catalog es **complemento**, no fuente UI.
- ❌ Migrar consequence types R.6 a `request_governance_action`. Coexistencia.
- ❌ Eliminar `governance_policies` o forzar todos los contextos al catalog default. Policies por contexto siguen autoridad.
- ❌ Re-emit eventos legacy (`governance.action_requested`) con nombre nuevo (`governance.requested`). Respetar R.5.
- ❌ Crear capability system nuevo para 3-level permissions. Reusar `actor_capabilities` + `permission_catalog`.

---

## §14 — Open questions para founder (post-R.7.A)

Estos no bloquean R.7.A-F pero se decidirán cuando el catálogo crezca:

1. **Auto-execute al aprobar.** ¿`close_decision` invoca `execute_governance_action` auto cuando catalog.push_supported=true? ¿O requiere tap explícito de un admin? Plan actual: auto, best-effort.
2. **Cancelación.** ¿Quién puede cancelar un `governance_action` que ya tiene votos? Solo proponente / cualquier admin / nadie hasta close.
3. **Quórum por action_key.** Hoy quórum es propiedad de la decision. ¿Cada catalog row define su quórum por default? Probablemente sí en R.7.x.
4. **Multi-step actions.** `resource.sell` necesita 2 decisions secuenciales. Fuera de R.7 v1.
5. **Governance sobre el catalog.** Cambios al `governance_action_catalog` ¿requieren governance? Probablemente sí, pero queda backlog.
6. **PUSH para R.5 legacy aliases.** `expense.large` / `ownership.change` etc. están en catalog sólo para policy_key resolution. ¿Se cablean a RPCs canónicos eventualmente? Founder decide.

---

## §15 — Resumen ejecutivo

R.7 **evoluciona** R.5 governance shipped (que no estaba documentado en `Plans/Active/`).
Conserva `governance_actions` + `governance_policies` + `request_governed_action()` +
`_governance_action_approved()` (PULL model). Agrega:
- Catálogo declarativo (`governance_action_catalog`) con defaults globales + 3-level permissions.
- Idempotency en `governance_actions`.
- Action keys canonical `domain.verb` con aliases legacy para backwards compat.
- `request_governance_action()` (alias canonical con idempotency).
- `execute_governance_action()` (PUSH opt-in para R.6 + iOS sheet flow).
- 6 activity event types nuevos (preservando los 2 R.5 existentes).
- F.2X extension: `mode` opcional en `available_actions[]`.

**Cero regresión.** PULL sigue siendo default. PUSH es opt-in catalog-controlled.
Policies por contexto siguen autoridad. R.6 seeds intactos. RPCs canónicos sin cambio.

Founder firmó camino A 2026-06-08: *"R.7 debe reconocer R.5 como base shipped. No
duplicar governance."*

Próximo paso: R.7.A migration (ALTER + new catalog + seed v1 + aliases). Sin tocar
nada shipped excepto agregar columnas.
