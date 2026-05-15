## Atom / Projection — naming + structural rule

> Status: **canónico desde 2026-05-09**. Rule de architecture review;
> nuevos commits que violen el patrón se bloquean en revisión.
> Cierra Gap 4 del audit de primitives L1.

---

## Por qué este doc existe

Plans/Completed/Primitives.md § 1 nombró el patrón Atom/Projection como
canónico — varias primitives existentes ya lo siguen
(`system_events` → History, `vote_casts` → `vote_counts_view`,
`events` → `events_view`, etc.). Pero **ningún tipo Swift ni
declaración SQL identifica explícitamente cuál es cuál**.

Cuando lleguen Phase 3 (`Fund` / `LedgerEntry` / `Balance`) y
Phase 4 (`Expense` / `Settlement`), la tentación va a ser modelar
`balance_per_member` como tabla mutable que se incrementa cada
contribución. Eso rompe la promesa Atom/Projection y mata la
auditabilidad del Ledger.

Este doc fija la regla y los marker protocols Swift que la hacen
explícita.

---

## La regla

### Atom

Un **Atom** es un append-only authoritative record de un hecho que
ocurrió:

- Persistido en una tabla SQL **sin UPDATE trigger que mute
  business fields**. Append-only.
- Se escribe vía `record_*` SECURITY DEFINER functions O triggers
  desde otros writes — nunca por user CRUD directo.
- `id` y `created_at` (o `occurred_at`) son inmutables.
- Cero side-effects fuera del log.

**Si el dato puede recomputarse desde otros datos, NO es atom — es
projection.**

### Projection

Una **Projection** es una derived read-side view de uno o más
atoms:

- Persistida como SQL view, materialized view, o computed at read.
- **Nunca** una tabla mutable que se actualiza independientemente
  del atom.
- Stale or missing projection → recoverable. Re-running la
  proyección contra el atom es el canonical recovery path.
- Mutaciones aterrizan en el atom; la projection actualiza
  reactivamente o on next read.

---

## Marker protocols (iOS)

```swift
public protocol Atom: Sendable, Codable, Identifiable {
    static var atomTableName: String { get }
}

public protocol Projection: Sendable, Codable {
    static var projectionViewName: String { get }
}
```

Definidos en
`ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/AtomProjection.swift`.

---

## Conformancias actuales

| Tipo Swift | Protocol | SQL |
|---|---|---|
| `SystemEvent` | `Atom` | `public.system_events` |
| `VoteCast` | `Atom` | `public.vote_casts` |
| `LedgerEntry` | `Atom` | `public.ledger_entries` |
| `RsvpAction` | `Atom` | `public.rsvp_actions` |
| `Booking` (mig 00216) | `Atom` | `public.bookings` |
| `Fund` (mig 00202) | `Projection` | `public.fund_balance_view` |

Conformancias futuras (cuando los tipos existan en código):

| Tipo Swift | Protocol | SQL |
|---|---|---|
| `Contribution` (Phase 3) | `Atom` | `public.contributions` |
| `Payout` (Phase 3) | `Atom` | `public.payouts` |
| `Balance` (Phase 3) | `Projection` | `public.balances_view` |
| `AttendanceSummary` | `Projection` | `public.attendance_view` |
| `History` | `Projection` | computed from `system_events` |

---

## Lo que NO es atom (instrumentos derivados)

Per Primitives.md § 6:

```
Rule(threshold)         + Resource = Vote
Rule(THEN consequence)  + Member   = Fine
Rule(THEN consequence)  + Member   = Sanction (futuro)
Rule(THEN reward)       + Member   = Badge (futuro)
```

`Vote` y `Fine` son instruments — Rules + Resources + Members
materializadas en decisiones y consequences. Tienen estado
mutable (`Fine.paid`, `Fine.waived`, `Vote.status`) y por eso no
son atoms.

Si llega Sanction/Badge/Reward en Phase 5+, **NO crear
`sanctions`/`badges`/`rewards` tables paralelas** — el patrón
correcto es `Consequence` polymórfica (`consequence_type`: fine,
sanction, badge, reward) con la misma forma derivada.

---

## Tablas existentes — clasificación

| Tabla / view | Tipo | Notas |
|---|---|---|
| `public.system_events` | Atom | append-only, source of truth. Guarded by `system_events_atom_guard` (mig 00162) — partial guard: business columns rejected; only the one-way `processed_at: null → ts` transition allowed for the rule-engine cron. |
| `public.vote_casts` | Atom | append-only post-mig 00163. Every cast inserts a new row; latest-per-(vote, member) wins in `vote_counts_view` + `finalize_vote`. Guarded by `vote_casts_atom_guard` (BEFORE UPDATE OR DELETE). |
| `public.vote_ballots` | Atom (legacy) | reemplazada por vote_casts post-mig 00020 |
| `public.events` | dropped | mig 00159 — events live as `resources WHERE resource_type='event'` |
| `public.events_view` | Projection | drop-in compatible view sobre `resources.metadata` |
| `public.group_members` | Atom-ish | `active`, `joined_at` mutables; ok porque transición es one-way |
| `public.group_members_with_founder` | Projection | join con `groups.created_by` |
| `public.invites` | Atom-ish | `used_at` mutable terminal |
| `public.user_actions` | Atom-ish | `resolved_at` mutable terminal (null → ts). Guarded by `user_actions_resolution_guard` (mig 00166) — rejects DELETE and any business-column mutation; allows only the one-way resolution flip. Constitution Article 8 reclassification (2026-05-14): not a projection, despite the original §8 example list. |
| `public.invite_preview` | Projection | view sobre invites |
| `public.fines` | Instrument | mutable status, no atom |
| `public.votes` | Instrument | mutable status, no atom |
| `public.rules` | Configuration | mutable, ni atom ni projection |
| `public.modules` | Configuration | catalog seeded by mig 00060 |
| `public.templates` | Configuration | jsonb config |

---

## Convención SQL (forward-only)

Para tablas nuevas:
- **Atom**: nombre singular o tabular sin sufijo (`ledger_entries`,
  `contributions`, `bookings`).
- **Projection**: sufijo `_view` (`balances_view`,
  `attendance_view`).
- **Configuration** (no atom ni projection): nombre directo
  (`modules`, `templates`).

Tablas existentes que rompen la convención **no se renombran** —
demasiada superficie afectada (RLS policies, RPCs, edge functions).
La convención es forward-only.

---

## Trigger anti-mutation (implementado)

`public.atom_no_mutation_guard()` (mig 00103) — BEFORE UPDATE OR
DELETE → raise `check_violation`. Cobertura actual:

| Atom | Guard | Migration |
|---|---|---|
| `public.ledger_entries` | `ledger_entries_atom_guard` | 00103 |
| `public.rsvp_actions` | `rsvp_actions_atom_guard` | 00103 |
| `public.check_in_actions` | `check_in_actions_atom_guard` | 00154 |
| `public.system_events` | `system_events_atom_guard` (partial) | 00162 |
| `public.vote_casts` | `vote_casts_atom_guard` | 00163 |
| `public.user_actions` | `user_actions_resolution_guard` (partial, Atom-ish) | 00166 |
| `public.bookings` | `bookings_atom_guard` | 00216 |

`system_events` uses a **partial guard** (`system_events_processed_at_only_guard`)
that allows the single legitimate mutation — `processed_at: null →
timestamp` by the rule-engine cron. Every other column is locked, and
DELETE is always rejected. Any future column added to `system_events`
is automatically protected because the guard compares
`to_jsonb(old) - 'processed_at'` against the same on `new` — fails
closed.

`vote_casts` switched to a fully append-only pattern in mig 00163
(Constitution audit Gap 2): start_vote still pre-seeds `pending`
rows, but cast_vote INSERT-s a new row each time and
`vote_counts_view` / `finalize_vote` fold to latest-per-(vote, member).
Re-cast supported by inserting another row.

All 5 canonical atoms listed in Constitution §7 are now DB-enforced
append-only as of 2026-05-14.

---

## Cuándo modificar este documento

- Cuando un tipo nuevo se añada y haga falta clasificarlo (Phase 2+).
- Cuando se descubra que un tipo clasificado como instrument o
  config debería ser atom/projection.
- Cuando el trigger anti-mutation se materialice — actualizar la
  sección "Trigger anti-mutation" con el shape real.

**No se modifica** por sprints o tareas — eso vive en
`Plans/Archive/Roadmap.md` o ADRs.

---

## Referencias cruzadas

- `Plans/Completed/Primitives.md` § 1 — patrón base.
- `Plans/Completed/Phase2Readiness.md` — primitives ready for Phase 2.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/AtomProjection.swift` —
  marker protocols.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEvent.swift` —
  primer conformance.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/VoteCast.swift` —
  segundo conformance.
