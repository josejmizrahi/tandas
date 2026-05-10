## Atom / Projection — naming + structural rule

> Status: **canónico desde 2026-05-09**. Rule de architecture review;
> nuevos commits que violen el patrón se bloquean en revisión.
> Cierra Gap 4 del audit de primitives L1.

---

## Por qué este doc existe

Plans/Active/Primitives.md § 1 nombró el patrón Atom/Projection como
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

Conformancias futuras (cuando los tipos existan en código):

| Tipo Swift | Protocol | SQL |
|---|---|---|
| `LedgerEntry` (Phase 3) | `Atom` | `public.ledger_entries` |
| `Contribution` (Phase 3) | `Atom` | `public.contributions` |
| `Payout` (Phase 3) | `Atom` | `public.payouts` |
| `Booking` (Phase 2) | `Atom` | `public.bookings` |
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
| `public.system_events` | Atom | append-only, source of truth |
| `public.vote_casts` | Atom | one ballot per member per vote |
| `public.vote_ballots` | Atom (legacy) | reemplazada por vote_casts post-mig 00020 |
| `public.events` | Atom-ish | `closed_at` muta una vez al cierre. OK por ser estado terminal. |
| `public.events_view` | Projection | resolución de recurrencia + RSVP join |
| `public.group_members` | Atom-ish | `active`, `joined_at` mutables; ok porque transición es one-way |
| `public.group_members_with_founder` | Projection | join con `groups.created_by` |
| `public.invites` | Atom-ish | `used_at` mutable terminal |
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

## Trigger anti-mutation (futuro, opcional)

Una capa adicional para tablas que conformen `Atom` server-side
sería un `BEFORE UPDATE` trigger que rechaza UPDATEs que toquen
business columns:

```sql
create function public.atom_no_mutation_guard() returns trigger ...
do $$ begin
  raise exception 'atom row % is append-only; UPDATE rejected', new.id;
end $$;
```

Documentado pero **no implementado todavía**. Ejecutar cuando
llegue el primer atom nuevo (probablemente `LedgerEntry` en
Phase 3).

---

## Cuándo modificar este documento

- Cuando un tipo nuevo se añada y haga falta clasificarlo (Phase 2+).
- Cuando se descubra que un tipo clasificado como instrument o
  config debería ser atom/projection.
- Cuando el trigger anti-mutation se materialice — actualizar la
  sección "Trigger anti-mutation" con el shape real.

**No se modifica** por sprints o tareas — eso vive en
`Plans/Active/Roadmap.md` o ADRs.

---

## Referencias cruzadas

- `Plans/Active/Primitives.md` § 1 — patrón base.
- `Plans/Active/Phase2Readiness.md` — primitives ready for Phase 2.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/AtomProjection.swift` —
  marker protocols.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEvent.swift` —
  primer conformance.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/VoteCast.swift` —
  segundo conformance.
