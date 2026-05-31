# Batch — Resources al máximo (polimorfismo por subtype)

> Plan canónico para llevar la Primitiva 8 (Resources / Property) a su
> máximo nivel siguiendo Universal Detail layered + polimorfismo por
> `resource_type`. **Ejecutable en una sesión nueva**. Cada fase tiene
> Inputs / Outputs / DoD / Smoke explícito.

## TL;DR

ResourceDetailView actual son **184 líneas planas** — renderea igual
un `fund`, un `space`, un `asset` y un `document`. Desperdicia la
riqueza del envelope canonical. Esta sesión añade polimorfismo por
subtype con bloques Coordination específicos + cluster por type en la
lista + cero RPC nuevo (todo lo que se necesita en backend ya existe).

**Ejecutar ANTES de `RitualsDeep.md`**: las ocurrencias de rituales
materializan como `group_resources` rows tipo `event`. Si Resources
no sabe rendear `event` distinto, RitualDetailView arranca sobre mala
foundation.

**Prefijo de commits**: `v3-deep: Resources <fase>`.

## Estado de partida

- Repo `tandas`, branch `main`. Último commit relevante: `0cc3413b`
  (plan Rituals).
- iPhone install pipeline mature: `iPhone de JJ` ID
  `E63668BF-3B28-5F51-B678-519B203E48CC`.
- ResourceDetailView vive en `Features/Resources/`. 5 archivos hoy:
  Create/Detail/Row/List + TransferOwnership.
- `GroupResource` domain type: `resourceType: GroupResourceType` enum
  con `.fund / .space / .asset / .document / .other`. (Doctrine: agregar
  `.event` cuando Rituals materialicen ocurrencias).

**Pre-flight checks**:
1. `git status` clean → si no, parar y reportar.
2. `git log --oneline -3` confirma commits del plan o posterior.
3. `mcp__supabase__list_migrations` confirma 29+ migs.

## Fase 0 — Audit BD-real (15 min, sin commits)

**Propósito**: confirmar subtype-specific tables existentes para diseñar
los Coordination blocks sin inventar APIs.

**Queries obligatorias**:

```sql
-- Q1: Subtype-specific tables canónicas que extienden group_resources
SELECT table_name FROM information_schema.tables
 WHERE table_schema='public'
   AND table_name LIKE 'group_resource_%'
 ORDER BY table_name;

-- Q2: Capabilities cableadas hoy
SELECT capability_key, count(*) FROM public.group_resource_capabilities
 GROUP BY capability_key;

-- Q3: ¿Hay tabla específica para fund balance? ¿Para asset valuations?
-- ¿Para document attachments?
SELECT table_name, column_name FROM information_schema.columns
 WHERE table_schema='public'
   AND table_name IN (
     'group_resource_funds',
     'group_resource_spaces',
     'group_resource_assets',
     'group_resource_documents',
     'group_resource_bookings',
     'group_resource_rsvps',
     'group_resource_check_ins',
     'group_resource_asset_valuations'
   )
 ORDER BY table_name, ordinal_position;

-- Q4: RPCs ya existentes para subtypes
SELECT proname, pg_get_function_arguments(p.oid) AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public'
   AND (proname ILIKE '%resource%'
        OR proname ILIKE '%booking%'
        OR proname ILIKE '%rsvp%'
        OR proname ILIKE '%check_in%'
        OR proname ILIKE '%valuation%')
 ORDER BY proname;

-- Q5: distribución real de subtypes en dev
SELECT resource_type, count(*) FROM public.group_resources
 GROUP BY resource_type ORDER BY count DESC;

-- Q6: ¿Hay ownership history table?
SELECT column_name FROM information_schema.columns
 WHERE table_schema='public' AND table_name='group_resource_ownership_history';
```

**Outputs esperados** (capturar literal):
- Lista de tablas `group_resource_*` extant.
- Capabilities key catalog.
- Per-subtype schema disponible.
- RPCs vivas (especialmente `book_resource`, `cancel_booking`,
  `submit_rsvp`, `submit_check_in`, `record_asset_valuation`,
  `enable_resource_capability`, `disable_resource_capability`).
- Distribución real por subtype.

**Bloqueantes**:
- Si no existe `group_resource_bookings` ni equivalente → Coordination
  block para `space` es read-only. Reportar.
- Si `group_resource_documents` no existe → block para `document` es
  metadata-only (preview placeholder). Reportar.
- Si Q5 muestra 0 resources de algún tipo en dev → fixture necesario
  antes del smoke device. Crear 1 de cada vía CreateResourceView post-Fase 3.

## Fase 1 — iOS Domain: Subtype dispatch helpers (1 commit, ~30 min)

**Goal**: extender `GroupResourceType` con SF Symbol icons, labels,
subtitle por tipo, y helper "qué bloques renderear". Cero backend.

### Sub-step 1.1 — Extender `GroupResourceType`

En `Packages/RuulCore/Sources/RuulCore/Domain/GroupResource.swift`:

```swift
public extension GroupResourceType {
    /// Mapping canónico para el bloque Coordination del Universal
    /// Detail. Define qué surface debe renderearse para este subtype.
    enum CoordinationBlock: String, Sendable {
        case money       // fund
        case schedule    // space, event
        case custody     // asset
        case attachment  // document
        case metadata    // other, fallback
    }

    var coordinationBlock: CoordinationBlock {
        switch self {
        case .fund:     return .money
        case .space:    return .schedule
        case .asset:    return .custody
        case .document: return .attachment
        case .other:    return .metadata
        }
    }

    var systemImageName: String {
        switch self {
        case .fund:     return "banknote.fill"
        case .space:    return "building.2.fill"
        case .asset:    return "shippingbox.fill"
        case .document: return "doc.text.fill"
        case .other:    return "shippingbox"
        }
    }

    var subtitle: LocalizedStringResource {
        // Crear L10n keys nuevos en Localization/L10n.swift
        // L10n.ResourceType.fundSubtitle, .spaceSubtitle, etc.
        switch self {
        case .fund:     return L10n.ResourceType.fundSubtitle
        case .space:    return L10n.ResourceType.spaceSubtitle
        case .asset:    return L10n.ResourceType.assetSubtitle
        case .document: return L10n.ResourceType.documentSubtitle
        case .other:    return L10n.ResourceType.otherSubtitle
        }
    }
}
```

L10n nuevos copy sugerido:
- `fundSubtitle`: "Pool de dinero compartido (cuotas, aportes, multas)"
- `spaceSubtitle`: "Lugar reservable (sala, cancha, sede)"
- `assetSubtitle`: "Objeto con custodio actual"
- `documentSubtitle`: "Documento compartido"
- `otherSubtitle`: "Objeto genérico del grupo"

### Sub-step 1.2 — Build + commit

`v3-deep: Resources fase 1 domain subtype dispatch`

**DoD Fase 1**:
- `coordinationBlock` enum y mapping aterrizado.
- Per-type SF Symbol icon + subtitle.
- BuildProject MCP verde.
- L10n keys nuevos.

## Fase 2 — iOS plumbing per-subtype reads (1 commit, ~45 min)

**Goal**: Cablear las RPCs subtype-specific que Fase 0 confirmó existir.
Cero nueva RPC.

### Sub-step 2.1 — Verificar cuáles ya están en protocol

Buscar en `RuulRPCClient.swift`:
- `bookResource`, `cancelBooking`, `submitRsvp`, `submitCheckIn`,
  `markNoShow`, `recordAssetValuation`, `enableResourceCapability`,
  `disableResourceCapability`.

Si alguna falta → añadir protocol method + Supabase impl + mock stub +
StaticProfile stub + repo wrapper. Patrón usado en sesiones previas
para `recordContribution`, `recordPoolCharge`, `groupPoolBalance`.

### Sub-step 2.2 — Domain types per subtype (nuevos si faltan)

- `GroupResourceBooking` (si Fase 0 confirmó tabla bookings)
- `GroupResourceCheckIn`
- `GroupResourceAssetValuation` (probably already exists)

### Sub-step 2.3 — Add reads if missing

Si Fase 0 reveló que falta read RPC para "próximas bookings de este
space" o "valuation history de este asset", añadir:

```sql
-- Solo SI Fase 0 los marca como missing:
group_resource_bookings_upcoming(p_resource_id uuid, p_limit int)
group_resource_asset_valuations(p_resource_id uuid, p_limit int)
```

Con active-member gate idéntico al patrón usado en
`group_governance_versions`, `group_events_for_member`, etc. Disk
file paralelo.

### Sub-step 2.4 — Repository

Expandir `CanonicalResourcesRepository` o crear sub-repos:
`CanonicalResourceBookingsRepository`, etc.

### Sub-step 2.5 — Build + commit

`v3-deep: Resources fase 2 plumbing per-subtype reads`

**DoD Fase 2**:
- Cero RPC orphan (todas tienen mock + stub + repo).
- BuildProject verde.

## Fase 3 — ResourceDetailView refactor con 6 bloques polimórficos (1-2 commits, ~90 min)

**Goal**: el detail abre y renderea distinto según subtype. Reusa el
patrón Universal Detail layered ya probado en MemberDetailView,
SanctionDetailView, MoneyMovementDetailView.

### Sub-step 3.1 — Estructura nueva del body

```swift
public var body: some View {
    List {
        identitySection
        contextSection
        participationSection
        coordinationSection  // ← polimórfico por subtype
        activitySection
        actionsSection
    }
    .navigationTitle(...)
    // ... existing sheets + confirmation dialogs preserved
}
```

### Sub-step 3.2 — Identity Section (refactor)

Heredar lo que ya hay (avatar/icon centrado, name, type label, status
badge). Añadir `resource.resourceType.subtitle` como segunda línea.

### Sub-step 3.3 — Context Section (nueva)

Por subtype:
- **fund**: "Creado por @nombre el <fecha>" + visibility + ownership
- **space**: similar + horario base si aplica
- **asset**: "Custodia actual: @nombre" + última valuation date
- **document**: "Subido por @nombre el <fecha>" + tamaño/format si en
  metadata
- **other**: solo metadata canónica

### Sub-step 3.4 — Participation Section (nueva)

Por subtype, perspectiva del caller:
- **fund**: "Tu aporte total: $X" (sum de contributions client-side)
- **space**: "Tus próximas reservas (N)" + tap → detalle
- **asset**: "Lo tienes en custodia hace X días" (si caller == owner)
- **document**: "Tu última lectura: <fecha>" (si rastreado)
- **other**: invisible

### Sub-step 3.5 — Coordination Section POLIMÓRFICA (CORE del slice)

Switch por `resource.resourceType.coordinationBlock`:

```swift
@ViewBuilder
private var coordinationSection: some View {
    switch resource.resourceType.coordinationBlock {
    case .money:      fundCoordination
    case .schedule:   spaceCoordination
    case .custody:    assetCoordination
    case .attachment: documentCoordination
    case .metadata:   otherCoordination
    }
}
```

#### `fundCoordination` (fund)
- Balance card del recurso (si Fase 0 reveló read).
- Lista de últimas 3 contribuciones to this resource.
- Acción primaria: "Aportar al fondo" → reuse `ContributeToPoolSheet`
  con `resourceId` pre-llenado.

#### `spaceCoordination` (space)
- Lista de próximas 3 bookings.
- Acción: "Reservar este espacio" → presenta BookResourceSheet (nuevo
  o reusable de un Sheet existente).

#### `assetCoordination` (asset)
- Owner actual + history breve (últimas 3 transferencias).
- Valuation actual + historial.
- Acción: "Transferir custodia" → reuse `TransferOwnershipSheet`
  (ya existe).
- Acción: "Registrar valuación" si permission.

#### `documentCoordination` (document)
- Preview o link a metadata download URL (si metadata.url).
- Version history si metadata.versions[] existe.
- Acción: "Compartir" via ShareLink.

#### `otherCoordination`
- Tabla genérica de metadata jsonb (key/value rows).

### Sub-step 3.6 — Activity Section (nueva)

Filter `group_events_recent` por `entity_id = resource.id`. Reuse el
mismo client-side filter pattern ya usado en MemberDetailView slice
B-1.

### Sub-step 3.7 — Actions Section (refactor)

Heredar Archive + Transfer existentes. Gated por perm:
- `resources.archive` → "Archivar"
- `resources.transfer` → "Transferir custodia" (asset only)
- `resources.edit` → "Editar metadata"
- Subtype-specific actions movieron al Coordination block.

### Sub-step 3.8 — Sheet nuevo (si Fase 0 lo dijo)

Si Fase 0 confirmó `book_resource` exists, crear
`BookResourceSheet.swift` con fecha picker + duración + propósito.

### Sub-step 3.9 — Build + commit + install

`v3-deep: Resources fase 3 detail view polimórfico por subtype`

**DoD Fase 3**:
- Detail view compila y abre desde ResourcesListView.
- Los 6 bloques rendereen (algunos vacíos).
- Coordination block dispatcha correcto por subtype.
- Build verde.
- Install device exitoso.

## Fase 4 — ResourcesListView clustering por type (1 commit, ~30 min)

**Goal**: Lista con clustering situacional por subtype + chip filter.

### Sub-step 4.1 — Cluster Sections

- **"Fondos"** (fund)
- **"Espacios"** (space)
- **"Objetos"** (asset)
- **"Documentos"** (document)
- **"Otros"** (other)
- **"Archivados"** (cualquier subtype con `archived_at != nil`)

Cluster invisible cuando vacío (situational doctrine).

### Sub-step 4.2 — Chip row filter (opcional, si quedó tiempo)

Horizontal scroll arriba de la lista con chips "Todo / Fondos /
Espacios / Objetos / Documentos / Otros / Archivados". Mismo patrón
visual que MoneyDashboardView.quickActionsRow.

### Sub-step 4.3 — Build + commit + push

`v3-deep: Resources fase 4 list clustering por type`

**DoD Fase 4**:
- Lista muestra clusters correctos según subtype.
- Empty state global cuando 0 resources totales.
- Chip filter opcional funciona (si se shipped).

## Fase 5 — Install device + smoke manual (no commit)

1. Build for-device + install via `xcrun devicectl`.
2. Lanzar app, navegar a Recursos.
3. **Smoke manual checklist**:
   - [ ] Lista muestra clusters por type.
   - [ ] Crear 1 resource de cada subtype (fund, space, asset,
         document, other) si Fase 0 reveló 0 en dev.
   - [ ] Tap cada subtype → verifica que Coordination block
         renderea distinto.
   - [ ] Fund: tap "Aportar" → presenta ContributeToPoolSheet con
         `resourceId` pre-llenado.
   - [ ] Asset: tap "Transferir custodia" → TransferOwnershipSheet
         existing flow.
   - [ ] Archive → row desaparece o pasa a cluster Archivados.

## Fase 6 (opcional) — Cross-links + polish

- Money tab → DebtsListView pool obligation referencia → tap → push
  ResourceDetailView del fund correspondiente.
- Decision → reference `resource_change` → push ResourceDetailView.
- MemberDetailView coordination Money block → tap "Sus aportes a
  este fondo" cuando aplica.

## Reglas duras

1. **Verify-before-implement**: Fase 0 obligatoria antes de Fase 1.
2. **Cero RPC orphan**: cada nueva RPC tiene caller iOS en el mismo
   slice.
3. **Disk files paralelos** a `mcp__supabase__apply_migration` si
   añades RPCs (Fase 2 sub-step 2.3).
4. **Reuse de sheets existentes**: `ContributeToPoolSheet`,
   `TransferOwnershipSheet`, `IssuePoolChargeSheet` ya existen.
   Pre-llenarlos en lugar de crear duplicados.
5. **Permission gating en UI**: cada Action button oculto cuando
   `callerPermissions` no contiene la key respectiva. Reusa pattern
   de MemberDetailView.QuickActionStores.
6. **Build verde** entre fases. Si rompe, parar.
7. **Stop-and-report** si:
   - Tabla subtype-specific tiene shape inesperado.
   - RPC `book_resource` no acepta el shape que necesita
     `BookResourceSheet`.
   - L10n.ResourceType.* keys colisionan con existentes.
8. **iPhone install al cierre** obligatorio.
9. **No push a main** sin confirmación founder.
10. **No tocar RuulUI base** — componer en feature layer.

## Risk register

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| Subtype-specific tables incompletas (e.g. group_resource_documents no existe) | Media | Fase 0 confirma. Plan B: documento queda metadata-only en Coordination. |
| `book_resource` RPC ya existe pero con shape distinto del plan | Alta | Fase 0 query a `pg_proc` lo confirma. Adapta `BookResourceSheet` al shape real. |
| Resource `event` subtype no existe en enum | Alta | Hoy NO está; agregar `.event` case rompe exhaustiveness en switch existentes. Slice futuro para Rituals. Por ahora, switch usa default fallback. |
| Capabilities catalog cambia el control de qué acciones rendear | Media | `group_resource_capabilities` con `capability_key` y `enabled`. Renderear actions sólo cuando capability enabled. |
| iPhone reindex stale | Alta | Pattern sesión previa: retry BuildProject 2x. |

## Smokes mínimos por fase

| Fase | Smoke |
|---|---|
| 1 | Build verde, GroupResourceType.coordinationBlock retorna case correcto per type |
| 2 | RPC nueva responde shape esperado (si Fase 2.3 agrega RPCs) |
| 3 | Detail abre + Coordination renderea sub-block correcto vía switch |
| 4 | List muestra clusters esperados, empty cluster invisible |
| 5 | Device install + manual checklist |

## Cross-link con RitualsDeep.md

> **Importante**: si esta sesión cierra antes de Rituals, agregar en
> el commit final una línea a `Plans/Active/RitualsDeep.md` Fase 0
> nota: *"ResourceDetailView ya polimórfico; Rituals reusa
> coordinationBlock=.schedule cuando el resource_type es event"*.
>
> Si esta sesión NO se ejecuta antes de Rituals, RitualsDeep va a
> tener que añadir `event` case y hacer su propio block manual. Más
> trabajo, pero no bloqueante.

## Output esperado al cierre

- **4-5 commits prefijo `v3-deep: Resources <fase>`**.
- **0-2 migs aplicadas** (depende de Fase 0; mayoría de RPCs ya
  existen).
- **5 Coordination sub-blocks polimórficos** (money/schedule/custody/
  attachment/metadata).
- **Cluster por type** en ResourcesListView.
- **L10n keys nuevos** para subtitles per type.
- **0-2 sheets nuevos** (BookResourceSheet opcional).
- **Build verde 4+ veces** + install device 1-2 veces.
- **Cross-link nota** en RitualsDeep.md.
- **Push a main** sólo con OK founder.

## Memorias críticas a cargar

- `ruul_universal_detail_layered_doctrine.md` — los 6 bloques
- `ruul_canonical_ux_doctrine.md` — verbos arriba
- `doctrine_group_space_situational.md` — empty cluster = invisible
- `doctrine_shared_money.md` — fund subtype connecta a pool concept
- `feedback_verify_before_implement.md` — Fase 0 sagrada
- `feedback_dont_touch_ruului_base.md` — componer en feature layer

## Pregunta al founder al arrancar

> "Confirmo plan Plans/Active/ResourcesPolish.md? Empiezo por Fase 0
> (audit BD-real, 15min). Reporto antes de Fase 1. ¿Quieres que
> después de cerrar Resources arranque RitualsDeep.md o lo dejo para
> otra sesión?"

Si dice "haz lo que recomiendes" → arrancar Fase 0 inmediato.
Recomendación post-Resources: pause + report, no encadenar sesiones
sin checkpoint founder.
