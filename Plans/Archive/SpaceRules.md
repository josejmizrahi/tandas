# Ruul — Space Rule Templates (Canonical Implementation Plan)

**Status:** Plan canónico desde 2026-05-18. Founder-approved (doc-first slice).
**Companion of:** `Plans/Active/Space.md` §18 (templates listados), `Plans/Active/Constitution.md` Artículo 9 (rules gobiernan acciones), `Plans/Active/AssetRules.md` (spec hermana — same pattern), `Plans/Active/Governance.md` §0.5 + §10 (Builder UX).
**Scope:** Roadmap determinístico para implementar los rule templates canónicos del space spec. Cada template aterriza como (shapes + template seed + engine evaluator + iOS mirror). Este doc **no implementa código** — lista el contrato que un PR de seguimiento debe cumplir.

---

## §1 — Resumen del §18 (Space.md)

Los 7 templates canónicos del space spec, con su mapping a primitivas:

| # | Template ID                          | Display ES                                       | Trigger atom              | Trigger shape                | Condition shape               | Consequence shape   | Estado |
|---|--------------------------------------|--------------------------------------------------|---------------------------|------------------------------|-------------------------------|---------------------|--------|
| 1 | `space_capacity_overflow_waitlist`   | "Cuando se llena, manda a lista de espera"       | `spaceCapacityReached`    | `spaceCapacityReached` (new) | `alwaysTrue` (reuse)          | `emitWarning` (reuse) → UI offers join_waitlist | new |
| 2 | `space_cancellation_late_fine`       | "Multa por cancelación tardía (<24h)"            | `bookingCancelled`        | `bookingCancelled` (new)     | `cancelledWithinHours` (new)  | `fine` (reuse)      | new |
| 3 | `space_no_check_in_release`          | "Libera la reserva si no hay check-in en 30 min" | (cron `emit-space-no-check-in` — derived) | `bookingNoCheckIn` (new)  | `alwaysTrue` (reuse)          | `releaseBooking` (new) | new |
| 4 | `space_outside_allowed_hours_deny`   | "Rechaza reservas fuera del horario permitido"   | `bookingCreated`          | `bookingCreated` (new)       | `outsideAllowedHours` (new)   | `denyAction` (new)  | new |
| 5 | `space_founder_priority_bump`        | "Founders tienen prioridad +100 en waitlist"     | `spaceWaitlistJoined`     | `spaceWaitlistJoined` (new)  | `actorHasRole` (new)          | `bumpPriority` (new) | new |
| 6 | `space_long_booking_vote`            | "Reservas > N horas requieren voto"              | `bookingCreated`          | `bookingCreated` (new)       | `bookingDurationAbove` (new)  | `startVote` (reuse) | new |
| 7 | `space_damage_temporary_closure_vote` | "Daño grave → voto cierre temporal"             | `damageReported`          | `damageReported` (reuse, asset) | `damageSeverityAbove` (reuse, asset) | `startVote` (reuse) | new |

> Reuses: `alwaysTrue`, `fine`, `startVote`, `emitWarning`, `damageReported`, `damageSeverityAbove` ya existen. Nuevas piezas: 5 trigger shapes + 5 condition shapes + 3 consequences (`releaseBooking`, `denyAction`, `bumpPriority`).

---

## §2 — Atoms ya disponibles (no requieren migración)

Mig 00264 + `SystemEventType.swift` whitelistean todos los atoms space que los triggers necesitan:

```
spaceCreated, spaceBooked, spaceReleased, spaceCapacityReached,
spaceWaitlistJoined, spaceWaitlistPromoted,
spaceAccessGranted, spaceAccessRevoked
```

Mig 00154 + mig 00203 + 00216 whitelistean los compartidos que aplican a space:

```
bookingCreated, bookingCancelled, bookingExpired,
checkInRecorded,
resourceArchived, resourceUnarchived, resourceRenamed,
resourceLinked, resourceUnlinked
```

Mig 00204 ya whitelistea `damageReported` para asset; reuse para space sin trabajo extra.

---

## §3 — Nuevas piezas de shape catalog

### 3.1 — Trigger shapes (5)

| shape_id                       | atom matched                | payload claves útiles                     |
|--------------------------------|-----------------------------|-------------------------------------------|
| `spaceCapacityReached`         | `spaceCapacityReached`      | `capacity`, `triggered_booking_id`        |
| `bookingCancelled`             | `bookingCancelled`          | `booking_id`, `target_kind`, `reason`     |
| `bookingNoCheckIn`             | (cron-emitted, future)      | `booking_id`, `minutes_overdue`           |
| `bookingCreated` (space-scope) | `bookingCreated`            | `booking_id`, `target_kind='space'`       |
| `spaceWaitlistJoined`          | `spaceWaitlistJoined`       | `priority`, `joined_at`                   |

Nota: `bookingNoCheckIn` requiere un cron job (`emit-space-no-check-in-events`) que escanea bookings activos sin checkInRecorded después de un grace window — análogo a `emit-asset-overdue-events` (mig 00225).

### 3.2 — Condition shapes (5)

| shape_id                  | parámetros declarativos              | pseudocode                                       |
|---------------------------|--------------------------------------|--------------------------------------------------|
| `cancelledWithinHours`    | `{hours: int}`                       | `(booking.metadata.starts_at - now()) < hours`   |
| `outsideAllowedHours`     | `{start: "HH:mm", end: "HH:mm"}`     | `now().hour < start OR now().hour >= end`        |
| `actorHasRole`            | `{role: text}`                       | `member.roles ? role`                            |
| `bookingDurationAbove`    | `{minutes: int}`                     | `(booking.ends_at - booking.starts_at) > minutes`|
| `damageSeverityAbove`     | `{level: enum}` (reuse asset)        | `severity >= level` (asset spec)                 |

### 3.3 — Consequence shapes (3 nuevos + reuses)

| shape_id          | efecto                                                              | nuevo o reuse |
|-------------------|---------------------------------------------------------------------|---------------|
| `releaseBooking`  | Llama `expire_booking(booking_id, reason='no_check_in')`            | new           |
| `denyAction`      | Bloquea la acción que generó el trigger (booking, etc.)             | new           |
| `bumpPriority`    | Modifica `payload.priority` del próximo `spaceWaitlistJoined` row del actor | new       |
| `fine`            | Issue manual fine al actor                                          | reuse         |
| `startVote`       | Inicia vote workflow para approval                                  | reuse         |
| `emitWarning`     | Aviso al grupo via system_events                                    | reuse         |

---

## §4 — Migration plan (incremental, 3 PRs)

### PR-1: shapes catalog + reuses
- Mig: agrega 5 trigger shapes + 5 condition shapes + 3 consequence shapes a `public.rule_shapes`.
- Mig: extiende `condition_type` y `consequence_type` SQL whitelists con los nuevos slugs.
- iOS: agrega cases a `ConditionType.swift`, `ConsequenceType.swift`, regen Generated/+Codable.
- iOS: humanLabel + isImplementedInV1 false hasta PR-3.

### PR-2: cron `emit-space-no-check-in-events`
- Supabase Edge Function análoga a `emit-asset-overdue-events`.
- Lee bookings activos sobre spaces con `metadata.starts_at + 30min < now()` sin checkInRecorded posterior.
- Emite atom `bookingNoCheckIn` con payload `{booking_id, minutes_overdue}`.
- Idempotente via `metadata.no_check_in_emitted` flag o tabla `processed_bookings`.

### PR-3: engine evaluator
- Extender `supabase/functions/_shared/ruleEngine.ts` con evaluators para los 5 nuevos condition shapes + 3 nuevos consequence handlers.
- Tests E2E: book → no check-in → cron fires → engine evaluates → expire_booking dispatched.
- Tests E2E: book at capacity → spaceCapacityReached → engine emits warning.

### PR-4: rule templates seed
- Mig: 7 rows en `public.rule_templates` con `is_active=false` por defecto.
- iOS: Template Gallery aprende a renderizar `resource_type='space'` templates.

---

## §5 — Capability gating

Cada template requiere capabilities específicas activadas en el space:

| Template                           | Required capabilities          |
|------------------------------------|--------------------------------|
| `space_capacity_overflow_waitlist` | `capacity`, `waitlist`         |
| `space_cancellation_late_fine`     | `booking`, `consequence`       |
| `space_no_check_in_release`        | `booking`, `check_in`          |
| `space_outside_allowed_hours_deny` | `booking`, `schedule`          |
| `space_founder_priority_bump`      | `waitlist`                     |
| `space_long_booking_vote`          | `booking`, `voting`            |
| `space_damage_temporary_closure_vote` | `maintenance`, `voting`     |

iOS Rule Builder filtra templates contra las capabilities activas en el resource antes de mostrarlas como sugerencias.

---

## §6 — Definition of Done por template

- Shape rows en `public.rule_shapes` con `enabled_resource_types` incluye `space`.
- ConditionType + ConsequenceType Swift cases + Generated codegen mirrored.
- Engine evaluator returns deterministic effect.
- E2E test que prueba trigger → evaluation → consequence end-to-end.
- iOS template card renders en Rule Builder cuando capabilities matchean.
- humanLabel ES y EN en `ConditionType+Extensions.swift` / `ConsequenceType+Extensions.swift`.

---

## §7 — Out of scope (futuro)

- Partial-time-overlap conditions (e.g. "reserva 11:00-12:30 traslapa 12:00-13:00 por 30min"). Hoy todo booking es claim atómico — overlap es count, no overlap-minutes.
- Multi-space rules (e.g. "si X% de spaces del grupo están llenos, abrir vote para nueva inversión"). Requiere `rules.scope='group'` + aggregate evaluator nuevo.
- Stateful priority bumps (e.g. "miembros que cancelaron 3 veces este mes pierden prioridad"). Requiere ledger de comportamiento — fuera de Phase 2.

---

## §8 — Resumen ejecutivo

| Pieza                   | Estado actual | PR esperado |
|-------------------------|---------------|-------------|
| Atoms (7 + reuse)       | ✅ mig 00264   | done        |
| Shape catalog           | ❌ pendiente   | PR-1        |
| Cron no-check-in        | ❌ pendiente   | PR-2        |
| Engine evaluators       | ❌ pendiente   | PR-3        |
| Template seeds          | ❌ pendiente   | PR-4        |
| iOS humanLabels         | ❌ pendiente   | PR-1+3      |

**Total estimado:** 4 PRs (~12-16h de trabajo) para ship los 7 templates canónicos. Atoms ya están listos — todo el trabajo restante son shape + engine + iOS surface.
