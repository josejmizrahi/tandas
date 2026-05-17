# Nivel 12 — Projections: GroupHome dashboard + workflow shortcuts

**Fecha:** 2026-05-16
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Jerarquía:** `HierarchyReference.md` §1 (Layer 12 — Projection/View)
**Migraciones base:** `00020` (vote_counts_view), `00136`/`00202` (balance_views), `00149`/`00227` (fines_view), `00152`/`00156` (events_view), `00154` (attendance_view), `00224` (my_activity_v1), `00198` (right_holders_view), `00212` (asset projections)

## Problema

Nivel 12 (Projections) tiene **rica capa BE** — 10+ vistas computadas (balance × 3 scopes, attendance, vote_counts, fines, events, my_activity, right_holders, asset × 4). El FE las consume **puntualmente en surfaces específicas**:

- `MoneySectionView` → balance per resource (top-3)
- `MyLedgerView` → cross-group balance hero
- `RSVPSectionView` → attendance per event
- `VoteCountsBar` → vote_counts en detail
- `MyFinesView` → fines per user
- `MyTimelineView` → my_activity (recién shipped L10)

**Pero hay gaps notables de "vista panorámica":**

1. **No hay "dashboard del grupo"** — para entender el estado del grupo de un vistazo, el usuario tiene que navegar 5 surfaces distintas (GroupHome → Money tab → Inbox → Votes → Members). Una sección "Resumen" en GroupHomeView con stats agregados no existe.

2. **No hay summary per-resource en HomeView feed** — `upcomingFeedSection` muestra titulo + fecha pero no "5/12 confirmados", "$300 recolectado", "2 reglas pendientes". El usuario tiene que tap-y-entrar a cada uno para saber su estado.

3. **No hay "votos abiertos" surface en GroupHome** — OpenVotesView vive solo en su propio destino; el usuario no sabe cuántos votos hay activos sin navegar.

4. **Per-group fine summary missing** — "5 multas pendientes, $1,500 outstanding en este grupo" no se muestra en ningún lado. MyFinesView es cross-grupo.

5. **Group health metrics** — member count, recent activity count, "última actividad hace X" no expuestos como widget.

## Objetivo

Cerrar el gap más visible: **dashboard de grupo** en `GroupHomeView`. Una nueva sección "Resumen" con 4 stat tiles + accesos directos a Inbox/Votos del grupo.

Pass 3+ (out of scope): per-resource summary inline en HomeView feed (requiere repo cache strategy), realtime updates, group health analytics histórico.

## Approach — 3 pasadas, Pass 1+2 en este plan

### Pass 1 · `GroupSummaryRepository` + dashboard data (3 tasks)

| Archivo | Acción |
|---|---|
| `RuulCore/Repositories/GroupSummaryRepository.swift` | **NEW** (~150 L). Protocol + Live + Mock. Método único `summary(groupId:userId:) async throws -> GroupSummary`. Internamente hace ~4 queries en paralelo (members count, upcoming events count via resources, member balance, pending fines count + sum). |
| `RuulCore/PlatformModels/GroupSummary.swift` | **NEW** (~60 L). Struct: `memberCount`, `upcomingEventsCount`, `myBalanceCents: Int`, `myBalanceCurrency: String`, `pendingFinesCount`, `pendingFinesOutstandingCents: Int`, `openVotesCount`, `pendingActionsCount`. All `Sendable + Hashable`. |
| `RuulCore/AppState.swift` | **Modify**. Add `groupSummaryRepo: any GroupSummaryRepository` (optional post-init setter, mismo patrón que `myActivityRepo`). |

### Pass 2 · `GroupHomeView` summary section + workflow shortcuts (3 tasks)

| Archivo | Acción |
|---|---|
| `Features/Group/GroupHomeCoordinator.swift` | **Modify**. Add `summary: GroupSummary?` + `loadSummary()` async method (called from `refresh()`). |
| `Features/Group/Views/GroupHomeView.swift` | **Modify**. New `summarySection` (4 stat tiles) entre `hero` y `configurationSection`. Tiles: "Miembros" / "Próximos eventos" / "Mi balance" / "Multas pendientes". Tap en cada uno navega al destino correspondiente (Miembros = navrow comunidad, Próximos = HomeView, Balance = MyLedgerView, Multas = MyFinesView). |
| `Features/Group/Views/GroupHomeView.swift` | **Modify** (mismo file). New `workflowShortcuts` rows en COMUNIDAD: "X votos abiertos → OpenVotesView", "Y acciones pendientes → InboxView". Solo visibles si count > 0. |

### Pass 3 (deferred): per-resource summary inline, realtime sync, group analytics histórico

## Wireframe `GroupHomeView` con Resumen + workflow

```
┌─────────────────────────────────────────┐
│  ╭────────╮                              │
│  │ AVATAR │  Cenas con amigos            │
│  ╰────────╯  8 miembros                  │
│              🔗 K3X9-Q2VB  [Compartir]  │
│  ─────────────────────────────────────  │
│  ┌────────┬────────┬────────┬────────┐  │  ← NEW Pass 1+2
│  │   8    │   3    │ +$200  │  $500  │  │
│  │MIEMBROS│PRÓXIMOS│ BALANCE│ MULTAS │  │
│  └────────┴────────┴────────┴────────┘  │
│  ─────────────────────────────────────  │
│  CONFIGURACIÓN                           │
│  ...                                     │
│  COMUNIDAD                               │
│  👥 Miembros                        8 → │
│  📅 Actividad del grupo              →  │
│  🗳️ 2 votos abiertos                →  │  ← NEW Pass 2
│  📥 4 acciones pendientes            →  │  ← NEW Pass 2
│  ─────────────────────────────────────  │
│  AVANZADO                                │
│  ...                                     │
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **Stat tiles muestran 4 datos clave**. Más sería ruido. Selection criteria: lo que el usuario revisa al abrir el grupo.

2. **Tap en stat tile navega al destino correspondiente.** Stat es teaser; el detalle vive en su surface dedicada.

3. **Workflow shortcuts solo visibles cuando count > 0.** Cero ruido visual cuando no hay acciones pendientes.

4. **Per-resource summary se difiere.** Requiere repo cache strategy (cada card en HomeView haría N+1 queries sin cache) — su propio spec con materialized views o cliente-side cache.

5. **`GroupSummary` es struct simple (no class).** Cacheable, sendable, easy mock.

6. **`loadSummary()` no bloquea hero.** `refresh()` lanza `async let` para detail + summary en paralelo; hero renderiza primero, stat tiles tienen su propio loading state.

7. **`openVotesCount` y `pendingActionsCount` se calculan client-side** desde los repos existentes (`voteRepo.openVotes(groupId:).count`, `userActionRepo.pending(userId:groupId:).count`) — no requieren BE view nueva.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| 4 queries paralelas pueden ser lentas | TaskGroup en repository; cada query independiente; <500ms total esperado |
| `myBalance` requiere `balanceRepo.balancesForGroup(group.id)` filtrado por user | Reusar mismo repo de MoneySectionView; group-level scope |
| `openVotesCount` y `pendingActionsCount` duplican queries que otros surfaces ya hacen | Aceptable V1; future: AppState-level cache or realtime sync |
| Stat tiles overflow en pantallas pequeñas (iPhone SE) | HStack adaptable + `.minimumScaleFactor(0.7)` |
| Si user no pertenece al grupo (admin viewing como no-member) summary podría fallar | RLS filtra; queries devuelven vacío |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `GroupSummaryRepository.summary`: returns valid struct con todos los counts. Mock returns deterministic seed |
| 2 | `GroupHomeCoordinator.summary`: populates after refresh. `GroupHomeView`: stat tiles render con loading state inicial + workflow shortcuts hide cuando count=0 |

## Out of scope (futuros specs)

- Per-resource summary inline en HomeView feed (necesita cache strategy)
- Realtime updates de summary (websocket subscriptions)
- Group analytics histórico (charts, trends)
- Cross-group dashboard "todos mis grupos at-a-glance"
- Export summary as PDF/CSV
- Notificación cuando algún metric cambia significativamente
- Stat tiles personalizables por usuario

## Done When

- 6 tasks committed (3 Pass 1 + 3 Pass 2).
- GroupHomeView muestra summarySection con 4 stat tiles funcionales.
- Workflow shortcuts ("X votos", "Y acciones") visibles cuando aplica.
- Build clean.
- Two tags: `level12-pass1-complete`, `level12-pass2-complete`.

## Cobertura del plan inicial

**Pass 1 + Pass 2 en el primer commit** (~6 tasks, cero migraciones — usa views existentes).
