# Pre-Phase2 Architecture Consolidation Plan

> Plan ejecutable para consolidar la arquitectura de Ruul antes de Fase 2.
>
> Objetivo: salir del estado híbrido `V1 event-centric + V2 resource-centric` y dejar una base limpia para que Ruul pueda crecer hacia Rotation, Slot, Asset, Fund, Tandas, Palcos y grupos multi-vertical sin deuda estructural.
>
> Este plan parte de:
>
> - `Plans/Audit-2026-05-06.md`
> - revisión directa de Supabase production project `fpfvlrwcskhgsjuhrjpz`
> - `Docs/Ruul-Social-Primitives-and-Product-Logic.md`
>
> Fecha de creación: 2026-05-07

---

## 0. TL;DR

Ruul ya tiene la arquitectura correcta diseñada, pero todavía no vive completamente en ella.

Estado actual:

```text
V1 event-centric runtime
+
V2 resource-centric foundation
```

Meta:

```text
Template
  → Group
  → Resource
  → Rule
  → Vote
  → Fine
  → SystemEvent
  → History
```

Antes de Fase 2, hay que consolidar 6 piezas:

1. Activar `resources` como capa real, no tabla vacía.
2. Hacer `fines` y `fine_review_periods` polimórficos con `resource_id`.
3. Matar `group_type` como fuente conceptual; `base_template` gana.
4. Completar `templates-as-data` y reconciliar `defaultRules`.
5. Crear `rule_slug` estable para reglas lógicas.
6. Definir qué vive en `groups` vs qué vive en `resources/settings/modules`.

El resultado esperado es que Fase 2 pueda construir Rotation/Assignment sin pelear contra el modelo viejo.

---

## 1. Principio arquitectónico rector

La arquitectura canónica de Ruul debe ser:

```text
Template → Resources → Rules → Votes → Fines → History
```

No:

```text
GroupType → hardcoded behavior → event-only fines
```

### Definiciones

#### Group

Contenedor social.

Debe responder:

- quiénes somos;
- quién pertenece;
- qué template usamos;
- qué governance default aplica;
- qué módulos están activos;
- branding/presentación básica.

#### Template

Configuración serializable de un tipo de grupo.

Debe definir:

- presentación;
- categoría;
- módulos default;
- reglas default;
- governance default;
- settings default;
- resource types esperados;
- onboarding flow.

#### Resource

Objeto gobernable.

Puede ser:

- event;
- rotation;
- position;
- assignment;
- slot;
- asset;
- fund;
- contribution;
- payout;
- booking;
- rule;
- fine;
- proposal.

#### Rule

Norma evaluable sobre eventos o recursos.

Debe tener:

- `id` UUID técnico;
- `slug` lógico estable;
- `name` visible;
- `conditions`;
- `consequences`;
- `is_active`;
- snapshots cuando afecte multas o historia.

#### Fine

Consecuencia de incumplimiento.

Debe poder apuntar a cualquier recurso:

```text
fine.resource_id → resources.id
```

No solo:

```text
fine.event_id → events.id
```

#### SystemEvent

Memoria inmutable del sistema.

Ya está bien orientado porque tiene `resource_id`.

---

## 2. Estado actual detectado en Supabase

### 2.1 Lo bueno

Supabase ya tiene:

- `templates` con `config jsonb`.
- `resources` con `resource_type`, `status`, `metadata`.
- `system_events.resource_id`.
- `votes` polimórfico con `vote_type`, `reference_id`, `payload`.
- `groups.base_template`.
- `groups.active_modules`.
- `groups.settings jsonb`.
- `group_members.roles jsonb`.
- `rules.conditions` y `rules.consequences`.

Esto confirma que el modelo nuevo ya existe.

### 2.2 Lo malo

Todavía existe deuda estructural:

- `resources` tiene `0 rows`.
- `fines` no tiene `resource_id`; sigue con `event_id`.
- `fine_review_periods` sigue con `event_id UNIQUE`.
- `groups.group_type` sigue vivo con enum rígido.
- `groups` está demasiado cargado con fields operacionales.
- `appeals`, `appeal_votes`, `vote_ballots` siguen coexistiendo con `votes`/`vote_casts`.
- `rules` todavía tiene columnas legacy deprecated.
- Falta `rule_slug` o equivalente estable lógico.

### 2.3 Diagnóstico

Ruul está en transición:

```text
El diseño correcto existe,
pero el runtime sigue siendo principalmente event-centric.
```

La prioridad no es agregar features nuevas. La prioridad es hacer que la app viva realmente sobre la arquitectura nueva.

---

## 3. Resultado final deseado

Al terminar este plan:

### 3.1 Resources ya no estará vacío

Cada `event` nuevo debe tener un `resource` correspondiente.

Ideal:

```text
events.id == resources.id
```

Si eso no es posible por compatibilidad inmediata:

```text
events.resource_id → resources.id
```

La opción recomendada es:

```text
events.id == resources.id
```

porque simplifica:

- history;
- fines;
- votes;
- deep links;
- resource repository;
- migration mental model.

### 3.2 Fines será resource-centric

`fines` debe tener:

```sql
resource_id uuid references public.resources(id)
```

Durante transición:

```text
fines.event_id nullable legacy
fines.resource_id canonical
```

### 3.3 Fine review periods será resource-centric

`fine_review_periods` debe tener:

```sql
resource_id uuid references public.resources(id)
```

con unique sobre `resource_id`, no sobre `event_id`.

### 3.4 Template será la taxonomía principal

`groups.base_template` gana.

`groups.group_type` queda:

- deprecated;
- backfilled desde `base_template` si hace falta;
- removido del código;
- drop DB en una fase posterior.

### 3.5 Rules tendrán slug lógico estable

Agregar:

```sql
rules.slug text
```

con unique parcial:

```sql
unique(group_id, slug)
```

O, si se quiere permitir múltiples versiones de la misma regla:

```sql
unique(group_id, slug, created_at/version)
```

Recomendación V1:

```sql
unique(group_id, slug)
```

porque es más simple y suficiente para Fase 2.

### 3.6 Groups se limpia conceptualmente

`groups` se mantiene como contenedor social. Lo operacional nuevo debe ir hacia:

- `resources.metadata`;
- `groups.settings`;
- `templates.config`;
- futuras tablas específicas (`rotations`, `assignments`, `funds`) cuando haga falta.

---

## 4. Orden recomendado de ejecución

El orden importa.

No conviene empezar por dual-write si antes no se decide cómo mapear `events` a `resources`.

Orden recomendado:

```text
A. Resource identity strategy
B. Backfill resources for existing events
C. Dual-write new events to resources
D. Add fines.resource_id + fine_review_periods.resource_id
E. Switch rule engine / RPCs to resource_id canonical
F. Add rule.slug stable ids
G. Complete templates-as-data parity
H. Remove GroupType from app logic
I. Cleanup legacy voting/rules columns
J. Write verification + acceptance tests
```

---

# Phase A — Decide Resource Identity Strategy

## Goal

Definir si `events.id` será igual a `resources.id` o si `events` tendrá `resource_id` separado.

## Recommendation

Usar:

```text
events.id == resources.id
```

## Why

Pros:

- minimiza joins;
- permite deep links simples;
- `system_events.resource_id` puede apuntar al mismo UUID que antes era `event_id`;
- backfill de fines es directo;
- no hay que agregar `events.resource_id`;
- reduce migración mental.

Cons:

- hay que insertar resources con IDs existentes durante backfill;
- hay que asegurar que futuros inserts de event creen resource con el mismo ID.

## Decision

Locked recommendation:

```text
For event resources, resources.id = events.id.
```

Para futuros resource types, `resources.id` será generado normalmente.

---

# Phase B — Backfill resources for existing events

## Goal

Crear un row en `resources` por cada row existente en `events`.

## Migration draft

```sql
insert into public.resources (
  id,
  group_id,
  resource_type,
  status,
  metadata,
  created_by,
  created_at,
  updated_at
)
select
  e.id,
  e.group_id,
  'event',
  e.status,
  jsonb_build_object(
    'title', e.title,
    'starts_at', e.starts_at,
    'ends_at', e.ends_at,
    'location', e.location,
    'host_id', e.host_id,
    'cycle_number', e.cycle_number,
    'source_table', 'events'
  ),
  e.created_by,
  e.created_at,
  e.updated_at
from public.events e
where not exists (
  select 1
  from public.resources r
  where r.id = e.id
);
```

## Acceptance criteria

```sql
select count(*) from public.events;
select count(*) from public.resources where resource_type = 'event';
```

The counts must match.

## Risk

If `resources` already has rows with conflicting IDs, migration fails.

Current production check showed `resources.rows = 0`, so risk is low.

---

# Phase C — Activate dual-write for new events

## Goal

Every future event creation must also create a resource row.

## Options

### Option 1 — DB trigger

Create trigger on `events`:

```sql
create or replace function public.sync_event_to_resource()
returns trigger
language plpgsql
security definer
as $$
begin
  insert into public.resources (
    id,
    group_id,
    resource_type,
    status,
    metadata,
    created_by,
    created_at,
    updated_at
  ) values (
    new.id,
    new.group_id,
    'event',
    new.status,
    jsonb_build_object(
      'title', new.title,
      'starts_at', new.starts_at,
      'ends_at', new.ends_at,
      'location', new.location,
      'host_id', new.host_id,
      'cycle_number', new.cycle_number,
      'source_table', 'events'
    ),
    new.created_by,
    new.created_at,
    new.updated_at
  )
  on conflict (id) do update set
    group_id = excluded.group_id,
    status = excluded.status,
    metadata = excluded.metadata,
    updated_at = excluded.updated_at;

  return new;
end;
$$;

create trigger trg_sync_event_to_resource
before insert or update on public.events
for each row
execute function public.sync_event_to_resource();
```

### Option 2 — Application/RPC dual-write

Update every RPC/client write path that creates/updates events.

## Recommendation

Use DB trigger for V1 consolidation.

Reason:

- prevents missed write paths;
- protects old clients;
- guarantees parity;
- faster to validate.

Later, when `ResourceRepository` becomes canonical, app writes can move directly to resources.

## Acceptance criteria

1. Create event from app.
2. Verify same UUID exists in `resources`.
3. Update event status.
4. Verify `resources.status` updates.

---

# Phase D — Add resource_id to fines and fine_review_periods

## Goal

Make fines and review periods polymorphic.

## Migration draft

```sql
alter table public.fines
add column if not exists resource_id uuid references public.resources(id) on delete set null;

alter table public.fine_review_periods
add column if not exists resource_id uuid references public.resources(id) on delete cascade;

update public.fines f
set resource_id = f.event_id
where f.event_id is not null
  and f.resource_id is null;

update public.fine_review_periods frp
set resource_id = frp.event_id
where frp.event_id is not null
  and frp.resource_id is null;

create index if not exists idx_fines_resource_id
on public.fines(resource_id);

create unique index if not exists idx_fine_review_periods_resource_id_unique
on public.fine_review_periods(resource_id)
where resource_id is not null;
```

## Transition rule

During transition:

```text
resource_id = canonical
event_id = legacy compatibility
```

## Later cleanup

After all code stops reading `event_id`:

```sql
alter table public.fines drop column event_id;
alter table public.fine_review_periods drop column event_id;
```

Do not drop in this phase.

## Acceptance criteria

```sql
select count(*)
from public.fines
where event_id is not null and resource_id is null;
```

Must be `0`.

```sql
select count(*)
from public.fine_review_periods
where event_id is not null and resource_id is null;
```

Must be `0`.

---

# Phase E — Switch rule engine and RPCs to resource_id canonical

## Goal

All fine creation paths must write `resource_id`.

## Likely affected backend areas

- `propose_fine` RPC.
- Rule engine sink that creates fines.
- Manual fine officialization flow.
- Fine appeal flow if it assumes event.
- Fine review period creation.
- Any edge function that references `event_id`.

## Required behavior

For event fines:

```text
resource_id = event.id
legacy event_id = event.id
```

For future non-event fines:

```text
resource_id = resource.id
event_id = null
```

## Acceptance criteria

- Manual fine on event creates both `resource_id` and `event_id`.
- Auto fine on event creates both.
- Future test insert with non-event resource can create fine with `event_id = null`.
- Fine detail UI still renders existing fines.

## Suggested test SQL

```sql
select
  id,
  event_id,
  resource_id,
  reason,
  amount
from public.fines
order by created_at desc
limit 20;
```

---

# Phase F — Add stable rule.slug

## Goal

Separate stable logical rule identity from display copy.

## Why

`rules.id` is stable technically, but templates/modules need logical stable identifiers.

Display strings are not IDs.

Bad:

```text
"Llegada tardía"
```

Good:

```text
late_arrival
```

## Migration draft

```sql
alter table public.rules
add column if not exists slug text;

update public.rules
set slug = case
  when lower(coalesce(name, title, code, '')) like '%tard%' then 'late_arrival'
  when lower(coalesce(name, title, code, '')) like '%confirm%' then 'missed_rsvp_deadline'
  when lower(coalesce(name, title, code, '')) like '%show%' or lower(coalesce(name, title, code, '')) like '%present%' then 'no_show'
  when lower(coalesce(name, title, code, '')) like '%men%' then 'host_no_menu'
  else regexp_replace(lower(coalesce(name, title, code, id::text)), '[^a-z0-9]+', '_', 'g')
end
where slug is null;

create unique index if not exists idx_rules_group_slug_unique
on public.rules(group_id, slug)
where slug is not null;
```

## Important caution

The backfill above is only a draft. Before running, inspect actual rule names to avoid slug collisions.

Recommended pre-check:

```sql
select group_id, coalesce(name, title, code) as label, count(*)
from public.rules
group by group_id, coalesce(name, title, code)
order by count(*) desc;
```

Then inspect proposed slugs.

## Swift changes

- Add `slug` to Rule model.
- Update template default rules to include slug.
- Update module provided rules to reference slug, not display string.
- Keep `name` as display text.

## Acceptance criteria

- Every active rule has non-null slug.
- No display string is used as an ID.
- Changing rule name does not break module references.

---

# Phase G — Complete templates-as-data parity

## Goal

Make `templates.config.defaultRules` and related template config canonical.

## Current risk

There may be drift between:

- Swift hardcoded defaults;
- RPC seed defaults;
- `templates.config.defaultRules`;
- mocks/fixtures.

## Required decision

Canonical source:

```text
templates.config.defaultRules
```

Not Swift hardcode.

Not one-off RPC logic.

## Work

1. Inspect `templates` rows.
2. Confirm default rules for `recurring_dinner`.
3. Reconcile amounts, active flags, condition types, names, slugs.
4. Update seed RPC to read from `templates.config.defaultRules`.
5. Update Swift Template model to read config.
6. Update mock repositories.
7. Remove template-specific default rule hardcoding where possible.

## Acceptance criteria

- Creating a recurring dinner group seeds rules from `templates.config.defaultRules`.
- No drift between Swift and DB default rules.
- Rule slugs match template config.
- Adding a future template does not require editing DinnerRecurring template code.

---

# Phase H — Remove GroupType from app logic

## Goal

Stop using `groups.group_type` as product taxonomy.

## Current problem

`groups` has both:

```text
group_type
base_template
category
```

This creates three overlapping classification systems.

## Canonical model

```text
base_template = exact template id
category = high-level segment / visual grouping
group_type = legacy only, deprecated
```

## Migration plan

### Step H1 — Backfill consistency

```sql
update public.groups
set base_template = case
  when base_template is null or base_template = '' then group_type
  else base_template
end;
```

Map old `group_type` values to templates if needed:

```text
recurring_dinner → recurring_dinner
tanda_savings → rotating_savings
poker → poker_pot
travel → shared_trip
other → custom
```

### Step H2 — App reads only base_template

Swift `Group` model should not expose `groupType` as primary product type.

Allowed compatibility:

```swift
var legacyGroupType: String?
```

but no product decisions should depend on it.

### Step H3 — DB deprecation comment

```sql
comment on column public.groups.group_type is
'DEPRECATED — use base_template + category. Kept temporarily for backward compatibility.';
```

### Step H4 — Future drop

Only after app and RPCs stop reading it:

```sql
alter table public.groups drop column group_type;
```

Do not drop in first pass.

## Acceptance criteria

- New group creation writes `base_template`.
- UI chooses presentation from `templates.config.presentation` or Template model.
- No Swift switch on `GroupType` for behavior.
- `group_type` can be null/deprecated without breaking app logic.

---

# Phase I — Define what lives in groups

## Goal

Prevent `groups` from becoming a dumping ground.

## Rule

`groups` should contain only:

- identity;
- membership container fields;
- template identity;
- high-level category;
- governance defaults;
- active modules;
- settings jsonb;
- branding/avatar.

Operational domain state should move elsewhere.

## Keep in groups

Recommended to keep:

- `id`
- `name`
- `description`
- `created_by`
- `currency`
- `timezone`
- `governance`
- `base_template`
- `active_modules`
- `settings`
- `category`
- `initials`
- `avatar_url`
- `created_at`
- `updated_at`

## Move out over time

Should not continue growing in `groups`:

- `fund_balance`
- `fund_target`
- `fund_admin`
- `rotation_enabled`
- `rotation_mode`
- `default_day_of_week`
- `default_start_time`
- `default_location`
- `auto_generate_events`
- `fines_enabled`
- `block_unpaid_attendance`

## Where they should go

### Event defaults

```text
groups.settings.eventDefaults
```

or template config.

### Fund state

Future:

```text
resources(type='fund')
```

or dedicated:

```text
funds
```

with corresponding resource row.

### Rotation state

Future:

```text
rotations
positions
assignments
```

with corresponding resource rows.

### Fines config

```text
groups.settings.fines
```

or template governance config.

## Acceptance criteria

- No new top-level columns on `groups` for resource-specific features unless explicitly justified.
- New Phase 2 primitives use resources/tables/settings, not more group columns.

---

# Phase J — Cleanup legacy voting/rules objects

## Goal

Remove or fully deprecate old parallel systems.

## Legacy objects

- `appeals`
- `appeal_votes`
- `vote_ballots`
- deprecated `rules` columns: `code`, `title`, `trigger`, `action`, `enabled`, `status`

## Recommendation

Do not drop all immediately if app still reads them.

Instead:

1. Confirm no active code path writes legacy tables.
2. Backfill any needed legacy data into `votes` / `vote_casts` / `fines.appeal_vote_id`.
3. Add comments marking deprecated.
4. Create final drop migration later.

## Acceptance criteria before drop

```sql
select count(*) from public.appeals;
select count(*) from public.appeal_votes;
select count(*) from public.vote_ballots;
```

Must be either:

- zero, or
- safely migrated.

---

## 5. Required verification queries

Run these after each phase.

### 5.1 Resource coverage for events

```sql
select
  (select count(*) from public.events) as events_count,
  (select count(*) from public.resources where resource_type = 'event') as event_resources_count;
```

### 5.2 Events without resources

```sql
select e.id, e.group_id, e.title, e.created_at
from public.events e
left join public.resources r on r.id = e.id
where r.id is null;
```

Must return zero rows.

### 5.3 Fines without resource_id

```sql
select id, event_id, resource_id, reason, created_at
from public.fines
where resource_id is null;
```

After Phase D/E, should be zero for event fines.

### 5.4 Fine review periods without resource_id

```sql
select id, event_id, resource_id, created_at
from public.fine_review_periods
where resource_id is null;
```

Should be zero after backfill.

### 5.5 Rules without slug

```sql
select id, group_id, coalesce(name, title, code) as label
from public.rules
where slug is null;
```

Should be zero for active/current rules after Phase F.

### 5.6 Legacy classification usage

```sql
select group_type, base_template, category, count(*)
from public.groups
group by group_type, base_template, category
order by count(*) desc;
```

Use this to confirm migration mapping.

### 5.7 Templates config sanity

```sql
select id, version, name, available, jsonb_object_keys(config) as config_key
from public.templates
order by id;
```

Confirm every template has required keys.

---

## 6. App / Swift workstreams

Database is only half the job.

### 6.1 Models

Update or verify:

- `Resource`
- `EventResource`
- `Rule`
- `Fine`
- `FineReviewPeriod`
- `Template`
- `Group`

### 6.2 Repositories

Add or consolidate:

- `ResourceRepository`
- `TemplateRepository`
- `RuleRepository`
- `FineRepository`

Event repository can remain for V1 screens, but should start leaning on resources.

### 6.3 UI implications

No major UI redesign required immediately.

But UI should stop assuming:

```text
all actionable things are events
```

Instead prepare for:

```text
actionable things are resources
```

### 6.4 Deep links

Move toward:

```text
ruul://group/{groupId}/resource/{resourceId}
```

Instead of only:

```text
ruul://group/{groupId}/event/{eventId}
```

### 6.5 History

History should render by:

```text
resource_id + event_type + payload
```

not only event-specific assumptions.

---

## 7. Edge Functions / RPC workstreams

Need audit/update of all functions that reference:

```text
event_id
rules.code
rules.title
rules.trigger
rules.action
group_type
```

### 7.1 Must inspect

- event creation RPCs;
- recurrence generation;
- rule engine evaluation;
- fine proposal/manual fine;
- fine officialization;
- appeal creation;
- vote creation/finalization;
- notifications outbox;
- history/system event emitters.

### 7.2 Rule

During transition, write both fields when applicable:

```text
resource_id = canonical
event_id = legacy compatibility
```

Never write only `event_id` in new code.

---

## 8. Testing plan

### 8.1 Migration tests

- Run migrations on fresh local DB.
- Run migrations on copied prod schema/data if possible.
- Verify backfill counts.
- Verify no null resource IDs for event fines.

### 8.2 Smoke tests

1. Create recurring dinner group.
2. Create event.
3. Confirm resource row exists.
4. RSVP.
5. Trigger late/no-show fine.
6. Confirm fine has `resource_id`.
7. Start appeal vote.
8. Finalize vote.
9. Check history.
10. Check notifications outbox.

### 8.3 Regression tests

- Existing events still render.
- Existing fines still render.
- Existing appeals still render or migrate.
- Rule change voting still works.
- Manual fine still works.
- OpenVotesView still works.

### 8.4 Future-readiness test

Create a non-event resource manually:

```sql
insert into public.resources (group_id, resource_type, status, metadata)
values ('<group_id>', 'slot', 'scheduled', '{"label":"Test slot"}'::jsonb)
returning id;
```

Then create a fine pointing to that resource with `event_id = null`.

If that works, Fase 2/3 is unblocked conceptually.

---

## 9. Rollout strategy

### 9.1 Do not big-bang the entire cleanup

Recommended rollout:

```text
Migration 1: Backfill resources + trigger dual-write
Migration 2: Add resource_id to fines/review periods + backfill
Migration 3: Update RPCs/rule engine to write resource_id
Migration 4: Add rule.slug + backfill
Migration 5: Template parity + GroupType deprecation
Migration 6: Legacy cleanup comments/indexes
```

### 9.2 Keep legacy columns during transition

Do not immediately drop:

- `fines.event_id`
- `fine_review_periods.event_id`
- `groups.group_type`
- rules legacy columns
- legacy appeal tables

First make app independent. Drop later.

### 9.3 Use comments aggressively

Every deprecated column should say:

```sql
comment on column ... is 'DEPRECATED — use ...';
```

This prevents future sessions from reviving dead patterns.

---

## 10. Definition of Done

This architecture consolidation is done when:

### Data layer

- Every event has matching resource row.
- Every new event creates/updates matching resource row automatically.
- Every fine has `resource_id`.
- Every fine review period has `resource_id`.
- New non-event resource can receive a fine.
- Rules have stable logical slug.
- Template config is canonical for default rules.

### App layer

- App no longer uses `GroupType` for product behavior.
- App can read template presentation/config.
- App can render existing event-centric views without regression.
- Fine UI still works with resource-backed fines.

### Architecture layer

- `resources` is no longer empty.
- `resource_id` is canonical in new logic.
- `event_id` is legacy compatibility only.
- `groups` is no longer the place for new domain-specific fields.

### Product layer

- Dinner recurring still works.
- Beta 1 can run without architecture lying to itself.
- Fase 2 can start with Rotation/Assignment without redoing fines/templates/resources.

---

## 11. Recommended next action

Start with Phase A/B/C together:

```text
Resource identity strategy
+
Backfill event resources
+
DB trigger dual-write
```

This is the highest-leverage move because it turns `resources` from a theoretical table into the real backbone of Ruul.

Then immediately do:

```text
fines.resource_id
+
fine_review_periods.resource_id
```

After those two, the architecture finally starts behaving like the vision.

---

## 12. Brutal truth

Ruul does not need more vision right now.

Ruul needs consolidation.

The product already knows where it wants to go:

```text
self-governed recurring groups
```

The database already hints at the right future:

```text
templates + resources + votes + system_events
```

But until `resources` becomes real and fines stop depending on `event_id`, Ruul is still operationally a dinner/event app with future-facing tables.

This plan exists to cross that bridge before building Fase 2.
