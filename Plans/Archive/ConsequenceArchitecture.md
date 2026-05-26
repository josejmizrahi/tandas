# Ruul — Consequence Architecture

**Status:** Canónico desde 2026-05-18. Founder directive.
**Companion of:** `Plans/Active/RulesVsMoneyDoctrine.md` (rule ≠ fine ≠ ledger), `Plans/Active/ObligationsProjectionDoctrine.md` (obligations son projections sobre los atoms emitidos por consequences), `Plans/Active/RuleEngineDoctrine.md` (engine ejecuta consequences vía sinks, append-only, idempotente), `Plans/Active/UniversalRuleTemplates.md` (templates declaran qué consequences componen), `Plans/Active/AtomProjection.md`.

> Un **consequence** es la acción que el rule engine despacha cuando rule.trigger fires y rule.conditions pasan. Es **acción**, no efecto persistente. Toda consequence se normaliza al shape `{ type, target, params }`, ejecuta vía un sink server-side, emite ≥1 atom y nada más. Cero mutación de state tables.

> El error doctrinal a evitar: pensar "rule = trigger + condition + fine amount". Es "rule = trigger + condition + 1..N consequences"; fine es solo una.

---

## §1 — Las 5 familias canónicas de consequence

Toda consequence existente o futura cae en una de 5 familias. Cada familia tiene shape común (target selector + params), sink contract común y atom set típico.

### Familia A — Economic

**Propósito:** mover dinero o crear obligación monetaria.

| Type | Sink emits | Notas |
|---|---|---|
| `fine` | `INSERT public.fines (...)` + downstream `ledger_entries(fine_issued)` via `officialize_fine` cron | V1 implementado. Soporta flat (`amount`) y escalating (`baseAmount`, `stepAmount`, `stepMinutes`). |
| `refund` | `ledger_entries(refund)` referencing prior atom via `metadata.cancels` | Wave 2. |
| `contributionRequired` | `user_actions(action_type='contributeToFund')` + (futura) `ledger_entries(contribution_required)` | Wave 1 templates (`contribution_requirement`). |

**Reglas de la familia:**

1. Cualquier money movement DEBE pasar por `ledger_entries` insertion.
2. Sinks economic NO escriben `fines.paid`/`fines.waived`/`fines.status` — viven en projection `fines_view`.
3. Si un sink quiere "ajustar balance", debe insertar un atom compensating (`refund`, `settlement`), nunca `UPDATE balance`.

### Familia B — Coordination

**Propósito:** modificar el orden, asignación, custody o lifecycle de un recurso coordinado.

| Type | Sink emits | Notas |
|---|---|---|
| `releaseBooking` | `expire_booking` RPC → `bookingExpired` atom (+ `spaceReleased` for spaces) | Implementado mig 00268 — Space rules. |
| `bumpPriority` | mutates next `spaceWaitlistJoined` atom's priority payload, idempotent via `metadata.priority_bumped_by` | Implementado — Space waitlist. |
| `requireApproval` | `user_actions(action_type='assetActionApproval')` row, idempotent (rule_id, resource_id, source_atom_id) | Implementado mig 00226 — Asset rules. |
| `lockBookings` | TARGET: `lock_asset_bookings` RPC emite `assetBookingsLocked` atom + lazy `asset_booking_lock_view` (planned R7 — `OperationalCacheDoctrine.md` §6). HOY: `setBookingsLocked` direct mutation = **violación F8**. | Refactor pending. |
| `assignSlot` | `assign_slot` RPC → `slotAssigned` atom | Reserved, evaluator pendiente. |
| `createEvent` | `create_event` RPC → resource row + `eventCreated` atom | Reserved, evaluator pendiente. |
| `transferRight` | `transfer_right` RPC → `rightTransferred` atom | Reserved. |
| `releaseCustody` | `release_custody` RPC → `custodyReleased` atom | Wave 2. |
| `rotationPick` | `rotation_pick` consequence → `rotationAssigned` atom | Wave 1 (`rotating_responsibility`). |

**Reglas de la familia:**

1. Sinks coordination llaman RPC canónico — NUNCA `UPDATE resources` directo.
2. Idempotency: cada sink define la `idempotency_key` que el engine inserta en `rule_evaluations` (`RuleEngineDoctrine.md` §1 Regla 4).
3. Si el sink necesita cambiar metadata (ej. `bookings_locked`), el RPC debe (a) emitir atom primero, (b) leer via projection después. Pattern: ver `release_booking` (mig 00268) hecho bien vs `setBookingsLocked` hecho mal (F8).

### Familia C — Access

**Propósito:** otorgar, restringir o revocar el derecho/capability de un miembro a ejercer una acción.

| Type | Sink emits | Notas |
|---|---|---|
| `suspendRight` | `suspend_right` RPC → `rightSuspended` atom + cache `metadata.suspended_until` | Implementado mig 00200. |
| `revokeRight` | `revoke_right` RPC → `rightRevoked` atom | Implementado mig 00200. |
| `denyAction` | `warningEmitted` companion atom + `target.context.deny_message` returned to caller | Implementado mig 00268 — Space soft-block. |
| `lockCapability` | `capabilityLocked` atom + `capability_lock_view` projection | Wave 1 (`spending_lock` template). |
| `expireRight` | `expire_right` cron consequence → `rightExpired` atom | Wave 1 (`right_expiration` template). |

**Reglas de la familia:**

1. Access changes son atom-derived; `right_state_view` (planned R2) debe ser la única lectura del status, NO `resources.metadata.holder_member_id` (F2).
2. `denyAction` no rolls back el atom triggering — atom es truth (`TalmudicGovernance.md` §4.G). Solo registra warning y devuelve error string.

### Familia D — Social / Communicative

**Propósito:** comunicar al usuario sin cambiar state operativo.

| Type | Sink emits | Notas |
|---|---|---|
| `emitWarning` | `warningEmitted` system_event scoped al rule target | Implementado mig 00193 — pilot expense_threshold_warning. Cero side-effects. |
| `sendNotification` | `notifications_outbox` row → APNs dispatch via cron | Reserved consequence, evaluator pendiente (Wave 2 — `notification_reminder` template). |
| `logOnly` | `system_event(event_type='ruleEvaluated', verdict='audit_only')` | Reserved — útil para dry-runs. |

**Reglas de la familia:**

1. Social consequences son **idempotentes y descartables**. Si el cron retry, no duplican warning (idempotency_key en `rule_evaluations`).
2. `emitWarning` aparece en activity feed (`SystemEventListView`), NUNCA en Inbox (no requiere acción).
3. `sendNotification` requiere registro en `notifications_outbox` con `dedup_key` propio (RPC `enqueue_notification`).

### Familia E — Governance / Workflow

**Propósito:** arrancar un flujo de governance (voto, escalation, override audit).

| Type | Sink emits | Notas |
|---|---|---|
| `startVote` | `start_vote` RPC → `votes` row + `voteStarted` atom | Implementado. Usado por `vote_required`, `damage_vote_required`, `transfer_vote_required` templates. |
| `escalateToAdmin` | `user_actions(action_type='escalatedReview', priority='high')` | Reserved Wave 2. |
| `recordOverride` | `system_event(event_type='overrideInvoked')` + admin justification capture | Reserved Wave 2 (`admin_override_with_audit` template). |

**Reglas de la familia:**

1. Governance consequences NO ejecutan la decisión — solo arrancan el flujo. La resolución del voto/escalation despacha **otra** consequence vía `vote_resolution_handlers_registry` (mig 00242).
2. Reentrancy banned: el handler de un vote_resolution NO puede emitir `startVote` sobre el mismo subject (loop detection P0).

---

## §2 — El shape canónico

Toda consequence en `rules.consequences[]` jsonb se persiste como:

```jsonc
{
  "type": "fine",               // String — nombre canónico (ConsequenceType case)
  "target": "$trigger.actor",   // Optional selector (§3) — default $trigger.actor
  "config": {                   // Typed params, validated por el shape catalog
    "amount": 200,
    "currency": "MXN"
  }
}
```

### Reglas del shape:

1. **`type`** es uno de los casos canónicos. Nunca `fine_late_arrival`, `fine_with_grace` — esos son **params**, no types.
2. **`target`** es un selector limitado:
   - `$trigger.actor` — quien disparó el atom (default)
   - `$trigger.resource.owner` — owner del resource
   - `$trigger.resource.holder` — holder actual (right resources)
   - `$trigger.resource.admins` — admin set del group
   - `<uuid>` literal — miembro específico (uso raro, principalmente para test)
3. **`config`** es jsonb tipado según el shape piece. Validado en publish-time contra `rule_shapes.config_schema`. Engine valida al evaluar; rechaza con `rule_evaluations.verdict='error'` si fails.

---

## §3 — Sink contract (server-side TS)

Definido en `Plans/Active/RuleEngineDoctrine.md` §10. Refinado aquí:

```typescript
interface ConsequenceSink {
  // Stable identifier — equal to ConsequenceType case in Swift.
  readonly type: string;

  // Family declaration — used for telemetry, gating, and code review.
  readonly family: 'economic' | 'coordination' | 'access' | 'social' | 'governance';

  // RPCs / atom tables this sink writes to. Audited in tests.
  readonly emits: readonly string[];

  // MUST be idempotent given the same idempotency_key.
  // MUST emit atom OR start workflow OR call canonical RPC.
  // MUST NOT directly UPDATE state tables.
  // MUST validate config against rule_shapes.config_schema before executing.
  execute(args: {
    rule_version_id: uuid;
    trigger_event_id: uuid;
    target_member_id: uuid | null;
    target_resource_id: uuid | null;
    consequence_index: number;
    consequence_params: jsonb;     // already validated
    context: RuleContext;          // snapshotted at cron tick
  }): Promise<{ atoms_emitted: uuid[] }>;
}
```

### Sink registry (target post-refactor)

Vive en `supabase/functions/_shared/ruleEngine.ts`. Cada sink se registra en un mapa estricto:

```typescript
const SINK_REGISTRY: Record<string, ConsequenceSink> = {
  fine:                  fineSink,                  // family: economic
  emitWarning:           emitWarningSink,           // family: social
  requireApproval:       requireApprovalSink,       // family: coordination
  lockBookings:          lockBookingsSink,          // family: coordination (post-R7)
  releaseBooking:        releaseBookingSink,        // family: coordination
  denyAction:            denyActionSink,            // family: access
  bumpPriority:          bumpPrioritySink,          // family: coordination
  revokeRight:           revokeRightSink,           // family: access
  suspendRight:          suspendRightSink,          // family: access
  startVote:             startVoteSink,             // family: governance
  // ... más conforme se shippean Wave 1/2 templates
};
```

Engine resuelve `consequence.type → SINK_REGISTRY[type]`. Si no encuentra, marca `rule_evaluations.verdict='error'` con `error_payload={kind: 'unknown_consequence_type'}` y skipea sin throw.

### Idempotency

Mecanismo único centralizado (`RuleEngineDoctrine.md` §1 Regla 4):

```
idempotency_key = sha1(rule_version_id || trigger_event_id || target_member_id || consequence_index)
```

Engine inserta en `rule_evaluations` ANTES de invocar `sink.execute`. UNIQUE constraint short-circuits dupes. Sink puede asumir "yo soy la primera y única ejecución."

---

## §4 — Las 6 prohibiciones

### Prohibición 1 — No mutate state tables desde sink code

Ya cubierto en `RuleEngineDoctrine.md` §11 ("Forbidden patterns"). Re-enunciado aquí porque es la regla cardinal de consequence:

```typescript
// PROHIBIDO
await supabase.from('resources').update({ metadata: nextMeta }).eq('id', X);
await supabase.from('fines').update({ paid: true }).eq('id', X);
await supabase.from('groups').update({ fund_balance: N }).eq('id', X);

// CORRECTO
await supabase.rpc('lock_asset_bookings', { p_asset_id: X, p_rule_id: V, p_reason: R });
await supabase.rpc('pay_fine', { p_fine_id: X });
await supabase.from('ledger_entries').insert({ type: 'contribution', amount_cents: N, ... });
```

### Prohibición 2 — No type explosion por param differences

Wrong:
```typescript
enum ConsequenceType {
  fineFlat,
  fineEscalating,
  fineWithGrace,
  fineForLateRsvp,
  fineForNoShow
  // ...
}
```

Correct:
```typescript
enum ConsequenceType {
  fine
}
// shapes: { amount } | { baseAmount, stepAmount, stepMinutes } | …
```

Razón: rule engine evaluador único, easier testing, easier UI rendering. Las variantes viven en `config` validado por el shape catalog.

### Prohibición 3 — No mezclar familias en un solo consequence type

Wrong:
```typescript
case fineAndSuspend  // mezcla economic + access
case warnAndVote     // mezcla social + governance
```

Correct: rule.consequences es **array**. Componer multi-effect = listar dos consequences distintas:

```jsonc
{
  "consequences": [
    { "type": "fine",         "config": { "amount": 500 } },
    { "type": "suspendRight", "config": { "until": "2026-06-01" } }
  ]
}
```

Engine ejecuta cada uno con su propio idempotency_key (`consequence_index` diferente).

### Prohibición 4 — No sinks que llamen otros sinks directamente

Anti-recursion. Si un sink necesita gatillar otra acción, emite un atom y deja que la rule downstream lo procese en el próximo cron tick.

Ejemplo: `fine` sink no llama `emitWarning` sink internamente. Si la regla quiere ambos, declara dos consequences.

### Prohibición 5 — No business logic dentro del sink más allá de canonical RPC

El sink:
1. Valida params (delegado al shape catalog si posible).
2. Llama RPC canónico O hace `INSERT` en atom table.
3. Retorna `atoms_emitted` array.

NO calcula montos custom, NO evalúa conditions reentrantes, NO consulta otras tablas para "decidir" qué hacer. Toda decisión vive en `rule.conditions` evaluadas por el engine antes de despachar al sink.

### Prohibición 6 — No silent failure

Sink que falla:
- Throw → engine atrapa, marca `rule_evaluations.verdict='error'`, `error_payload={message, stack}`. System_event NOT marked processed → retry next cron tick.
- Idempotency unique violation → engine treats as "already done", logs as `verdict='skipped_dup'`, marks system_event processed.
- Config validation failure → engine marks `verdict='error'`, `error_payload={kind:'invalid_config', detail}`. System_event marked processed (no retry — broken config doesn't get better via retry).

---

## §5 — Mapa de consequence type → families → atoms emitted

| ConsequenceType (Swift) | Family | RPC / atom emitted | Implemented |
|---|---|---|---|
| `.fine` | A — Economic | `fines` insert (V1); future `ledger_entries(fine_issued)` direct | ✅ V1 |
| `.refund` | A — Economic | `ledger_entries(refund)` | ❌ Wave 2 |
| `.contributionRequired` | A — Economic | `user_actions(contributeToFund)` + future atom | ❌ Wave 1 |
| `.requireApproval` | B — Coordination | `user_actions(assetActionApproval)` | ✅ mig 00226 |
| `.lockBookings` | B — Coordination | `lock_asset_bookings` RPC → `assetBookingsLocked` atom (post-R7); HOY direct write | ⚠ Violation F8 |
| `.releaseBooking` | B — Coordination | `expire_booking` RPC → `bookingExpired` atom | ✅ mig 00268 |
| `.bumpPriority` | B — Coordination | Mutates next `spaceWaitlistJoined` atom payload | ✅ mig 00268 |
| `.assignSlot` | B — Coordination | `assign_slot` RPC → `slotAssigned` atom | ❌ Reserved |
| `.createEvent` | B — Coordination | `create_event` RPC → resource + `eventCreated` | ❌ Reserved |
| `.transferRight` | B — Coordination | `transfer_right` RPC → `rightTransferred` | ❌ Reserved |
| `.suspendRight` | C — Access | `suspend_right` RPC → `rightSuspended` | ✅ mig 00200 |
| `.revokeRight` | C — Access | `revoke_right` RPC → `rightRevoked` | ✅ mig 00200 |
| `.denyAction` | C — Access | `warningEmitted` companion + deny_message return | ✅ mig 00268 |
| `.emitWarning` | D — Social | `warningEmitted` system_event | ✅ mig 00193 |
| `.sendNotification` | D — Social | `notifications_outbox` row | ❌ Wave 2 |
| `.logOnly` | D — Social | `system_event(ruleEvaluated, verdict='audit_only')` | ❌ Reserved |
| `.startVote` | E — Governance | `start_vote` RPC → `votes` + `voteStarted` | ✅ |
| `.loseTurn` | B — Coordination (future) | `loseTurn` consequence + atom `turnSkipped` | ❌ Wave 2 (`rotation_skip_consequence`) |
| `.losePriority` | B — Coordination | `bumpPriority` con `priority_delta<0` | ✅ same sink |
| `.serviceCompensation` | A — Economic (future) | `ledger_entries(reimbursement)` | ❌ Wave 2 |
| `.blockTemporary` | C — Access | `lockCapability` RPC → atom | ❌ Wave 1 (`spending_lock`) |
| `.reciprocity` | A — Economic (future) | Compound: `ledger_entries(refund)` + `ledger_entries(contribution)` | ❌ Wave 3 |
| `.sumPoints` / `.subtractPoints` | C — Access (point-based) | Reserved | ❌ Wave 3 |
| `.callWebhook` | D — Social | Reserved — non-deterministic, requires careful design | ❌ Likely Never (`RuleEngineDoctrine.md` §17) |

Source para validación: `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/ConsequenceType.swift`.

---

## §6 — Adding a new consequence type (checklist)

PR que agrega consequence nueva debe incluir:

1. **Doctrine entry** — agregar fila en §5 con family y atom plan.
2. **Swift enum** — case nuevo en `ConsequenceType.swift` con doc comment que cite family + sink path.
3. **TS sink** — implementación en `supabase/functions/_shared/ruleEngine.ts` que respete §3 contract.
4. **Atom guard** — si emite a nueva atom table, agregar `*_atom_guard` trigger.
5. **Shape piece** — INSERT en `public.rule_shapes` con `config_schema` validable.
6. **Test fixtures** — mínimo 5 (happy / condition_fails / idempotent_under_retry / config_invalid / target_not_found).
7. **Template integration** — al menos 1 template universal usa el consequence en su `composition` (sino el consequence es huérfano).
8. **Audit ref** — entrada en `ConsequenceArchitecture.md` §5 + (si rompe algo existente) `RulesFinesAudit_2026-05-18.md`.

CI block si falta cualquier punto.

---

## §7 — Tests doctrinales

| Test | Cubre |
|---|---|
| `test_consequence_type_swift_matches_ts_registry` | Codegen invariante: Swift `ConsequenceType` set == TS `SINK_REGISTRY` keys. |
| `test_no_sink_calls_another_sink` | Prohibición 4 — grep TS for `await sink.X.execute(...)`. |
| `test_no_sink_updates_state_table` | Prohibición 1 — scan sinks for `.update()` on non-atom tables. |
| `test_every_sink_emits_at_least_one_atom_or_workflow` | Sink contract — no silent no-op. |
| `test_every_consequence_type_has_family_declared` | §5 mapping completeness. |
| `test_idempotency_key_includes_consequence_index` | Multi-consequence rules don't deduplicate. |
| `test_unknown_consequence_type_does_not_throw` | Engine resilience — verdict=error, no crash. |

---

## §8 — Doctrina final

> **Rules emit consequence intent.**
> **Consequences are normalized actions.**
> **Sinks execute consequences via canonical atom emission.**
> **Atoms are the truth.**
> **State tables are never mutated by sinks directly.**
>
> **A consequence is what the rule decides to do.**
> **It is not what the system already is.**
> **It is not where the money lives.**
> **It is the verb between trigger and atom.**

Cuando hay duda sobre dónde modelar algo nuevo:

- ¿Cambia plata? → consequence `fine|refund|contributionRequired` family A.
- ¿Cambia quién tiene qué? → family B coordination o C access.
- ¿Comunica sin cambiar nada? → family D.
- ¿Arranca un flujo deliberativo? → family E governance.
- ¿No cae en ninguna? → probable que sea una rule nueva, no una consequence nueva — revisar `UniversalRuleTemplates.md` §3.
