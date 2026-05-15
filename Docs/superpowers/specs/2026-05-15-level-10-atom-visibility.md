# Nivel 10 — Atom layer: gaps + visibility

**Fecha:** 2026-05-15
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Jerarquía:** `HierarchyReference.md` §1 (Layer 10 — Atom/Action)
**Migraciones base:** `00014` + `00078` (system_events + ledger_entries core), `00153/00154` (rsvp/check_in actions), `00162/00186` (atom guards), `00163` (vote_casts atom-only), `00174` (identity_atoms), `00192` (capability atoms)
**Spec hermana:** L0 spec proponía `MyTimelineView` cross-group en Pass 4 (deferido) — este spec lo aterriza.

## Problema

Nivel 10 — la capa de atoms — está **muy madura en BE**:
- 7+ tablas atom (`system_events`, `ledger_entries`, `rsvp_actions`, `check_in_actions`, `vote_casts`, `identity_atoms`, capability atoms)
- Append-only guards estrictos (mig 00162/00186 — UPDATE/DELETE rejected)
- 60+ event types whitelisted con `isHiddenFromUserActivity` filter
- Cron jobs procesan + emiten atoms sintéticos (hours_before_event, deadline_passed)
- 9 edge functions de procesamiento (process-system-events, dispatch-notifications, finalize-votes, etc.)

El FE expone **3 superficies de visibilidad**, pero con gaps:

1. **`ActivityView` (group-scoped)** — Cronología paginada de `system_events` filtrados por grupo. 60+ event types renderizados via `HistoryItemPresentation`. Chips: Todo / Dinero / Recursos / Gobernanza / Miembros. **Gap: NO hay filtro por miembro** (BE soporta `memberId` filter, UI no expone).

2. **`ActivitySectionView` (per-resource)** — Top 8 atoms del resource, settings-style list, **solo cubre 24 de los 60+ event types** (icon/label hardcoded en lugar de reusar `HistoryItemPresentation`). 36+ atoms aparecen como "Actividad" genérica.

3. **`MyLedgerView` (Profile)** — Solo money cross-group. NO hay cross-group timeline de atoms no-financieros. Usuario que confirmó 3 RSVPs en 3 grupos distintos esta semana no tiene dónde verlos juntos.

**Gaps mayores:**

1. **`MyTimelineView` no existe** (especificada en L0 Pass 4, diferida). El BE map propuso `my_activity_v1` SQL view union de rsvp_actions + check_in_actions + vote_casts + ledger_entries — sin implementar.

2. **`ActivitySectionView` icon/label drift** — 24 cases hardcoded en una función `iconFor(_:)` privada cuando `HistoryItemPresentation` ya cubre 60+. Code dup + drift garantizado.

3. **No filtro por miembro en `ActivityView`** — `SystemEventFilter.memberId` existe, sin UI.

4. **No audit UI para atoms técnicos** (rule_evaluations, identity_atoms, capability_atoms) — admins / soporte ciegos a forensics.

5. **Sin CSV export** — útil para auditoría externa o respaldo.

## Objetivo

Cerrar los 2 gaps más visibles:

- **`MyTimelineView` cross-group** que une rsvp_actions + check_in_actions + vote_casts + ledger_entries del usuario en TODAS sus membresías, ordenados cronológicamente. Entry desde `MyProfileView` (sección "Tu actividad" ya prepara el slot).
- **`ActivitySectionView` parity** — reusar `HistoryItemPresentation` en lugar de la función privada. 60+ event types renderizados consistentemente en el detalle del resource.

Pass 3+ (out of scope aquí): member filter en ActivityView, audit UI para atoms técnicos, CSV export.

## Approach — 3 pasadas, Pass 1+2 en este plan

### Pass 1 · `MyTimelineView` cross-group (4 tasks)

**BE — vista nueva (mig 00XXX):**

```sql
-- my_activity_v1 unifies user-scoped atoms across all groups for the
-- cross-group personal feed. RLS-permissive: per-table RLS already
-- restricts visibility; this view is transport convenience.
create or replace view public.my_activity_v1 as
  select 'rsvp'::text as kind, ra.id, ra.resource_id, gm.user_id,
         gm.group_id, jsonb_build_object('status', ra.status) as payload,
         ra.recorded_at as occurred_at
  from public.rsvp_actions ra
  join public.group_members gm on gm.id = ra.member_id
  union all
  select 'check_in', ca.id, ca.resource_id, gm.user_id, gm.group_id,
         jsonb_build_object('method', ca.metadata->>'check_in_method'),
         ca.recorded_at
  from public.check_in_actions ca
  join public.group_members gm on gm.id = ca.member_id
  union all
  select 'vote_cast', vc.id, vc.vote_id::uuid, gm.user_id, gm.group_id,
         jsonb_build_object('choice', vc.choice),
         vc.cast_at
  from public.vote_casts vc
  join public.group_members gm on gm.id = vc.member_id
  where vc.cast_at is not null and vc.choice <> 'pending'
  union all
  select 'ledger', le.id, le.resource_id, gmf.user_id, le.group_id,
         jsonb_build_object('type', le.type, 'amount_cents', le.amount_cents, 'currency', le.currency),
         le.occurred_at
  from public.ledger_entries le
  left join public.group_members gmf on gmf.id = le.from_member_id
  where gmf.user_id is not null;

-- The view inherits permissions from underlying tables' RLS.
grant select on public.my_activity_v1 to authenticated;
```

**FE:**

| Archivo | Acción |
|---|---|
| `supabase/migrations/00XXX_my_activity_view.sql` | NEW. SQL above |
| `RuulCore/Repositories/MyActivityRepository.swift` | NEW (~120 L). `loadRecent(limit:) async throws -> [MyActivityItem]`. Live: `from("my_activity_v1").select().eq("user_id", uid).order("occurred_at", ascending: false).limit(limit)`. Mock + Live. |
| `Features/Profile/Subscreens/MyTimelineView.swift` | NEW (~220 L). Feed agrupado por día. Cada item: icon (kind-specific) + label humano + group origin tag + relative time. Tap → resource detail (cuando aplica). |
| `Features/Profile/Views/MyProfileView.swift` | Modify. "Mi línea de tiempo" row en sección "Tu actividad" (slot ya documentado en L0 wireframe) |

### Pass 2 · `ActivitySectionView` parity (2 tasks)

| Archivo | Acción |
|---|---|
| `Features/Resources/Detail/Sections/ActivitySectionView.swift` | Modify. Reemplazar la lógica privada `iconFor(_:)` + `labelFor(_:)` con instanciación de `HistoryItemPresentation(event:memberName:)` y usar `.icon` + `.title` + `.tone` directamente. Mantener layout compact (settings-style row), pero alimentado por el mismo catalog que ActivityView |
| `Features/Activity/Views/HistoryItemPresentation.swift` | Si renderiza un layout heavy hoy, considerar agregar inicializador `compactRow` que skip subtitle/timestamp para listas inline. NO crear si la versión actual ya separa data (icon/title/tone) del rendering (que es lo que el L8 map sugirió) |

### Pass 3 (deferred): member filter + audit UI + CSV export

## Wireframe `MyTimelineView`

```
┌─────────────────────────────────────────┐
│  ⟵     Mi línea de tiempo               │
│  ─────────────────────────────────────  │
│  HOY                                     │
│  ─────────────────────────────────────  │
│  ✓  Confirmaste asistencia               │
│      Cena de jueves · Cenas con amigos   │
│      hace 2h                              │
│                                          │
│  💸  Pagaste $300                        │
│      Cuenta de cena · Cenas con amigos   │
│      hace 4h                              │
│                                          │
│  AYER                                    │
│  ─────────────────────────────────────  │
│  🗳️   Votaste                            │
│      Cambio de regla · Palco Azteca      │
│      hace 1d                              │
│                                          │
│  ✓  Check-in                             │
│      Cena de jueves · Cenas con amigos   │
│      hace 1d                              │
│                                          │
│  HACE 3 DÍAS                             │
│  ─────────────────────────────────────  │
│  ...                                      │
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **`my_activity_v1` es vista SQL, no tabla.** Sin writes adicionales. Hereda RLS de las tablas source. Pure transport convenience.

2. **NO incluir `system_events` en `my_activity_v1`** en V1 — son group-scoped events sin clear user attribution. La user-scoped subset (memberJoined, fineOfficialized to_member_id, etc.) podría agregarse Pass 3.

3. **MyTimelineView muestra solo atoms del usuario** (RSVPs propias, check-ins propios, votes propios, ledger entries donde `from_member.user_id = caller`). NO los del grupo entero.

4. **ActivitySectionView parity NO es estructural** — sigue siendo compact-row, no timeline. El cambio es: data source compartido con ActivityView.

5. **Tap en item de MyTimelineView** abre el resource detail cuando `resource_id` existe; para vote_cast abre VoteDetailView vía vote_id; para ledger sin resource va a MyLedgerView.

6. **Pagination de MyTimelineView**: V1 limit=100, sin pagination UI. Si demand crece → infinite scroll en Pass 3.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| `my_activity_v1` lento con muchos atoms | Índices en cada tabla source ya existen `(member_id, recorded_at desc)`. Limit obligatorio. Si lento → materializar |
| Vote_casts duplicados (latest per (vote, member)) | Filter `cast_at IS NOT NULL AND choice <> 'pending'` excluye pre-seeds. Si user re-cast, ambos aparecen — aceptable como historial |
| `from_member_id` puede ser NULL en ledger (group-level entries) | LEFT JOIN gmf + filter `gmf.user_id is not null` ya skipea esos |
| HistoryItemPresentation puede asumir env que ActivitySectionView no tiene | Inspeccionar si HistoryItemPresentation requiere `memberName?: String` — pasar nil o resolver via memberDirectory |
| Group origin tag requiere `groups` join — extra round-trip o cached | Reusar `app.groups` lista in-memory (ya cacheada por AppState) |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `MyActivityRepository.loadRecent`: returns 4 kinds. `MyTimelineView`: agrupación por día correcta. `my_activity_v1` view: returns RLS-permitted rows only |
| 2 | `ActivitySectionView`: renderiza correctamente para 5+ event types antes "fallback" (eventClosed, fineOfficialized, voteResolved, groupCreated, capabilityToggled). No drift visual con ActivityView para mismo event |

## Out of scope

- Pass 3 — member filter en ActivityView, audit UI para atoms técnicos, CSV export
- Realtime updates via Supabase subscriptions
- "Borrar mi actividad" (GDPR — diferido a L0 Pass 6 spec dedicado)
- Filtrar por tipo en MyTimelineView (V1 es flat)
- Cross-group ActivityView (toggle "todos los grupos" en ActivityView)
- Push notification cuando nueva actividad relevante aparece

## Done When

- 6 tasks committed (4 Pass 1 + 2 Pass 2).
- `my_activity_v1` view deployed.
- Tap "Mi línea de tiempo" en MyProfileView → MyTimelineView con feed cross-group.
- ActivitySectionView usa HistoryItemPresentation (60+ types parity).
- Build clean.
- Two tags: `level10-pass1-complete`, `level10-pass2-complete`.

## Cobertura del plan inicial

**Pass 1 + Pass 2 en el primer commit** (~6 tasks, 1 migración pequeña).
