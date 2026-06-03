# D.24 — Schema Consolidation Audit

**Status:** PHASE 0 only — audit produced, **NO migrations executed**.
**Verified against live DB** `wyvkqveienzixinonhum` 2026-06-01 vía MCP.
**Author note:** trabajo gated por aprobación founder antes de pasar a PHASE 1+.

---

## Resumen ejecutivo

Esta auditoría inventaría 13 áreas de consolidación pedidas por founder y cuantifica para cada una:

- tablas/columnas/RPCs afectadas (estado real, no asumido)
- volumetría (¿hay datos que migrar?)
- riesgos doctrinales (append-only guards, governance, RLS)
- compatibilidad iOS (¿qué stores/views se rompen?)
- estrategia de rollback

Recomendación global: **ejecutar por fases pequeñas, cada una en una sesión, con smoke + rollback file**. No mega-migration.

### Tabla pivote — qué existe vs qué hay que crear

| Recurso | Estado | Acción |
|---|---|---|
| `group_resources` (envelope 18 types, incluye `event`) | EXISTE | Reusar |
| `group_resource_events` (starts_at, ends_at, host_membership_id, rsvp_deadline, check_in_window, capacity, location, location_geo) | EXISTE | Reusar |
| `group_rsvp_actions` (resource_id, membership_id, rsvp_status, note, acted_at, source) | EXISTE | Reusar |
| `group_check_in_actions` | EXISTE | Reusar |
| `group_resource_capabilities` (resource_id, capability_key, enabled, config) | EXISTE | Reusar (reminders cap) |
| `group_resource_series` (recurrence) | EXISTE | Reusar |
| `group_calendar_events`, `group_calendar_event_attendees`, `group_calendar_event_reminders` (D.23) | EXISTE, **0 filas** | DEPRECAR |
| `assert_resource_type()` trigger | EXISTE × 22 subtype triggers | Reusar |
| `group_resources_resource_type_check` (whitelist) | INCLUYE `'event'` | OK |
| `group_resource_owners` | FALTA | Crear (PHASE 3) |
| `group_external_parties` | FALTA | Crear (PHASE 4) |
| `group_decisions.execution_status/error/attempts/payload` | FALTAN | Agregar (PHASE 5) |
| `group_comments` | FALTA | Crear (PHASE 6) |
| `group_attachments` | FALTA | Crear (PHASE 7) |
| `group_sanctions.appealed_at/appeal_decision_id/appeal_status` | FALTAN | Agregar (PHASE 8) |
| `group_role_assignment_events`, `group_mandate_events` | FALTAN | Crear (PHASE 9) |

---

## Hallazgo crítico — D.23 es el caso testigo

`event` ya estaba **first-class en `group_resources.resource_type_check`** (primer item del whitelist). El subtype `group_resource_events` ya tiene columnas equivalentes a las que creé en D.23. Volumetría:

```
group_calendar_events           = 0 rows
group_calendar_event_attendees  = 0 rows
group_calendar_event_reminders  = 0 rows
group_resources WHERE type=event= 0 rows
group_resource_events           = 0 rows
group_rsvp_actions              = 0 rows
```

**Conclusión:** D.23 creó tablas paralelas en un dominio donde la infra canónica existía y estaba sin datos. Costo doctrinal real, costo de migración de datos = cero. PHASE 1 = consolidar antes de que entren datos vivos.

**Mea culpa:** la prompt original de D.23 dijo *"salvo que ya exista arquitectura resource_kind"*. Existía. No lo vi como motivo suficiente y construí paralelo. Esta es exactamente la regla doctrinal `feedback_audit_verify_canonical_functions.md`.

---

## PHASE 1 — Consolidate Event model

### Mapeo wire-level

| D.23 (deprecar) | Canónico (target) |
|---|---|
| `group_calendar_events.id` | `group_resources.id` (resource_type='event') |
| `.title, .description, .visibility, .status, .metadata, .created_by, .archived_at` | `group_resources.{name,description,visibility,status,metadata,created_by,archived_at}` |
| `.starts_at, .ends_at, .location_name, .location_address` | `group_resource_events.{starts_at,ends_at,location,location_geo}` |
| `.timezone` | `group_resource_events.metadata.timezone` (no col separada, OK por jsonb) |
| `.recurrence_rule, .recurrence_parent_id` | `group_resource_series` (canon ya existe para series) |
| `event_type` (social/meal/...) | `group_resources.metadata.event_subtype` |
| `group_calendar_event_attendees.{membership_id, rsvp_status, rsvp_note, responded_at}` | `group_rsvp_actions.{membership_id, rsvp_status, note, acted_at}` |
| `.role (host/cohost/attendee/...)` | `group_resources.metadata.hosts[]` + (nuevo) capability `attendee_roles`? — **decisión pendiente** |
| `group_calendar_event_reminders` | `group_resource_capabilities` con `capability_key='reminders'`, `config={reminders:[{offset_minutes, target, type}]}` |

### RPCs afectadas (11 D.23 → wrappers o deprecadas)

| RPC actual | Acción |
|---|---|
| `create_event` | Convertir en wrapper que llama `create_group_resource(resource_type='event', ...)` + insert en `group_resource_events` |
| `update_event` | Wrapper → `update_resource_metadata` + update en `group_resource_events` |
| `cancel_event` | Wrapper → mover a `group_resource_events.cancelled_at` |
| `archive_event` | Wrapper → `archive_resource(resource_id)` (RPC canónico existente) |
| `list_group_events` | Wrapper sobre `group_resources WHERE resource_type='event'` JOIN `group_resource_events` |
| `get_event_detail` | Wrapper sobre `group_resource_detail(resource_id)` + agg RSVPs |
| `add_event_attendee` / `remove_event_attendee` | **Decisión pendiente:** RSVP-actions es append-only, no soporta "remove attendee". Posibilidad: capability `attendee_roster` con lista jsonb manejada por host. |
| `respond_event` | Wrapper → insert en `group_rsvp_actions` (append-only — historial preservado) |
| `add_event_reminder` / `remove_event_reminder` | Wrapper → upsert config en `group_resource_capabilities` |

### Read model recomendado (PHASE 1.D)

```sql
create view public.group_event_calendar_view as
select
    r.id, r.group_id, r.name as title, r.description, r.visibility,
    r.status, r.archived_at, r.created_at, r.created_by, r.metadata,
    e.starts_at, e.ends_at, e.location, e.location_geo,
    e.host_membership_id, e.rsvp_deadline, e.check_in_window, e.capacity,
    e.cancelled_at, e.closed_at,
    s.id as series_id,
    (select count(*) from group_rsvp_actions a
      where a.resource_id=r.id and a.rsvp_status='accepted') as accepted_count
from public.group_resources r
join public.group_resource_events e on e.resource_id=r.id
left join public.group_resource_series s on s.id=r.series_id
where r.resource_type='event';
```

Solo lectura. Nunca escritura.

### Riesgos

- **iOS** (CalendarEvent domain, store, repo, 3 views, GroupHome integration): seguirá funcionando contra los wrappers. Cuando los wrappers re-routeen a canon, el domain Swift puede mantener su shape vía el shape devuelto por `list_group_events`. **Costo iOS: cero si los wrappers preservan el contract de salida.**
- **Permisos `events.*`** (8 keys seedeadas en 73 grupos): mantener como aliases o redirigir a `resources.create / bookings.cancel / rsvp.submit`. Recomendación: mantener `events.*` durante la transición; `resources.create` ya cubre create-event vía el RPC canónico.
- **Audit log** `entity_kind='calendar_event'`: 0 rows. Re-mapear a `entity_kind='resource', resource_kind='event'` en wrappers.
- **`record_system_event`** sigue funcionando idéntico — solo cambia `entity_kind`.
- **Append-only en `group_rsvp_actions`**: significa que cambiar de "acepto" a "declino" agrega una fila nueva. UI debe mostrar el último por `(membership_id, resource_id)`. Esto es **doctrina engine vs vote** ya saved memory.

### Migración de datos

Cero (0 filas en D.23). No backfill necesario.

### Rollback strategy

1. Las tablas `group_calendar_events*` quedan como están (no drop) → "marca deprecated" via comment, no destructive.
2. Las RPCs `create_event/...` se renombran a `legacy_create_event` y los wrappers nuevos toman su nombre.
3. Si algo rompe iOS: revert RPC rename. iOS sigue hablando con `create_event` → `legacy_create_event` (los datos viejos no se mueven nunca).
4. Drop final de las tablas D.23 = sólo cuando founder firme; mínimo 1 release después de wrappers en prod.

---

## PHASE 2 — Resource invariants (envelope→subtype)

### Estado actual

- `assert_resource_type()` trigger × 22 instancias enforces **subtype→envelope**: si insertas en `group_resource_events` con `resource_id` cuyo envelope no es `event`, RAISE. **OK.**
- NO existe enforcement **envelope→subtype**: puedes crear `group_resources(resource_type='event')` sin la fila subtype correspondiente. **Esto es el gap.**

### Tasks PHASE 2

Crear RPCs canónicas (no triggers — los triggers introducen orden de inserción frágil):

```
create_event_resource(p_group_id, p_title, p_starts_at, p_ends_at, p_metadata)
  → BEGIN
    INSERT group_resources (resource_type='event', name=p_title, ...) RETURNING id
    INSERT group_resource_events (resource_id, starts_at, ends_at, ...)
    record_system_event('resource.created', entity_kind='resource', entity_id)
    COMMIT;
```

Idem para `create_asset_resource`, `create_space_resource`, `create_slot_resource`, `create_fund_resource`, `create_right_resource`.

**Decisión pendiente:** los RPCs canónicos existentes `create_group_resource` ya cubren parte de esto pero NO escriben el subtype atómicamente. Hay que auditar uno por uno cuáles ya son atómicos (per memory `V3 Resources Deep shipped`: "create_group_resource whitelist 10→18" — esto sugiere que es solo envelope, subtype va separado).

### Riesgos

- Existing rows con envelope sin subtype: query auditora antes de aplicar enforcement opcional como CHECK.
- iOS: las stores actuales probablemente llaman `create_group_resource` + subtype write. Migrar a un único RPC simplifica iOS — **iOS friendly**.

### Rollback

Trivial. Los nuevos RPCs no eliminan los viejos. Si fallan, revert al patrón 2-RPC.

---

## PHASE 3 — Ownership 2.0

### Estado

`group_resources.owner_membership_id` (single owner) + `ownership_kind` enum (`individual/group/shared/custodial/external`) + `ownership_metadata` jsonb.

NO existe `group_resource_owners`.

### Tasks

Crear:

```sql
group_resource_owners (
    id uuid pk,
    resource_id uuid → group_resources(id),
    membership_id uuid → group_memberships(id),
    owner_kind text check (in 'primary','co_owner','beneficiary','custodian','external_party'),
    ownership_pct numeric(6,3) check (between 0 and 100),
    ownership_role text,
    starts_at timestamptz default now(),
    ends_at timestamptz,
    source_decision_id uuid → group_decisions(id),
    metadata jsonb default '{}',
    constraint exactly_one_owner_target check (
        (membership_id is not null and external_party_id is null)
     or (membership_id is null     and external_party_id is not null)
    )
)
```

Nota: necesita `external_party_id` para custodian/beneficiary externos (PHASE 4).

### Backfill

```sql
insert into group_resource_owners (resource_id, membership_id, owner_kind, ownership_pct, source_decision_id)
select id, owner_membership_id, 'primary', 100, null
from group_resources
where owner_membership_id is not null;
```

### Governance

Cambios de ownership = `request_or_execute_action('resource.transfer_ownership')`. Catálogo `action_catalog` debe registrar el action (PHASE 10 deps).

### Riesgos

- iOS: `GroupResource.ownerMembershipId` queda como derived (primary owner). Vista nueva opcional para `co_owners[]`.
- `assert_resource_type` no aplica aquí (es polimórfico cross-type).
- RLS: nueva tabla necesita policy `select` para members + write SECURITY DEFINER.

### Rollback

`owner_membership_id` queda como columna canónica hasta firma. Si la transición rompe, revert dropping `group_resource_owners` (sin pérdida de datos: backfill puede correr de nuevo).

---

## PHASE 4 — External parties

### Estado

NO existe `group_external_parties`. Memberships solo modelan personas con `user_id` (auth.users).

### Tasks

```sql
group_external_parties (
    id uuid pk,
    group_id uuid → groups(id),
    party_type text check (in 'vendor','guest','venue','landlord','coach','organization','mediator','other'),
    display_name text not null,
    email text, phone text,
    status text default 'active' check (in 'active','archived','blacklisted'),
    metadata jsonb default '{}',
    created_by uuid → auth.users(id),
    created_at, updated_at, archived_at
)
```

+ RPC `create_external_party(...)` + RLS (members read, perm `external_parties.manage`).

### Compat

- D.23 `group_calendar_event_attendees.invited_email/invited_phone/display_name` puede mapearse a `external_parties` cuando consolidemos (PHASE 1 close).
- Money: pagar a `vendor` puede ir como `paid_to_external_party_id` en `group_resource_transactions` (futuro).

### Rollback

Trivial — drop table si no se usa.

---

## PHASE 5 — Decision execution hardening

### Estado

`group_decisions` tiene `status, executed_at, executed_by, execution_mode, result jsonb` pero NO tiene `execution_status, execution_error, execution_attempts, execution_payload`.

`execute_decision` RPC ya existe (D.18) pero sin retry/idempotency formal: si falla a la mitad, el row queda `status='passed'` y necesita re-llamada manual.

### Tasks

```sql
alter table group_decisions
    add column execution_status text default 'pending'
        check (execution_status in ('pending','executing','executed','failed','blocked')),
    add column execution_error text,
    add column execution_attempts int default 0,
    add column execution_payload jsonb default '{}';
```

Refactor `execute_decision`:
- BEGIN: mark `executing`, increment `execution_attempts`
- on success: `executed_status='executed', execution_payload={...result}`
- on fail: `'failed', execution_error=...`
- idempotency check: if status already `executing`, return early; if `executed`, return cached payload

### Riesgos

- iOS `DecisionStatus` enum ya tiene `executed` (D.18). Necesita nuevo derived `executionStatus` paralelo.
- Mig backfill: `execution_status='executed'` si `executed_at IS NOT NULL`.

### Rollback

Drop columns si no se usan. `execute_decision` revert via mig anterior preservada.

---

## PHASE 6 — Universal comments

### Estado

NO existe. La unica "discusión" en el sistema es `dispute_event_added` en `group_dispute_events` (específico a disputes).

### Tasks

```sql
group_comments (
    id uuid pk,
    group_id uuid → groups(id),
    entity_kind text not null,    -- 'decision','resource','dispute','sanction','rule','event'
    entity_id uuid not null,
    actor_membership_id uuid → group_memberships(id),
    body text not null check (length(btrim(body)) > 0),
    status text default 'active' check (in 'active','deleted','flagged'),
    metadata jsonb default '{}',
    created_at, updated_at, deleted_at
)
```

Index: `(group_id, entity_kind, entity_id, created_at desc)`.

RLS: members of group can read; only actor or `comments.moderate` perm can soft-delete.

RPC: `add_comment(p_entity_kind, p_entity_id, p_body)`, `delete_comment(p_id)`.

### Compat

- Cross-primitive: cualquier entity_kind. **No new table per primitive.**
- iOS: nuevo store `CommentsStore` + view `CommentsThreadView` embebida en cada detail view.

### Rollback

Trivial.

---

## PHASE 7 — Universal attachments

### Estado

NO existe. No hay storage path en uso.

### Tasks

```sql
group_attachments (
    id uuid pk,
    group_id uuid → groups(id),
    entity_kind text not null, entity_id uuid not null,
    uploaded_by_membership_id uuid → group_memberships(id),
    file_url text not null,        -- supabase storage path
    file_name text, mime_type text, size_bytes bigint,
    attachment_kind text check (in 'receipt','evidence','photo','document','other'),
    metadata jsonb default '{}',
    created_at, deleted_at
)
```

Storage bucket: `group-attachments`. RLS: members read, only uploader OR admin delete.

### Riesgos

- Supabase Storage policies necesitan crearse en paralelo.
- iOS: `PhotosPicker` + `Supabase.storage.from(...).upload()`. Nuevo módulo.
- Append-only? No — soft-delete con `deleted_at` para "borrar evidencia" sin perderla.

### Rollback

Trivial.

---

## PHASE 8 — Sanction appeals

### Estado

`group_sanctions.status` enum incluye `appealed`. Pero no hay columnas dedicadas para tracking del appeal flow.

### Tasks

```sql
alter table group_sanctions
    add column appealed_at timestamptz,
    add column appeal_decision_id uuid references group_decisions(id),
    add column appeal_status text default 'none'
        check (appeal_status in ('none','appealed','upheld','reduced','overturned'));
```

RPC: `start_sanction_appeal(p_sanction_id)` → crea `group_decision(reference_kind='sanction')` + setea `appealed_at, appeal_decision_id, appeal_status='appealed'`.

Wire `execute_decision` para sanction_appeal: cuando passa, setea `appeal_status` por result.

### Compat

- iOS `SanctionsStore.startAppeal` ya existe (memory: V2/V3). Necesita extender el shape devuelto.

### Rollback

Trivial.

---

## PHASE 9 — Role / Mandate audit

### Estado

`group_member_roles` table existe (membership_id × role_id). NO hay tabla de audit append-only para grants/revokes.

Mandates: existe `group_mandates` + iOS store. NO hay `group_mandate_events`.

### Tasks

```sql
group_role_assignment_events (
    id uuid pk, group_id, membership_id, role_id,
    action text check (in 'granted','revoked','expired'),
    actor_user_id, source_decision_id, reason text, metadata jsonb,
    occurred_at timestamptz default now()
);

group_mandate_events (
    id uuid pk, group_id, mandate_id,
    action text check (in 'granted','revoked','expired','executed_as'),
    actor_user_id, source_decision_id, reason, metadata jsonb,
    occurred_at
);
```

Ambos append-only (atom_no_delete_guard). Indexed por `(group_id, occurred_at desc)`.

RPCs existentes (`grant_role`, `revoke_role`, `grant_mandate`, `revoke_mandate`) DEBEN emitir a estas tablas. Auditar implementaciones.

### Compat

- iOS: `MemberHistoryView` / `MandatesListView` pueden mostrar el historial nuevo.

### Rollback

Trivial.

---

## PHASE 10 — Action governance audit

### Estado

Existe `action_catalog`, `request_or_execute_action`, `resolve_action_governance`. Memory `project_v3_d22_action_governance.md`: catálogo 105 acciones + 12 templates.

Pero hay RPCs **directas** que modifican estado crítico sin pasar por governance.

### Tasks PHASE 10 (audit-only en esta fase)

Generar reporte:

```sql
-- pseudo-query: list all RPCs in public schema that DELETE/UPDATE on critical tables
-- (group_memberships, group_decisions, group_sanctions, group_mandates,
--  group_resources, group_role_permissions, group_member_roles, groups)
-- AND don't internally call request_or_execute_action / resolve_action_governance
```

Output: `Plans/Active/D24P10_RPC_GovernanceBypass_Report.md`.

### Tareas derivadas (no en PHASE 10)

Cada RPC bypass = sesión separada. No hacer batch.

### Riesgos

- Algunos bypasses son intencionales (e.g. `create_event` debería ser direct para admin/founder vía perm `events.create` y NO pasar por vote). Doctrine `engine_vs_vote`: solo pasa por governance lo que **cambia autoridad**.
- Reporte debe clasificar cada RPC como `bypass_ok` vs `bypass_violation`.

### Rollback

PHASE 10 es solo reporte. Cero migración.

---

## PHASE 11 — Money roadmap (design doc only)

### Estado

Memory `v2_g4_2_sanction_payment_plans`, `v3_se_group_settlement_plan_for_member`, `v3_s1_split_engine_shipped`. Sistema actual: `group_resource_transactions`, `group_obligations`, `group_settlements`.

### Task

Crear design doc `Plans/Active/D24P11_DoubleEntryLedger.md`. Sin migración.

Diseño preliminar (founder review pendiente):

- `group_ledger_accounts` (group_id, account_kind, owner_membership_id?, resource_id?, currency, balance derived)
- `group_ledger_entries` (group_id, posted_at, description, reference_kind/id)
- `group_ledger_lines` (entry_id, account_id, debit/credit, amount, currency)

Invariant: sum(lines) per entry = 0 (double entry).

NO implementar sin firma.

---

## PHASE 12 — Read models

### Estado actual

Existen:
- `group_summary` RPC (D.x)
- `decision_detail`, `decision_provenance`, `decision_summary` (D.18)
- `group_resource_detail`
- `group_membership_boundary`
- `group_foundation_status`
- `group_events_recent`
- `group_money_movements_active`
- `global_search` (D.22)

Falta consolidar:
- `group_home_summary` — single RPC para hidratar GroupHome (hoy iOS hace 8-10 RPCs en `.task`)
- `event_attendance_summary` — agregado de RSVPs por evento
- `decision_live_result` — tally + cuanto falta para threshold
- `activity_feed` — unión paginada de `group_events` por tipo

### Riesgos

- iOS refactor non-trivial: cambiar 10 fetches por 1 implica re-cablear stores.
- Cada read model nuevo agrega superficie a mantener cuando cambien schemas. **Recomendación:** vistas materializadas con refresh on-demand vs views regulares con joins.

### Rollback

Trivial. Views son cheap.

---

## PHASE 13 — Final report

Se entregará tras completar PHASES 1-12. Estructura ya descrita en prompt founder.

---

## Orden de ejecución recomendado

1. **PHASE 1** (D.23 consolidation) — urgente, 1 sesión. Bloquea PHASES 4, 6, 7 si no se cierra.
2. **PHASE 5** (decision execution hardening) — 1 sesión. Bajo blast radius.
3. **PHASE 9** (role/mandate audit events) — 1 sesión. Append-only puro.
4. **PHASE 8** (sanction appeals) — 1 sesión. Extends existing.
5. **PHASE 4** (external parties) — 1 sesión. Standalone.
6. **PHASE 6** (comments) — 1 sesión. iOS work substantial pero contenido.
7. **PHASE 7** (attachments) — 2 sesiones (DB + storage + iOS).
8. **PHASE 3** (ownership 2.0) — 2 sesiones. Backfill delicado.
9. **PHASE 2** (envelope→subtype) — 1 sesión. Reqs PHASE 1 cerrado.
10. **PHASE 10** (governance bypass report) — 1 sesión audit-only.
11. **PHASE 12** (read models) — 2-3 sesiones (iOS-heavy).
12. **PHASE 11** (double-entry ledger design) — design doc only, sin implementación.
13. **PHASE 13** (final report) — al final.

Total estimado: ~15 sesiones distribuibles. NO mega-batch.

---

## Compatibilidad iOS — resumen

| Phase | iOS impact |
|---|---|
| 1 | Bajo: domain `CalendarEvent` puede mantenerse; wrappers preservan shape |
| 2 | Bajo: stores simplifican llamadas |
| 3 | Medio: nuevo `OwnersStore`; views opcional `CoOwnersSection` |
| 4 | Bajo: nuevo `ExternalPartiesStore` opcional |
| 5 | Bajo: extends `DecisionsStore`, nuevo derived state |
| 6 | Medio-Alto: nuevo `CommentsStore` + thread embebido en 6 detail views |
| 7 | Alto: `PhotosPicker` + storage SDK + nuevo módulo |
| 8 | Bajo: extends `SanctionsStore` |
| 9 | Bajo: read-only del audit en `MemberHistoryView` |
| 10 | Cero (audit-only) |
| 11 | Cero (design doc) |
| 12 | Alto: refactor de cargas iniciales |

---

## Estrategia de rollback global

1. **Cada migración tiene `_rollbacks/<version>_rollback.sql` correspondiente.** Patrón D.21 ya establecido.
2. **No drops destructivos en la misma fase.** Tablas obsoletas se marcan `comment on table 'DEPRECATED — drop in DX'` y se eliminan ≥1 release después.
3. **Smoke obligatorio antes de cierre.** Pattern D.17-D.23: DO block + rollback intencional para no contaminar.
4. **iOS guard:** ningún PR de schema sin build verde en Xcode + simulator manual run del flujo afectado.

---

## Doctrina derivada (a guardar como memory)

1. **Event = `resource_type='event'`.** No paralelo. Confirma `doctrine_canonical_schema_decisions`.
2. **Antes de crear tabla nueva:** verificar `group_resources_resource_type_check` + subtype tables + capabilities. Si la primitiva puede expresarse como (envelope + subtype + capability), úsala.
3. **Append-only tables solo se rolean por rollback dentro de la misma transacción.** Smoke tests con `RAISE EXCEPTION 'rollback_ok'` al final.
4. **Audit kind = `resource` con `resource_kind=<subtype>`** en `group_events` payload. No nuevos `entity_kind` por primitiva.
