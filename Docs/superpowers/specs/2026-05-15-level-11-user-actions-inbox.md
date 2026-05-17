# Nivel 11 — Atom-ish: `user_actions` inbox UX

**Fecha:** 2026-05-15
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Jerarquía:** `HierarchyReference.md` §1 (Layer 11 — Atom-ish)
**Migraciones base:** `00014` (user_actions schema), `00016/00029/00077/00133/00142/00143/00145` (triggers crean acciones), `00043/00044` (auto-resolvers), `00166` (atom-ish guard: resolved_at one-way)

## Problema

Nivel 11 vive en `user_actions` — proyección terminal mutable one-way (resolved_at: null→ts). BE maduro:
- 8 action_type seedeados (`finePending`, `fineVoided`, `appealVotePending`, `rsvpPending`, `fineProposalReview`, `ruleChangeApplyPending`, `hostAssigned`, `votePending`).
- 5+ triggers que crean acciones automáticamente.
- 5 auto-resolvers (vote cast, fine paid, fine voided, rule applied, vote closed).
- Atom-ish guard (mig 00166): UPDATE solo `resolved_at: null→ts`, DELETE rechazado.

FE: `InboxView` + `ActionInboxView` + `InboxCoordinator` + `UserActionRepository`. Renderiza con 8 chips de categoría. Tap → dispatch a destino correspondiente. Tab badge cuenta pendientes.

**Gaps user-facing:**

1. **No hay historial de acciones resueltas.** Una vez resuelta, una acción **desaparece para siempre del FE**. Usuario que pagó 30 multas no tiene forma de ver el historial.

2. **No swipe-to-resolve.** Solo button/tap → abre detail. Quick-resolve sin abrir destino = imposible. Friction alta para acciones repetitivas.

3. **No bulk-resolve.** "Tengo 15 recordatorios y los quiero limpiar de un golpe" requiere 15 taps + 15 navegaciones.

4. **No undo después de resolve.** Tap (= "abrir") dispara `analytics.inbox_action_resolved` y la acción desaparece. Si el tap fue accidental, no hay vuelta atrás.

5. **`hostAssigned` no tiene auto-resolver.** Vive en el inbox indefinidamente hasta que el usuario lo abre (event detail), pero no hay confirmación de "ya vi".

6. **`InboxCoordinator.resolve` fires analytics on TAP, not on actual resolution.** Conceptualmente errado: abrir != hacer. Acción dispatch antes que el flow downstream complete.

7. **No snooze** — diferir una acción 24h/7d/personalizada. Columna `snoozed_until` NO existe en BE — requeriría mig.

8. **`Solicitudes` chip** UI placeholder — el tipo `swap_request` no existe en el enum BE todavía.

## Objetivo

Cerrar los 2 gaps más visibles para Beta:

- **Historial de resueltas** — chip "Resueltas" en InboxView + repo method `resolved(userId:limit:)` + render greyed con resolved-timestamp.
- **Swipe-to-resolve + bulk-resolve** — gesture rápido para quick-resolve sin abrir destino + botón "Marcar todas" con confirmation + undo toast 5s.

Pass 3+ (out of scope aquí): snooze (requiere mig), auto-resolver para `hostAssigned`, fix analytics-on-tap vs analytics-on-action, Solicitudes chip.

## Approach — 3 pasadas, Pass 1+2 en este plan

### Pass 1 · Resolved history (3 tasks)

| Archivo | Acción |
|---|---|
| `RuulCore/Repositories/UserActionRepository.swift` | Modify. Agregar `func resolved(userId:, limit: Int = 50) async throws -> [UserAction]` al protocol + Live + Mock. Live: `from("user_actions").select().eq("user_id", uid).not("resolved_at", .is, AnyJSON.string("null")).order("resolved_at", ascending: false).limit(limit)`. |
| `Features/Inbox/Views/InboxView.swift` | Modify. Add `.resueltas` case to `InboxChip` enum + filter logic. When chip = resueltas, render resolved list instead of pending. |
| `Features/Inbox/Views/ActionInboxView.swift` (o `FilteredInboxList`) | Modify. Resolved actions render with `.opacity(0.6)`, sin chevron (no nav target — pure history), trailing label "Resuelta hace X" via RelativeDateTimeFormatter. |

### Pass 2 · Swipe + bulk + undo (3 tasks)

| Archivo | Acción |
|---|---|
| `RuulUI/Primitives/ActionCard.swift` o wrapper | Modify. Wrap with `.swipeActions(edge: .trailing) { Button("Hecho") { Task { await onResolve?() } } .tint(.green) }`. Param nuevo `onResolve: (() -> Void)?`. |
| `Features/Inbox/Coordinator/InboxCoordinator.swift` | Modify. Agregar `resolveAll() async throws` (loop sobre actions pendientes + repo.resolve per id) + `revertLastBulk()` placeholder (V1 no real undo — guarda IDs, re-fetch + delete `resolved_at` no se puede por atom-ish guard; V1 toast solo dice "5 acciones resueltas" sin botón undo). |
| `Features/Inbox/Views/InboxView.swift` | Modify. Toolbar item "Marcar todas" (visible si pending.count > 1) + confirmation alert + toast no-undo "X acciones resueltas". |

### Pass 3 (deferred): snooze (mig + UI), hostAssigned auto-resolver, analytics fix, Solicitudes chip

## Wireframe `InboxView` con chip Resueltas + swipe

```
┌─────────────────────────────────────────┐
│  Bandeja                  Marcar todas │
│  ─────────────────────────────────────  │
│  [Todos] [Urgente] [Aprobaciones] ...   │
│  [Pagos] [Recordatorios] [Resueltas]    │  ← NUEVO chip
│  ─────────────────────────────────────  │
│                                          │
│  ⚠️ Multa de $500                       │
│  Por llegar tarde a cena de jueves   →  │
│  ────────────────────────────────────   │
│  ✓  RSVP                                │  ← swipe-right "Hecho"
│  Confirma tu asistencia              →  │
│  ────────────────────────────────────   │
│  ...                                     │
└─────────────────────────────────────────┘

Resueltas chip view:
┌─────────────────────────────────────────┐
│  ⚠️ Multa de $500                       │  ← opacity 0.6
│  Resuelta hace 3 días                    │
│  ────────────────────────────────────   │
│  ✓  RSVP                                │
│  Resuelta hace 5 días                    │
│  ...                                     │
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **No-undo en bulk-resolve V1.** El atom-ish guard (mig 00166) impide re-abrir resolved actions. Para implementar undo real necesitaríamos columna `unresolved_at` o nueva tabla `unresolve_log` — overkill V1. Toast informativo sin botón undo.

2. **Resolved chip muestra últimas 50** sin paginación. Si demanda crece → infinite scroll Pass 3.

3. **Swipe-to-resolve no abre el destino.** Si el usuario quiere revisar antes, tap normal (abre destino + auto-resolve downstream). Swipe = "ya está, no me lo muestres más".

4. **Bulk-resolve aplica a chip actual.** "Marcar todas" en chip Urgente = resuelve TODAS las urgentes pendientes, no todas las acciones del inbox. Más predecible.

5. **`hostAssigned` sin auto-resolver queda en Pass 3.** Workaround V1: usuario lo abre (tap) → InboxCoordinator.resolve dispara → desaparece.

6. **Analytics fix se difiere a Pass 3.** No es un bug bloqueante, solo signal noise.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Swipe + tap pueden conflictar gesture | iOS SwiftUI maneja bien `.swipeActions` con button taps; testear in-sim |
| Bulk resolve de N acciones puede ser lento sin batched RPC | V1: secuencial. Si N>10 → loading state. Pass 3 podría agregar `bulk_resolve_user_actions(ids[])` RPC |
| Resolved list crece sin límite | Limit 50 V1. RLS ya filtra por user_id |
| Atom-ish guard rejects re-open (intencional) | Documentar en docstring que undo no es posible |
| Resolved actions sin destination útil al tap | Resolved chip suprime chevron + tap no hace nada (pure history) |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `UserActionRepository.resolved`: returns latest 50 resolved. `InboxView` chip=resueltas: muestra opacity-reduced rows con "Resuelta hace X". |
| 2 | Swipe gesture: "Hecho" button visible + resuelve correctamente. `resolveAll`: pasa de N→0 pending. Toast aparece + desaparece tras 5s. |

## Out of scope

- Pass 3: snooze (mig + UI), hostAssigned auto-resolver, analytics fix, Solicitudes chip
- True undo (requiere schema change)
- Paginación de resolved history
- Filtros temporales en resolved (última semana / mes / año)
- Per-action notes ("dejé esto sin hacer porque X")
- Push notification cuando llega nueva acción urgente (parte de L15)
- Cross-device sync realtime (parte de L0 future)
- Bulk-snooze
- Custom sort (priority vs date vs type)

## Done When

- 6 tasks committed (3 Pass 1 + 3 Pass 2).
- "Resueltas" chip visible en InboxView, renderiza historial con opacity.
- Swipe-right "Hecho" funciona en cada ActionCard.
- "Marcar todas" toolbar funciona + toast feedback.
- Build clean.
- Two tags: `level11-pass1-complete`, `level11-pass2-complete`.

## Cobertura del plan inicial

**Pass 1 + Pass 2 en el primer commit** (~6 tasks, cero migraciones).
