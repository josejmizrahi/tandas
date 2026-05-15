# Nivel 9 — Workflow / Votes: gaps + flow completion

**Fecha:** 2026-05-15
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Jerarquía:** `HierarchyReference.md` §1 (Layer 9 — Workflow)
**Migraciones base:** `00020` (votes/vote_casts core), `00023` (quorum_min_absolute), `00052` (start_fine_appeal helper), `00089` (apply_pending_change), `00116` (vote_type whitelist), `00123` (appeal side-effects), `00163` (vote_casts atom-only), `00194` (ledger_review), `00195` (ledger reversal on fail)
**Specs hermanos:** L0-L5, L8 todos shipped.

## Problema

Nivel 9 es donde la governance del L8 cobra vida — los `votes` materializan los cambios `vote_required` por policy. El BE es muy maduro:

- 9 `vote_type` registrados (`fine_appeal`, `rule_change`, `rule_repeal`, `member_removal`, `fund_withdrawal`, `role_assignment`, `general_proposal`, `slot_dispute`, `ledger_review`).
- `vote_casts` atom-only post-mig 00163 (latest per `(vote, member)` wins).
- `start_vote` / `cast_vote` / `finalize_vote` RPCs robustos.
- `start_fine_appeal` helper (mig 00052).
- `apply_pending_change` trigger sobre rule_change pass (mig 00089).
- Reimbursement automático en ledger_review fail (mig 00195).

El FE expone solo **2 de 9 vote types** plenamente (`general_proposal` + `rule_change`). Los otros 5 (`rule_repeal`, `member_removal`, `fund_withdrawal`, `role_assignment`, `slot_dispute`) están disabled en `CreateVoteSheet`. Además:

1. **`member_removal` enabled en CreateVoteSheet pero sin flow de creación** ni body type-specific en `VoteDetailView`. Si el admin la inicia desde otro lado (e.g., `MembersAdminView`), no hay vista que la presente correctamente.

2. **No hay "cancelar voto"** UI. El creator que se arrepiente del voto que abrió debe esperar al deadline o que pase/falle. BE no tiene `cancel_vote` RPC tampoco — gap conjunto BE+FE.

3. **No hay "finalizar manualmente"** para admins cuando el deadline pasó sin cron. Per BE map: "votes don't auto-close at closes_at; requires Edge Function or manual finalize_vote call". El FE tampoco expone botón manual.

4. **No hay ExpiredVotesSection** en `OpenVotesListView`. Votos cuyo `closes_at` ya pasó pero `status='open'` siguen apareciendo en "Pendientes" sin distinción visual.

5. **`rule_repeal`, `fund_withdrawal`, `role_assignment`, `slot_dispute`** son placeholders BE — entran en este spec como out-of-scope hasta que tengan side-effects.

## Objetivo

Cerrar los 3 gaps más visibles:

- **Member removal flow completo** — entry point desde `MembersAdminView` ("Proponer remoción") → `CreateMemberRemovalVoteSheet` → `start_vote(vote_type=member_removal)` → `MemberRemovalVoteBody` en detail.
- **Manual finalize button** — admin ve "Finalizar voto" cuando `closes_at` ya pasó y status sigue 'open'. Llama `finalize_vote` RPC.
- **Cancel vote** — BE: nueva RPC `cancel_vote(vote_id)` con guard creator-only + no_casts_yet + status=open. FE: botón "Cancelar voto" en `VoteDetailView` para creator.

Pass 3+ (out of scope aquí): trigger side-effect `apply_member_removal_on_pass`, auto-finalize cron (edge function), `rule_repeal` / `fund_withdrawal` / `role_assignment` UI.

## Approach — 3 pasadas, Pass 1+2 en este plan

### Pass 1 · Member removal flow (4 tasks)

| Archivo | Acción |
|---|---|
| `Features/Votes/Bodies/MemberRemovalVoteBody.swift` | **NEW** (~120 L). Lee `payload.target_member_id` + `payload.reason`. Muestra avatar+name del target + reason card. Tono destructivo (color ruulNegative en header chip). |
| `Features/Votes/CreateMemberRemovalSheet.swift` | **NEW** (~180 L). Picker `Member` activos del grupo (excluye self), TextField razón min 30 chars, duración 1-168h, submit → `voteRepo.startVote(vote_type: .memberRemoval, referenceId: member.userId, payload: {target_member_id, reason})`. |
| `Features/Votes/CreateVoteSheet.swift` | **Modify**. Habilitar `memberRemoval` card (actualmente disabled). Tap → presenta `CreateMemberRemovalSheet`. |
| `Features/Members/Views/MembersAdminView.swift` | **Modify**. Swipe action "Proponer remoción" admin-only (alternativa al "Echar" directo) → presenta `CreateMemberRemovalSheet` preLlenado con `target: member`. |

**Note**: el BE map dice "no trigger to flip group_members.active=false on finalize_vote pass". Esto significa que al pasar el voto, el admin verá `voteResolved` + tendrá que ir manualmente a "Echar" — el sistema NO ejecuta el removal automáticamente. Documentamos esto como warning UI: "Si pasa el voto, el admin deberá ejecutar la remoción manualmente". Pass 3+ agrega el trigger.

### Pass 2 · Manual finalize + cancel vote (3 tasks)

| Archivo | Acción |
|---|---|
| `supabase/migrations/00207_cancel_vote.sql` | **NEW**. RPC `cancel_vote(p_vote_id)` con guards: caller is creator, status='open', `(SELECT count(*) FROM vote_casts WHERE vote_id=p_vote_id AND choice != 'pending') == 0`. UPDATE votes SET status='cancelled', resolved_at=now(). Emite `voteResolved` con resolution=cancelled. |
| `Repositories/VoteRepository.swift` | **Modify**. Agregar `cancelVote(_ voteId: UUID) async throws` en protocol + Live + Mock. |
| `Features/Votes/VoteDetailView.swift` (o VoteDetailCoordinator) | **Modify**. Dos botones nuevos al final de la `body` (cuando aplica): "Finalizar voto" (admin-only, `closes_at < now()`, status=open) + "Cancelar voto" (creator-only, no votes cast, status=open). Ambos con confirmation alert. |

### Pass 3 (deferred) — trigger member_removal side-effect + auto-finalize cron

## Wireframe `CreateMemberRemovalSheet`

```
┌─────────────────────────────────────────┐
│  Cancelar    Proponer remoción    [···]│
│  ─────────────────────────────────────  │
│                                          │
│  ¿A quién?                               │
│  ┌─────────────────────────────────┐    │
│  │  Carla R.                    ▼ │    │
│  └─────────────────────────────────┘    │
│                                          │
│  Razón                                   │
│  ┌─────────────────────────────────┐    │
│  │ No participa hace 3 meses, no   │    │
│  │ contesta mensajes…              │    │
│  └─────────────────────────────────┘    │
│  30 caracteres mínimo                    │
│                                          │
│  Duración del voto                       │
│  ◉ 48h    ○ 72h    ○ 1 semana            │
│                                          │
│  ⚠️ Si pasa el voto, el admin deberá    │
│  ejecutar la remoción manualmente.       │
│                                          │
│                          [Iniciar voto]  │
└─────────────────────────────────────────┘
```

## Wireframe `VoteDetailView` con manual finalize + cancel

```
┌─────────────────────────────────────────┐
│  ⟵     Proponer remoción de Carla    ⋯ │
│  ─────────────────────────────────────  │
│   Estado: ABIERTO · Cierra hace 2h  ⚠️  │
│  ─────────────────────────────────────  │
│  [target avatar + name + reason card]   │
│                                          │
│  Tally:                                  │
│  A favor    ████████░░  4               │
│  En contra  ███░░░░░░░  2               │
│  Pendientes ██░░░░░░░░  3               │
│                                          │
│  [VoteCastButtons or AlreadyCast]        │
│                                          │
│  ⚠️ Acciones de admin:                  │
│  ┌─────────────────────────────────┐    │
│  │ Finalizar voto ahora           │    │
│  └─────────────────────────────────┘    │
│  ┌─────────────────────────────────┐    │
│  │ Cancelar voto (creador)        │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **Member removal vote NO ejecuta el removal automáticamente.** Pass 1 ships un voto que, al pasar, deja al admin con la tarea de ejecutar el "Echar" desde MembersAdminView. El trigger DB que automatiza esto es Pass 3.

2. **Cancel vote restringido**: solo creator, solo cuando NO hay vote_casts no-pending. Una vez alguien votó, el voto debe correr (o expire) — no se puede cancelar.

3. **Manual finalize es admin-only, no creator-only.** El creator puede tener bias; admins lo cierran. Solo aparece cuando `closes_at < now()` y `status='open'`.

4. **No agregamos auto-finalize cron en este spec** — requiere edge function deployment + scheduling decision (cada 5min?). Pass 3 dedicado.

5. **`rule_repeal` / `fund_withdrawal` / `role_assignment` / `slot_dispute`** quedan disabled. Cada uno merece su propio spec con definir side-effect + body UI.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Cancel vote race con cast simultáneo | Trigger BE valida `no_casts_yet` atómicamente; cliente maneja error como "alguien ya votó" |
| Member removal vote sin side-effect = vote pasado sin acción | Warning explícito en CreateMemberRemovalSheet + en VoteResolvedView para member_removal |
| Manual finalize doble-tap → double finalize | RPC `finalize_vote` ya es idempotente (no-op si status != open) |
| Member removal target eligible to vote? | start_vote excluye `payload.target_member_id` (mismo patrón que fine_appeal infractor). Confirmar con BE |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `CreateMemberRemovalSheet`: validation (reason >30 chars, target != self). `MemberRemovalVoteBody`: render con target + reason. `MembersAdminView` swipe acción visible solo admin |
| 2 | `cancel_vote` RPC: rechaza con casts existentes / non-creator / status!=open. `VoteDetailView`: manual finalize visible solo admin + deadline passed. `cancelVote` button visible solo creator + no casts |

## Out of scope

- Pass 3 — trigger `apply_member_removal_on_pass`
- Pass 4 — auto-finalize cron (edge function)
- Pass 5 — `rule_repeal` / `fund_withdrawal` / `role_assignment` / `slot_dispute` bodies
- Vote extension (extender deadline) — diferido hasta tener demand real
- Vote re-open after finalize — explícitamente NO (immutability)
- Anonymous vote toggle UI (BE soporta, FE no expone — Pass futuro)

## Done When

- 7 tasks committed (4 Pass 1 + 3 Pass 2).
- Tap "Proponer remoción" desde MembersAdminView opens flow correctamente.
- VoteDetailView para `vote_type=member_removal` renderiza body custom.
- Admin ve "Finalizar voto" en votos abiertos con deadline pasado.
- Creator ve "Cancelar voto" cuando no hay casts.
- Build clean.

## Cobertura del plan inicial

**Pass 1 + Pass 2 en el primer commit** (~7 tasks, 1 migración pequeña). Pass 3+ específicos.
