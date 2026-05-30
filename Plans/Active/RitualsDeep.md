# Batch D — Rituals al máximo nivel de detalle

> Plan canónico para llevar la Primitiva 21 (Rituals) a su máximo nivel
> de detalle siguiendo Universal Detail layered doctrine. **Ejecutable
> en una sesión nueva**. Cada fase tiene Inputs / Outputs / DoD / Smoke
> explícito para que el agente que la tome no necesite re-derivar.

## TL;DR

Hoy los rituales son entidades muertas en iOS — solo Create/Edit/List
existen, sin detail view, sin occurrence tracking, sin completion
flow. Esta sesión cierra ese gap con **5 fases ordenadas + 1 fase
opcional**. Total estimado: **5-7 commits**, ~3-4 horas de trabajo
sincrónico, build verde + install device al cierre.

**Prefijo de commits**: `v3-deep: Rituals <fase>`.

## Estado de partida (verificar al arrancar)

Esta sesión cierra con:
- Sesión previa: Money tab cerrado (Q1-Q4 + redesign hero/pool).
  Último commit en `main`: `3c0b958c`.
- 26 commits + 29 migs en BD desde sesión inicial. Build verde.
- iPhone install pipeline mature: `iPhone de JJ` ID
  `E63668BF-3B28-5F51-B678-519B203E48CC`. Build for-device via
  `xcodebuild` + install via `xcrun devicectl device install app`.

**Pre-flight checks obligatorios**:
1. `git status` clean → si hay cambios sin commit, parar y reportar.
2. `git log --oneline -3` confirma `3c0b958c` o posterior.
3. `mcp__supabase__list_migrations` confirma 29+ migs aplicadas.
4. `mcp__supabase__execute_sql` query a `information_schema.columns`
   para confirmar shape REAL de `group_resource_series` (drift
   posible).

## Fase 0 — Audit BD-real (15 min, sin commits)

**Propósito**: Antes de tocar nada, confirmar que el schema real
matchea la doctrina. Caso testigo de sesión previa: doc decía cosas
que BD no reflejaba.

**Comandos a ejecutar**:

```sql
-- Q1: shape exacto de group_resource_series
SELECT column_name, data_type, is_nullable
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='group_resource_series'
 ORDER BY ordinal_position;

-- Q2: ¿cuántos rituales hay vivos? Sample data
SELECT id, name, is_ritual, recurrence_cadence, next_at, last_at,
       ended_at, ritual_intent
  FROM public.group_resource_series
 WHERE is_ritual = true
 LIMIT 5;

-- Q3: ¿cómo se modelan las ocurrencias? Subtype event
SELECT column_name FROM information_schema.columns
 WHERE table_schema='public' AND table_name='group_resource_events';

-- Q4: RPCs existentes relacionadas
SELECT proname, pg_get_function_arguments(p.oid) AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public'
   AND (proname ILIKE '%ritual%' OR proname ILIKE '%series%' OR proname ILIKE '%occurrence%')
 ORDER BY proname;

-- Q5: catálogo permisos existentes para rituals
SELECT key FROM public.permissions WHERE key ILIKE '%ritual%';

-- Q6: event_types existentes con prefijo ritual.*
SELECT DISTINCT event_type FROM public.group_events
 WHERE event_type LIKE 'ritual%';

-- Q7: kinds de reputation_event existentes (para saber si 'ritual_held' ya está)
SELECT DISTINCT kind FROM public.group_reputation_events;
```

**Outputs esperados** (capturar literalmente):
- Lista de columnas de `group_resource_series` con tipos.
- N° de rituales vivos en dev DB.
- Si existe `group_resource_events` subtype y su shape.
- Lista de RPCs ya existentes (para NO duplicar).
- Permisos en catálogo (saber si crear `rituals.complete` o reusar).
- Event types y reputation kinds preexistentes.

**Bloqueantes**:
- Si `group_resource_series.is_ritual` no existe → STOP. Sesión
  invalidada hasta que el founder confirme el schema canonical.
- Si `recurrence_cadence` tiene otro nombre (e.g. `cadence`) → no
  asumir, usar el nombre real.
- Si ya existe `group_ritual_occurrences` RPC → leer su body, NO
  duplicar. Slice 1 quizás solo se reduce a `complete_ritual_occurrence`.

## Fase 1 — Backend RPCs (1 commit, ~45 min)

**Goal**: 2 nuevas RPCs + 1 permiso + 1 reputation kind si falta.

### Sub-step 1.1 — Mig `add_rituals_complete_permission_and_kind`

**Solo si Fase 0 confirma que faltan**:

```sql
-- 1. Permission key
INSERT INTO public.permissions (key, category, description)
VALUES ('rituals.complete', 'Rituals',
        'Marcar una ocurrencia de ritual como cumplida')
ON CONFLICT (key) DO NOTHING;

-- 2. Reputation event kind (si manejado por CHECK constraint del kind)
-- Adaptar al modelo real verificado en Fase 0
```

**DoD**: query `SELECT key FROM permissions WHERE key='rituals.complete'`
retorna row. Permission existe y es asignable a roles.

### Sub-step 1.2 — Mig `group_ritual_occurrences_rpc`

```sql
CREATE OR REPLACE FUNCTION public.group_ritual_occurrences(
  p_series_id uuid,
  p_limit int DEFAULT 20,
  p_include_past boolean DEFAULT true
) RETURNS TABLE(
  resource_id uuid,
  occurred_at timestamptz,
  status text,        -- 'upcoming' | 'completed' | 'missed' | 'cancelled'
  attendance_count int,
  intent_snapshot text,
  created_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_group_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'unauthorized' USING errcode='42501'; END IF;
  SELECT group_id INTO v_group_id FROM public.group_resource_series
   WHERE id = p_series_id;
  IF v_group_id IS NULL THEN RAISE EXCEPTION 'series not found'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = v_group_id AND gm.user_id = v_uid AND gm.status = 'active'
  ) THEN RAISE EXCEPTION 'not a member' USING errcode='42501'; END IF;

  -- Implementación depende del schema real verificado en Fase 0.
  -- Plantilla: cada ocurrencia es un row en group_resources
  -- linkado por metadata->>'series_id' o columna source_series_id.
  RETURN QUERY
  SELECT
    gr.id AS resource_id,
    COALESCE((gr.metadata->>'occurred_at')::timestamptz, gr.created_at) AS occurred_at,
    CASE
      WHEN (gr.metadata->>'completed_at') IS NOT NULL THEN 'completed'
      WHEN COALESCE((gr.metadata->>'occurred_at')::timestamptz, gr.created_at) > now() THEN 'upcoming'
      WHEN (gr.metadata->>'cancelled_at') IS NOT NULL THEN 'cancelled'
      ELSE 'missed'
    END AS status,
    COALESCE((SELECT COUNT(*)::int FROM public.group_resource_check_ins ci WHERE ci.resource_id = gr.id), 0) AS attendance_count,
    gr.metadata->>'intent_snapshot' AS intent_snapshot,
    gr.created_at
  FROM public.group_resources gr
  WHERE gr.metadata->>'series_id' = p_series_id::text
    AND (p_include_past OR COALESCE((gr.metadata->>'occurred_at')::timestamptz, gr.created_at) >= now())
  ORDER BY COALESCE((gr.metadata->>'occurred_at')::timestamptz, gr.created_at) DESC
  LIMIT GREATEST(p_limit, 1);
END;
$$;

REVOKE ALL ON FUNCTION public.group_ritual_occurrences(uuid, int, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.group_ritual_occurrences(uuid, int, boolean) TO authenticated;
```

**ADAPTAR** según schema real de Fase 0. Si las ocurrencias usan
otra tabla o columnas (e.g. `source_series_id` directo en lugar de
`metadata->>'series_id'`), ajustar.

**Smoke**: invocar con un series_id real del dev DB; verificar shape
y que el active-member gate rechace caller no-member.

### Sub-step 1.3 — Mig `complete_ritual_occurrence_rpc`

```sql
CREATE OR REPLACE FUNCTION public.complete_ritual_occurrence(
  p_resource_id uuid,
  p_reflection text DEFAULT NULL,
  p_client_id text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_resource public.group_resources%ROWTYPE;
  v_series_id uuid;
  v_actor_m uuid;
  v_event_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'unauthorized' USING errcode='42501'; END IF;
  SELECT * INTO v_resource FROM public.group_resources WHERE id = p_resource_id;
  IF v_resource.id IS NULL THEN RAISE EXCEPTION 'resource not found'; END IF;

  v_actor_m := (SELECT id FROM public.group_memberships
                 WHERE group_id = v_resource.group_id
                   AND user_id = v_uid AND status = 'active');
  IF v_actor_m IS NULL THEN RAISE EXCEPTION 'not a member' USING errcode='42501'; END IF;

  PERFORM public.assert_permission(v_resource.group_id, 'rituals.complete');

  IF (v_resource.metadata->>'completed_at') IS NOT NULL THEN
    RAISE EXCEPTION 'already completed' USING errcode='22023';
  END IF;
  v_series_id := NULLIF(v_resource.metadata->>'series_id','')::uuid;
  IF v_series_id IS NULL THEN RAISE EXCEPTION 'resource is not a ritual occurrence' USING errcode='22023'; END IF;

  UPDATE public.group_resources
     SET metadata = metadata
                  || jsonb_build_object(
                       'completed_at', now()::text,
                       'completed_by', v_actor_m::text,
                       'reflection', COALESCE(p_reflection, ''),
                       'client_id', COALESCE(p_client_id, ''))
   WHERE id = p_resource_id;

  UPDATE public.group_resource_series
     SET last_at = now()
   WHERE id = v_series_id;

  v_event_id := (SELECT rse.uuid_id FROM public.record_system_event(
    v_resource.group_id,
    'ritual.occurrence_completed',
    'resource',
    p_resource_id,
    p_reflection,
    jsonb_build_object(
      'series_id', v_series_id,
      'completed_by_membership', v_actor_m,
      'attendance_count', (SELECT COUNT(*) FROM public.group_resource_check_ins WHERE resource_id = p_resource_id)
    )
  ) rse);

  PERFORM public.evaluate_rules_for_event(v_event_id, 'sync');

  RETURN v_event_id;
END;
$$;
```

**Smoke**:
1. Sin perm → 42501 con mensaje claro.
2. Con perm → emite event + actualiza series + retorna event_uuid.
3. Doble complete → 22023 "already completed".

### Sub-step 1.4 — Disk files

Por cada mig aplicada vía `mcp__supabase__apply_migration`, crear el
file paralelo en `supabase/migrations/<timestamp>_v3_rituals_*.sql`
con el mismo SQL. Asegura que `supabase db reset` futuro lo replique.

### Sub-step 1.5 — Commit Fase 1

`git add supabase/migrations/<new files> && git commit -m "v3-deep: Rituals fase 1 backend RPCs"`

**DoD Fase 1**:
- 2 (o 3) migs aplicadas en BD vía MCP.
- 2 (o 3) disk files en `supabase/migrations/`.
- 3 smokes verdes (occurrences + complete happy path + complete double-fail).
- Commit pushed (preguntar al founder antes).

## Fase 2 — iOS plumbing (1 commit, ~45 min)

**Goal**: Domain + protocol + Supabase impl + mock + repo wrapper para
las 2 nuevas RPCs. Cero UI todavía.

### Sub-step 2.1 — Domain types

Nuevo archivo `Packages/RuulCore/Sources/RuulCore/Domain/GroupRitualOccurrence.swift`:

```swift
public struct GroupRitualOccurrence: Decodable, Sendable, Hashable, Identifiable {
    public var id: UUID { resourceId }
    public let resourceId: UUID
    public let occurredAt: Date
    public let status: Status
    public let attendanceCount: Int
    public let intentSnapshot: String?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case resourceId      = "resource_id"
        case occurredAt      = "occurred_at"
        case status
        case attendanceCount = "attendance_count"
        case intentSnapshot  = "intent_snapshot"
        case createdAt       = "created_at"
    }

    public enum Status: String, Decodable, Sendable, Hashable {
        case upcoming, completed, missed, cancelled
    }
}
```

### Sub-step 2.2 — Params en RPCInputs.swift

```swift
public struct GroupRitualOccurrencesParams: Encodable, Sendable {
    public let pSeriesId: UUID
    public let pLimit: Int
    public let pIncludePast: Bool
    enum CodingKeys: String, CodingKey {
        case pSeriesId    = "p_series_id"
        case pLimit       = "p_limit"
        case pIncludePast = "p_include_past"
    }
}

public struct CompleteRitualOccurrenceParams: Encodable, Sendable {
    public let pResourceId: UUID
    public let pReflection: String?
    public let pClientId: String?
    enum CodingKeys: String, CodingKey {
        case pResourceId = "p_resource_id"
        case pReflection = "p_reflection"
        case pClientId   = "p_client_id"
    }
}
```

### Sub-step 2.3 — Protocol RuulRPCClient

```swift
func groupRitualOccurrences(seriesId: UUID, limit: Int, includePast: Bool) async throws -> [GroupRitualOccurrence]
func completeRitualOccurrence(_ input: CompleteRitualOccurrenceParams) async throws -> UUID
```

### Sub-step 2.4 — SupabaseRuulRPCClient impls

Patrón: `try await client.rpc("group_ritual_occurrences", params: ...).execute().value` y `callReturningUUID("complete_ritual_occurrence", ...)`.

### Sub-step 2.5 — Mock + StaticProfile stubs

Añadir case + stub + setter + method en `MockRuulRPCClient.swift`.
Añadir simple stubs en `ProfilePreviewData.StaticProfileRPCClient`.

### Sub-step 2.6 — Repository wrapper

Expandir o crear `CanonicalRitualsRepository` con:

```swift
public func occurrences(seriesId: UUID, limit: Int = 20, includePast: Bool = true) async throws -> [GroupRitualOccurrence]
public func complete(resourceId: UUID, reflection: String? = nil, clientId: String? = nil) async throws -> UUID
```

Wire en `DependencyContainer`.

### Sub-step 2.7 — Build + commit

`mcp__xcode-tools__BuildProject` → verde antes de commit.

`v3-deep: Rituals fase 2 iOS plumbing`

**DoD Fase 2**:
- Build verde (BuildProject MCP success).
- Cero RPC orphan (todas tienen mock + stub + repo).
- Commit en main.

## Fase 3 — RitualDetailView nueva (1-2 commits, ~90 min)

**Goal**: Crear el detail view con los 6 bloques universales.

### Sub-step 3.1 — Esqueleto del archivo

Nuevo `Packages/RuulApp/Sources/RuulApp/Features/Rituals/RitualDetailView.swift`:

```swift
public struct RitualDetailView: View {
    let container: DependencyContainer
    let groupId: UUID
    let series: GroupResourceSeries

    @State private var occurrences: [GroupRitualOccurrence] = []
    @State private var isLoadingOccurrences: Bool = false
    @State private var callerPermissions: Set<String> = []
    @State private var pendingCompletion: GroupRitualOccurrence?
    @State private var isShowingEdit: Bool = false

    public var body: some View {
        List {
            identitySection
            contextSection
            participationSection
            coordinationSection
            activitySection
            actionsSection
        }
        .navigationTitle(series.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
        .refreshable { await loadAll() }
        // sheets + nav destinations
    }

    // private @ViewBuilder vars por cada bloque
}
```

### Sub-step 3.2 — Bloque 1 Identity

- Hero centrado: ícono del ritual + name + recurrence cadence label
  ("Semanal" / "Mensual" / "Anual").
- `ritual_intent` text bajo el name (italic, secondary).
- Badge "Pausado" si `ended_at IS NOT NULL`.

### Sub-step 3.3 — Bloque 2 Context

- "Próxima ocurrencia: <relative date>" si `next_at != nil`.
- "Última: <relative date>" si `last_at != nil`.
- Stat: "<N> veces cumplido" (count de occurrences con status=completed).

### Sub-step 3.4 — Bloque 3 Participation

- "Has asistido a X/Y ocurrencias" (calcular client-side filtrando
  occurrences por attendance_count > 0 y comparing user). Para Foundation,
  surfaceando solo el count total mientras backend no expone "mi asistencia".
- Si la próxima ocurrencia está dentro de N días → botón RSVP inline.

### Sub-step 3.5 — Bloque 4 Coordination

- **Schedule sub-block**: lista de próximas 3 ocurrencias con check-in
  self inline (botón "Apuntarme").
- **Money sub-block** (opcional, condicional): si el ritual tiene
  metadata `recurring_charge` (slice futuro), mostrar "Cuota recurrente:
  $X — Cobrar próxima cuota" → reuse `IssuePoolChargeSheet` pre-llenado.

### Sub-step 3.6 — Bloque 5 Activity

- Feed de events filtrados por `entity_id = series.id` (RPC ya existe
  `group_events_recent` — filtrar client-side por entity_kind='ritual'
  AND entity_id=series.id).
- Si lista > 8 → "Ver toda la actividad" → push `GroupHistoryView`.

### Sub-step 3.7 — Bloque 6 Actions

Gated por `callerPermissions`:
- **"Marcar última ocurrencia como cumplida"** → presenta sheet con
  reflexión opcional + invoca `completeRitualOccurrence`. Requiere
  `rituals.complete`.
- **"Pausar ritual"** → set `ended_at = now()` via `update_resource_series`.
  Requiere `resources.update`.
- **"Editar"** → presenta `EditRitualSheet`. Requiere `resources.update`.
- **"Compartir intent"** → ShareLink con el ritual_intent text.

### Sub-step 3.8 — Sheet `CompleteRitualOccurrenceSheet`

Nuevo archivo dedicado, simple form: textarea para reflexión opcional +
botón Confirmar.

### Sub-step 3.9 — Build + commit

`v3-deep: Rituals fase 3 RitualDetailView con 6 bloques universales`

**DoD Fase 3**:
- Detail view compila + abre desde RitualsListView.
- Los 6 bloques renderean (incluso si algunos están vacíos).
- Actions section gated por perms.
- Sheet de completion funcional.

## Fase 4 — RitualsListView clustering situacional (1 commit, ~45 min)

**Goal**: Rediseñar la lista con clustering por urgencia + push al
detail.

### Sub-step 4.1 — Compute clusters

Filtrar la lista vía `next_at` en próximos 7 días vs más adelante vs
pausados.

### Sub-step 4.2 — Section per cluster

- **"Esta semana"** — ocurrencias en próximos 7 días.
- **"Próximas"** — más de 7 días.
- **"Pausados"** — `ended_at IS NOT NULL`.
- Empty global → presence card + CTA "Crear ritual".

### Sub-step 4.3 — Wire `.navigationDestination` para push detail

Row tap → push `RitualDetailView`.

### Sub-step 4.4 — Build + commit + push

`v3-deep: Rituals fase 4 list clustering situacional`

**DoD Fase 4**:
- Lista compila + push a detail funcional.
- Empty state visible cuando no hay rituals.
- Cluster headers no aparecen vacíos.

## Fase 5 — Install device + smoke manual (no commit)

1. `xcodebuild -project Tandas.xcodeproj -scheme Tandas -configuration Debug -destination 'platform=iOS,id=E63668BF-3B28-5F51-B678-519B203E48CC' -derivedDataPath /tmp/tandas-device-build build`
2. `xcrun devicectl device install app --device E63668BF-3B28-5F51-B678-519B203E48CC /tmp/tandas-device-build/Build/Products/Debug-iphoneos/Tandas.app`
3. Lanzar app, navegar a Rituales tab.
4. **Smoke manual checklist**:
   - [ ] Crear ritual nuevo → aparece en cluster apropiado.
   - [ ] Tap ritual → push a detail.
   - [ ] Los 6 bloques aparecen (empty vs poblados).
   - [ ] Tap "Marcar última como cumplida" (si caller admin) → sheet
         con reflexión → submit → cierre + refresh → status pasa a
         'completed'.
   - [ ] Activity bloque muestra el event `ritual.occurrence_completed`.
   - [ ] Pausar ritual → moverlo al cluster Pausados.

## Fase 6 (opcional) — Cross-links + reputation polish (1 commit)

- Ritual event en `ReputationFeedView` con icon especial.
- `MemberDetailView.activitySection` ya muestra "X cumplió este ritual"
  por nuestro slice anterior — verificar event_type maps a icono.
- DeepLink: agregar `.ritual(groupId, seriesId)` case + parser.

## Reglas duras de la sesión

1. **Verify-before-implement**: Fase 0 ANTES de Fase 1. Sin excepción.
2. **Una mig por sub-step**. Smoke verde antes de seguir.
3. **Disk files paralelos** a `mcp__supabase__apply_migration` siempre.
4. **Atom guards intactos**: nada de `update group_events` directo —
   pasar por `record_system_event`.
5. **`evaluate_rules_for_event` sync** para `ritual.occurrence_completed`
   (engine debe poder reaccionar).
6. **Permission gating en UI**: Actions section oculta botones cuando
   caller no tiene perm (anti-tap-then-error UX).
7. **Build verde** entre fases. Si rompe, parar y arreglar antes de
   seguir.
8. **Stop-and-report** si:
   - Schema BD-real difiere de la plantilla del plan.
   - RPC ya existe con shape diferente.
   - Permission `rituals.complete` ya está pero asignada a otra
     categoría.
9. **No push a main** sin confirmación founder.
10. **iPhone install al cierre** obligatorio. La sesión no está hecha
    si no se vió en device.

## Risk register

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| `is_ritual` column no existe en schema real | Media | Fase 0 lo verifica antes. Stop si falla. |
| Ocurrencias no son `group_resources` rows | Media | Fase 0 query a `group_resource_events` confirma. Plan B: si subtype event existe, RPC adapta. |
| Permission catalog read-only | Baja | Mig 1.1 usa ON CONFLICT DO NOTHING; si tabla es view, reportar. |
| reputation_event kind 'ritual_held' rechazado | Media | Fase 0 query confirma. Si CHECK constraint estricto, abrir slice paralelo para ALTER. |
| Bug `_assert_mandate_authorizes` sin scope 'rituals' | Baja | record_pool_charge scope='charge'; rituals no usa mandato hoy. Sin impacto. |
| iPhone reindex stale | Alta | Si BuildProject MCP da errors fantasma, retry build. Sesión previa lo confirmó. |

## Smokes mínimos por fase

| Fase | Smoke |
|---|---|
| 1.2 | `SELECT * FROM group_ritual_occurrences(<series_id>)` retorna shape correcto |
| 1.3 happy | `complete_ritual_occurrence(<rid>)` retorna event_uuid + actualiza series.last_at |
| 1.3 perm | Caller sin perm → 42501 "lacks permission rituals.complete" |
| 1.3 double | Segundo complete del mismo resource → 22023 "already completed" |
| 2 | BuildProject success post-plumbing |
| 3 | Detail view abre sin crash + 6 bloques rendereados |
| 4 | List view muestra clusters correctos |
| 5 | Device install + smoke manual completo |

## Output esperado al cierre

- **5-7 commits prefijo `v3-deep: Rituals <fase>`**.
- **2-3 migs aplicadas** + disk files paralelos.
- **2 RPCs nuevas**: `group_ritual_occurrences`, `complete_ritual_occurrence`.
- **1 permiso nuevo** (`rituals.complete`).
- **1 reputation event_type nuevo** (`ritual.occurrence_completed`).
- **1 view nueva**: `RitualDetailView.swift`.
- **2 archivos modificados**: `RitualsListView.swift`, opcional `CompleteRitualOccurrenceSheet.swift`.
- **Domain type nuevo**: `GroupRitualOccurrence`.
- **Build verde 5+ veces** + **install device 2+ veces**.
- **Push a main** solo con OK founder.

## Memorias críticas a cargar al arrancar

- `ruul_universal_detail_layered_doctrine.md` — los 6 bloques
- `ruul_canonical_ux_doctrine.md` — verbos arriba, no fondo
- `doctrine_group_space_situational.md` — empty cluster = invisible
- `feedback_verify_before_implement.md` — Fase 0 sagrada
- `feedback_dont_touch_ruului_base.md` — composición en feature layer
- `feedback_no_paralysis_by_analysis.md` — codear y mostrar diff
- `doctrine_rule_eval_sync_async.md` — `ritual.occurrence_completed`
  debe pasar por `evaluate_rules_for_event` sync

## Pregunta al founder al arrancar la sesión

> "Confirmo el plan Plans/Active/RitualsDeep.md? Empiezo por Fase 0
> (audit BD-real). Cuando termine reporto antes de Fase 1."

Espera respuesta. Si dice "sí" o "haz lo que recomiendes": arrancar
Fase 0 inmediato.
