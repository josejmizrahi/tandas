# Ruul Documentation System

> Canonical documentation structure for Ruul.
>
> Goal:
>
> - eliminate contradictory architecture docs;
> - prevent resurrection of legacy event-centric assumptions;
> - keep AI-assisted development consistent;
> - create a single source of truth for product + architecture.

---

# 1. Core Principle

Ruul is no longer:

```text
an event app with governance features
```

Ruul is:

```text
infrastructure for recurring self-governed groups
```

Canonical architecture:

```text
Template
→ Group
→ Resource
→ Rule
→ Vote
→ Fine
→ History
```

All new documentation must align with this model.

---

# 2. Canonical Documentation Areas

## Docs/Vision/

High-level product philosophy and long-term direction.

Contains:

- social primitives;
- recurring group thesis;
- governance philosophy;
- roadmap;
- product north star;
- universal group model.

These docs answer:

```text
Why does Ruul exist?
Where is it going?
```

---

## Docs/Architecture/

Technical architecture source of truth.

Contains:

- resource model;
- templates-as-data;
- voting system;
- fines;
- history;
- event system;
- data ownership;
- backend architecture.

These docs answer:

```text
How does Ruul actually work?
```

---

## Docs/Product/

Concrete product behavior.

Contains:

- templates;
- UX;
- onboarding;
- notification strategy;
- Beta learnings;
- user flows.

These docs answer:

```text
What does the user experience?
```

---

## Plans/Active/

Current execution plans.

Only active workstreams belong here.

Examples:

- architecture consolidation;
- Beta execution;
- current phase implementation.

---

## Plans/Completed/

Historical execution plans already finished.

Examples:

- Sprint0;
- Phase1;
- previous audits.

---

## Docs/Archive/

Deprecated or historical material.

Nothing here should be considered canonical.

This exists to preserve:

- historical decisions;
- previous assumptions;
- migration context;
- lessons learned.

---

# 3. Deprecated Concepts

The following concepts are deprecated and should not be used as primary architecture going forward.

---

## GroupType-centric architecture

Deprecated:

```text
GroupType enum drives behavior
```

Canonical replacement:

```text
Template-as-data
```

Meaning:

- `base_template` becomes canonical;
- templates define rules/modules/presentation;
- new verticals are template compositions.

---

## Event-centric architecture

Deprecated:

```text
Everything important is an Event
```

Canonical replacement:

```text
Everything governable is a Resource
```

Examples:

- Event;
- Slot;
- Rotation;
- Assignment;
- Fund;
- Booking;
- Proposal.

---

## Event-only fines

Deprecated:

```text
fine.event_id
```

Canonical replacement:

```text
fine.resource_id
```

This enables:

- rotation violations;
- late payments;
- slot violations;
- fund violations;
- asset governance.

---

## Display strings as rule identity

Deprecated:

```text
"Late arrival"
```

Canonical replacement:

```text
late_arrival
```

using stable rule slugs.

---

# 4. Documentation Rules

## Rule 1 — No duplicate truth

Every concept must have ONE canonical document.

Avoid:

- duplicate architecture explanations;
- conflicting roadmap documents;
- multiple definitions of the same primitive.

---

## Rule 2 — Archive instead of delete first

Before deleting old docs:

1. move to `Docs/Archive/`;
2. verify no active references remain;
3. only then consider deletion.

---

## Rule 3 — No new docs around deprecated architecture

Do not create new documents that assume:

- GroupType-driven architecture;
- event-only governance;
- hardcoded template logic;
- vertical-specific apps.

---

## Rule 4 — Resources are first-class

All future primitives should be explainable through:

```text
resource lifecycle
```

If a feature cannot be mapped to resources/templates/governance, rethink the abstraction.

---

## Rule 5 — Plans are temporary

Plans are not architecture.

Once finished:

```text
Plans/Completed/
```

Only active execution belongs in `Plans/Active/`.

---

# 5. Recommended File Structure

```text
Docs/
├── README.md
│
├── Vision/
├── Architecture/
├── Product/
├── Engineering/
└── Archive/

Plans/
├── Active/
├── Completed/
└── Archive/
```

---

# 6. Current Canonical Documents

As of 2026-05-07 (post-consolidación pre-Fase 2), these are the
canonical references.

## Vision / strategy

- `docs/Ruul-Social-Primitives-and-Product-Logic.md` — primitives, 130
  group categories, product logic.

## Architecture (canonical, "how it works")

- `docs/Platform.md` — 7 primary citizens (Group, Member, Resource,
  Rule, SystemEvent, Action, Vote) + dataflow.
- `docs/Governance.md` — `groups.governance` jsonb model + per-action
  permission checks via `GovernanceService`.
- `docs/TemplateGuide.md` — templates as data, not code.
- `docs/ModuleGuide.md` — composable modules, ModuleRegistry.
- `docs/RuleAuthoring.md` — WHEN/IF/THEN rule shape + composing
  triggers/conditions/consequences.
- `docs/EventTypes.md` — catalog of `SystemEventType`.
- `docs/ConditionTypes.md` — catalog of `ConditionType`.
- `docs/ConsequenceTypes.md` — catalog of `ConsequenceType`.

## Product / UX

- `docs/DesignSystem.md` (v3.0) — tokens, components, Liquid Glass
  patterns. Authoritative for any new UI.
- `docs/DesignPrinciples.md` — what "Apple-grade" means for ruul.
- `docs/UXAudit.md` — 2026-05-04 snapshot of every surface (some
  references are pre-Resource-centric — read with that lens).

## Active plans

- `Plans/Active/Roadmap.md` — north star, the 6 phases.
- `Plans/Completed/Audit-2026-05-06.md` — post-F0 audit, items §5.3
  fully closed at 2026-05-07.
- `Plans/Active/Beta1.md` — current cycle: real-cena observation
  period, journal template, freeze rules.
- `Plans/Completed/Phase0-DSv3-Migration-2026-05-07.md` — DS migration
  in progress in parallel session.
- `Plans/Active/SystemEventsArchival.md` — deferred plan for pre-Fase 4.
- `Plans/Active/GroupTypeRemoval.md` — follow-up to audit §7c.
- `Plans/Completed/AnonAuthUpgradeGap.md` — open backlog.
- `Plans/Completed/DSFutureComponents.md` — DS deferred items.

## Historical (non-canonical, kept for context)

- `Plans/Completed/` — every executed plan (Phase 1, F0 sprints,
  V1 layers, audits).
- `Plans/Archive/` — superseded docs (Roadmap followups, V1 DS spec).
- `docs/Archive/` — placeholder for legacy doc moves (none yet —
  current `docs/*.md` are aligned with Resource-centric model).

> **Note on path references in older docs**: docs written pre-2026-05-07
> may reference plans by their old flat path (`Plans/Phase1.md`,
> `Plans/Audit-2026-05-06.md`, etc.). After the 2026-05-07 reorg, those
> files now live under `Plans/Active|Completed|Archive/`. The basename
> is unchanged — if a doc says `Plans/X.md`, look in
> `Plans/Active/X.md` or `Plans/Completed/X.md`.

---

# 7. Beta 1 freeze (2026-05-07 → exit)

Architecture is **frozen** while Beta 1 runs. See
`Plans/Active/Beta1.md` for:

- the cena journal template;
- what's allowed during Beta (bugs, polish, analytics);
- what's NOT allowed (new primitives, refactors, templates);
- exit criteria → Phase 2 decision.

No new structural docs during Beta 1 unless they describe a critical
bug fix or analytics scaffolding.

---

# 8. Philosophy

Ruul should evolve by:

```text
composing primitives
```

not by:

```text
creating isolated vertical products
```

The documentation system must reinforce this.
