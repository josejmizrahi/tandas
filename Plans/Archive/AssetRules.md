# Ruul — Asset Rule Templates (Canonical Implementation Plan)

**Status:** Plan canónico desde 2026-05-15. Founder-approved (doc-first slice).
**Companion of:** `Plans/Active/Asset.md` §18 (templates listados), `Plans/Active/Constitution.md` Artículo 9 (rules gobiernan acciones), `Plans/Active/Governance.md` §0.5 + §10 (Builder UX).
**Scope:** Deja roadmap determinístico para implementar los 5 rule templates canónicos del asset spec. Cada template aterriza como (shapes + template seed + engine evaluator + iOS mirror). Este doc **no implementa código** — lista el contrato exacto que un PR de seguimiento debe cumplir.

---

## §1 — Resumen del §18 (Asset.md)

Los 5 templates canónicos del asset spec, con su mapping a primitivas:

| # | Template ID                       | Display ES                                  | Trigger atom         | Trigger shape         | Condition shape       | Consequence shape   | Estado |
|---|-----------------------------------|---------------------------------------------|----------------------|-----------------------|-----------------------|---------------------|--------|
| 1 | `damage_approval_required`        | "Daño grande requiere aprobación"           | `damageReported`     | `damageReported` (new)| `damageAmountAbove` (new) | `requireApproval` (new) | new |
| 2 | `not_returned_fine`               | "Multa por no devolver el activo"           | (cron derivado)      | `checkoutOverdue` (new) | `alwaysTrue` (reuse)   | `fine` (reuse)      | new |
| 3 | `maintenance_overdue_lock`        | "Bloquea bookings si mantenimiento atrasado"| (cron derivado)      | `maintenanceOverdue` (new) | `alwaysTrue` (reuse) | `lockBookings` (new) | new |
| 4 | `transfer_large_vote`             | "Voto para transferencias grandes"          | `assetTransferred`   | `assetTransferred` (new)| `transferAmountAbove` (new) | `startVote` (reuse) | new |
| 5 | `damage_logged_warning`           | "Aviso al grupo por daño reportado"         | `damageReported`     | `damageReported` (new) | `alwaysTrue` (reuse)  | `emitWarning` (reuse) | new |

> Reuses: `alwaysTrue`, `fine`, `startVote`, `emitWarning` ya existen en `public.rule_shapes` + engine. Nuevas piezas: 5 trigger/condition shapes + 2 consequences (`requireApproval`, `lockBookings`).

---

## §2 — Atoms ya disponibles (no requieren migración)

Mig 00204 + `SystemEventType.swift` (cases 173-219) ya whitelistean todos los atoms asset que los triggers necesitan:

```
custodyAssigned, custodyReleased
maintenanceLogged, maintenanceCompleted
damageReported
assetUsed, assetCheckedOut, assetCheckedIn
valuationRecorded
assetTransferred, assetAssigned, assetReturned
```

**No hay que añadir SystemEventType cases nuevos.** Lo que falta es exponerlos como **trigger shapes** del builder + engine evaluators que mapean cada atom a `RuleTarget[]`.

---

## §3 — Shapes nuevas a crear

### 3.1 Trigger shapes

| ID                   | Atom fuente              | Resource types | Config fields                                 | Comentario |
|----------------------|--------------------------|----------------|-----------------------------------------------|------------|
| `damageReported`     | `damageReported`         | `['asset']`    | `[]`                                          | Member que reporta = `event.member_id` |
| `assetTransferred`   | `assetTransferred`       | `['asset']`    | `[]`                                          | Member transferring = `event.member_id` |
| `checkoutOverdue`    | (cron derivado)          | `['asset']`    | `[{key:'grace_days', kind:'int', default:1}]` | Emite atom sintético `assetCheckoutOverdue` desde `process-system-events` cuando `expected_return_at < now() - grace`. Mig nueva crea el cron path. |
| `maintenanceOverdue` | (cron derivado)          | `['asset']`    | `[{key:'days', kind:'int', default:7}]`        | Emite `assetMaintenanceOverdue` cuando `maintenance.logged` no tiene `maintenance.completed` ni `damage.reported` en window |

### 3.2 Condition shapes

| ID                       | Aplica a trigger    | Config fields                                                       | Evaluator pseudocode |
|--------------------------|---------------------|---------------------------------------------------------------------|----------------------|
| `damageAmountAbove`      | `damageReported`    | `[{key:'threshold_cents', kind:'currency', default:500000}]`         | `event.payload.estimated_cost_cents > threshold_cents` |
| `transferAmountAbove`    | `assetTransferred`  | `[{key:'threshold_cents', kind:'currency', default:5000000}]`        | `target.context.valuation_cents > threshold_cents` (mirar `asset_valuation_view` para latest) |

### 3.3 Consequence shapes

| ID                | Behavior                                                                                         | New evaluator |
|-------------------|--------------------------------------------------------------------------------------------------|---------------|
| `requireApproval` | Crea `user_actions` row de tipo `assetActionApproval` apuntando al resource + target action     | sí |
| `lockBookings`    | Inserta atom `bookingLockEnabled` o actualiza `resources.metadata.bookings_locked=true`. Sticky hasta `maintenance.completed`. | sí |

> Los consequences DEBEN ser idempotent: re-running the rule must not double-issue approvals or duplicate the lock. Same contract que `fine` (que es idempotent vía `fines_view` dedupe-on-(rule_id, target_id, source_event_id)).

---

## §4 — Engine evaluators (`_shared/ruleEngine.ts`)

### 4.1 Triggers

Cada nuevo trigger sigue el shape `TriggerEvaluator = (event, rule, context) => Promise<RuleTarget[]>`. Pseudocode:

```ts
// damageReported — single target = quien reporta el daño
damageReported: async (event, _rule, context) => {
  if (!event.resource_id || !event.member_id) return [];
  return [{
    member_id: event.member_id,
    resource_id: event.resource_id,
    context: {
      severity:               event.payload?.severity,
      estimated_cost_cents:   event.payload?.estimated_cost_cents,
      currency:               event.payload?.currency,
    },
  }];
},

// assetTransferred — single target = quien transfiere
assetTransferred: async (event, _rule, context) => {
  if (!event.resource_id || !event.member_id) return [];
  // Latest valuation for transferAmountAbove evaluation
  const valuation = await context.sink.latestValuation?.(event.resource_id);
  return [{
    member_id: event.member_id,
    resource_id: event.resource_id,
    context: {
      to_user_id:       event.payload?.to_user_id,
      to_group:         event.payload?.to_group,
      valuation_cents:  valuation?.value_cents ?? null,
    },
  }];
},

// checkoutOverdue — single target = holder del checkout sin check-in
checkoutOverdue: async (event, _rule, context) => {
  if (!event.resource_id || !event.member_id) return [];
  return [{
    member_id: event.member_id,
    resource_id: event.resource_id,
    context: {
      expected_return_at:  event.payload?.expected_return_at,
      checked_out_at:      event.payload?.checked_out_at,
    },
  }];
},

// maintenanceOverdue — broadcasts a member-less target (resource-scoped)
maintenanceOverdue: async (event, _rule, context) => {
  if (!event.resource_id) return [];
  return [{
    member_id: null,
    resource_id: event.resource_id,
    context: {
      maintenance_event_id: event.payload?.maintenance_event_id,
      days_open:            event.payload?.days_open,
    },
  }];
},
```

### 4.2 Conditions

```ts
damageAmountAbove: (cfg, target) => {
  const threshold = cfg.threshold_cents ?? 500000;
  return (target.context.estimated_cost_cents ?? 0) > threshold;
},

transferAmountAbove: (cfg, target) => {
  const threshold = cfg.threshold_cents ?? 5000000;
  return (target.context.valuation_cents ?? 0) > threshold;
},
```

### 4.3 Consequences

```ts
requireApproval: async (cons, target, rule, context) => {
  if (!target.resource_id) {
    return failure(rule.id, target.member_id, "requireApproval needs resource_id");
  }
  const actionId = await context.sink.createUserAction({
    type:         "assetActionApproval",
    group_id:     rule.group_id,
    resource_id:  target.resource_id,
    member_id:    target.member_id,
    rule_id:      rule.id,
    payload:      target.context,
  });
  return success(rule.id, target.member_id, { action_id: actionId });
},

lockBookings: async (_cons, target, rule, context) => {
  if (!target.resource_id) {
    return failure(rule.id, target.member_id, "lockBookings needs resource_id");
  }
  await context.sink.setBookingsLocked(target.resource_id, true, {
    reason: rule.title,
    source_rule_id: rule.id,
  });
  return success(rule.id, null, { resource_id: target.resource_id });
},
```

Sink hooks (`context.sink`) need extension:
- `latestValuation(resourceId)` — reads `asset_valuation_view`
- `createUserAction({...})` — inserts into `user_actions` with `type='assetActionApproval'`
- `setBookingsLocked(resourceId, bool, meta)` — updates `resources.metadata.bookings_locked` + emits an atom for audit

---

## §5 — Cron paths (los 2 atoms sintéticos)

`process-system-events` ya corre cada minuto y procesa system events. Para `checkoutOverdue` + `maintenanceOverdue` necesitamos un emisor nuevo similar a `emit-deadline-events`:

### 5.1 `emit-asset-overdue-events` (cron 1/min)

```sql
-- pseudo, edge function ts
const overdueCheckouts = await sql`
  with last_out as (
    select resource_id, member_id, occurred_at, payload->>'expected_return_at' as expected_return_at,
           row_number() over (partition by resource_id order by occurred_at desc) rn
    from system_events
    where event_type = 'assetCheckedOut'
  ),
  last_in as (
    select resource_id, max(occurred_at) as last_checked_in_at
    from system_events
    where event_type = 'assetCheckedIn'
    group by resource_id
  )
  select lo.*
  from last_out lo
  left join last_in li on li.resource_id = lo.resource_id
  where lo.rn = 1
    and (li.last_checked_in_at is null or li.last_checked_in_at < lo.occurred_at)
    and (lo.expected_return_at::timestamptz) < now()
    and not exists (
      -- dedupe: don't re-fire if we already emitted in last 24h
      select 1 from system_events s
      where s.event_type = 'assetCheckoutOverdue'
        and s.resource_id = lo.resource_id
        and s.occurred_at > now() - interval '24 hours'
    )
`;
// emit one assetCheckoutOverdue per row
```

`maintenanceOverdue` similar — joins `maintenanceLogged` sin matching `maintenanceCompleted` o `damageReported`.

Ambos nuevos atom types (`assetCheckoutOverdue`, `assetMaintenanceOverdue`) **sí** requieren extender `SystemEventType.swift` + mig que extiende `is_known_system_event_type` whitelist. Esto es un costo adicional (~1 mig + iOS codegen) que se contabilizó arriba.

---

## §6 — Mig order (un PR ideal por bloque)

| Orden | Mig                                  | Cambia                                                                                |
|-------|--------------------------------------|---------------------------------------------------------------------------------------|
| 1     | `XXXXX_asset_rule_atoms.sql`         | Extiende `is_known_system_event_type` con `assetCheckoutOverdue` + `assetMaintenanceOverdue`. |
| 2     | `XXXXX_asset_rule_shapes.sql`        | Insert de los 4 trigger shapes + 2 condition shapes + 2 consequence shapes (§3).      |
| 3     | `XXXXX_asset_rule_templates.sql`     | Insert de los 5 templates (§1).                                                       |
| 4     | (edge fn) `emit-asset-overdue-events`| Nueva cron 1/min con su trigger (§5).                                                 |
| 5     | (edge fn) `_shared/ruleEngine.ts`    | Triggers + conditions + consequences evaluators (§4). Sink hook extensions.            |
| 6     | (iOS) `RuleTemplateRepository.swift` | Mirror templates en `defaultBetaCatalog`. Codegen Swift↔TS regenera SystemEventType.   |
| 7     | (iOS) `SystemEventType.swift`        | Codegen auto-extiende cases para los 2 atoms sintéticos.                              |
| 8     | (tests) `RuleEngineTests`            | 1 test per template (5) cubriendo happy path + threshold edge.                         |

**No mezclar pasos 1-3 en una sola mig** — split helps reviewers verify each layer independently y mantiene el rollback localizado.

---

## §7 — iOS mirror snippet

Adición al `defaultBetaCatalog` en `RuleTemplateRepository.swift`:

```swift
RuleBuilderTemplate(
    id: "damage_approval_required",
    displayNameES: "Daño grande requiere aprobación",
    descriptionES: "Si alguien reporta un daño con costo estimado mayor a $X, se crea una acción pendiente de aprobación para administradores.",
    category: "assets",
    templateKind: "governance",
    requiredCapabilities: ["maintenance"],
    defaultParams: .object(["threshold_cents": .int(500_000)]),
    composition: .init(
        triggerShapeId: "damageReported",
        conditionShapeIds: ["damageAmountAbove"],
        consequenceShapeIds: ["requireApproval"],
        scopeHint: "resource"
    ),
    sortOrder: 80
),
RuleBuilderTemplate(
    id: "not_returned_fine",
    displayNameES: "Multa por no devolver el activo",
    descriptionES: "Si quien hizo checkout no devuelve el activo en X días después del expected_return, cobra multa.",
    category: "assets",
    templateKind: "penalty",
    requiredCapabilities: ["custody", "fines"],
    defaultParams: .object(["grace_days": .int(1), "amount": .int(200)]),
    composition: .init(
        triggerShapeId: "checkoutOverdue",
        conditionShapeIds: ["alwaysTrue"],
        consequenceShapeIds: ["fine"],
        scopeHint: "resource"
    ),
    sortOrder: 90
),
RuleBuilderTemplate(
    id: "maintenance_overdue_lock",
    displayNameES: "Bloquea bookings si mantenimiento atrasado",
    descriptionES: "Si un mantenimiento queda abierto más de X días, bloquea nuevos bookings hasta que se cierre.",
    category: "assets",
    templateKind: "governance",
    requiredCapabilities: ["maintenance", "booking"],
    defaultParams: .object(["days": .int(7)]),
    composition: .init(
        triggerShapeId: "maintenanceOverdue",
        conditionShapeIds: ["alwaysTrue"],
        consequenceShapeIds: ["lockBookings"],
        scopeHint: "resource"
    ),
    sortOrder: 100
),
RuleBuilderTemplate(
    id: "transfer_large_vote",
    displayNameES: "Voto para transferencias grandes",
    descriptionES: "Si la valuación del activo supera $X y se intenta transferir, abre un voto group-wide.",
    category: "assets",
    templateKind: "governance",
    requiredCapabilities: ["transfer", "voting"],
    defaultParams: .object([
        "threshold_cents":   .int(5_000_000),
        "duration_hours":    .int(48),
        "quorum_percent":    .int(50),
        "threshold_percent": .int(66),
    ]),
    composition: .init(
        triggerShapeId: "assetTransferred",
        conditionShapeIds: ["transferAmountAbove"],
        consequenceShapeIds: ["startVote"],
        scopeHint: "resource"
    ),
    sortOrder: 110
),
RuleBuilderTemplate(
    id: "damage_logged_warning",
    displayNameES: "Aviso al grupo por daño reportado",
    descriptionES: "Cualquier daño reportado emite un aviso visible en la actividad del grupo.",
    category: "assets",
    templateKind: "governance",
    requiredCapabilities: ["maintenance"],
    defaultParams: .object([:]),
    composition: .init(
        triggerShapeId: "damageReported",
        conditionShapeIds: ["alwaysTrue"],
        consequenceShapeIds: ["emitWarning"],
        scopeHint: "resource"
    ),
    sortOrder: 120
)
```

`category: "assets"` es nueva — el Template Gallery la pintará como tercera categoría junto a `attendance` y `money` que ya existen.

---

## §8 — Tests requeridos (DoD)

Cada PR de implementación debe shipear, mínimo:

| Test                                      | Cubre                                                                 |
|-------------------------------------------|-----------------------------------------------------------------------|
| `damageReportedTriggerEnumeratesMember`   | Un atom → target único = quien reportó                                |
| `damageAmountAboveFiresOnThreshold`       | `payload.estimated_cost_cents = threshold+1` fires; `-1` skips        |
| `requireApprovalCreatesUserAction`        | Inserción correcta en `user_actions` + dedupe en re-run               |
| `checkoutOverdueDeduplicatesWithin24h`    | Cron no re-emite si ya emitió overdue hace <24h                       |
| `maintenanceOverdueRespectsCompletion`    | `maintenance.completed` cierra el window — no se emite overdue        |
| `lockBookingsSetsMetadata`                | `resources.metadata.bookings_locked = true` y atom de audit emitido   |
| `transferLargeVoteRequiresValuation`      | Falla con claridad si `asset_valuation_view` está vacía               |
| `eachAssetTemplateHappyPath`              | End-to-end por cada uno de los 5 templates                            |

---

## §9 — Open questions (decidir antes de implementar)

1. **`lockBookings` idempotencia**: ¿flag jsonb en `resources.metadata` o tabla `resource_locks` propia? Recomendación: empezar con metadata flag + atom de audit (más simple, reversible vía siguiente atom `bookingLockReleased`); migrar a tabla solo si necesitamos múltiples razones simultáneas de lock.

2. **`requireApproval` UI**: ¿el `user_action` aparece en Inbox cross-group? Sí (los UserActions ya son cross-group con filtro per-group). Pero el approver es admin del grupo, no cualquier member — `pending(_, groupId:)` ya filtra; lo que falta es resolver "¿qué hace el admin al aprobar?" → emite atom `assetActionApproved` que el engine consume como side-channel (out of scope de este doc).

3. **`transferAmountAbove`**: leer la valuation **antes** o **después** del transfer? Pre-transfer → engine corre al **prepare** del transfer (no implementado). Post-transfer → siempre dispara, el voto reverse-flow si rechaza (similar a `expense_threshold_vote`). Recomendación: post-transfer + vote consequence emite `assetTransferReversed` si pierde, alineado al patrón existente de `expense_threshold_vote`.

4. **Cron windows**: 1/min para overdue events es estándar. ¿OK soportar `checkoutOverdue` con `grace_days` configurable per-rule? Sí — el shape lo expone como config field, el cron lee la rule's grace_days al evaluar.

5. **`assets` category en gallery**: ¿filtrable por `required_capabilities` igual que el resto? Sí — si la asset's capability `maintenance` está activa, los templates 1/3/5 aparecen; si `booking` también, sale el 3; etc. Cliente filtra; server seed solo lista.

---

## §10 — No incluido (out of scope explícito)

- `access` + `delegation` capabilities siguen `incomplete` (Asset.md §16). No hay templates contra ellas hasta que el runtime path aterrice.
- `ledger`-driven rules sobre assets (e.g. "gasto de mantenimiento > $X → vote") **ya están cubiertos** por los 2 templates de money existentes (`expense_threshold_warning`, `expense_threshold_vote`) — el ledger entry sobre el asset las dispara via `ledgerEntryCreated`, no requiere shape nuevo. Asset.md §18 lo lista pero el binding ya existe.
- Recurrence (revaluación mensual automática del §18 — "revaluation mensual") es **cron de aplicación**, no rule. Vive como edge function separada (`emit-asset-revaluation-due` cuando exista), fuera de este plan.

---

## §11 — Definición final

> 5 templates canónicos + 4 trigger shapes + 2 condition shapes + 2 consequences + 2 atoms sintéticos + 1 cron + 1 iOS mirror + 8 tests. Ejecutable en ~3-4 días con un implementador dedicado; ~1 día si ya hay familiaridad con el rule engine + cron pattern.

Ese es el roadmap canónico para cerrar `Plans/Active/Asset.md` §18.
