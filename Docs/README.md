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

As of now, these are considered core canonical references.

## Vision

- `Docs/Vision.md`
- `Docs/Ruul-Social-Primitives-and-Product-Logic.md`

## Architecture

- `Plans/Pre-Phase2-Architecture-Consolidation-Plan.md`
- `Plans/Audit-2026-05-06.md`

---

# 7. Immediate Cleanup Targets

The following types of documents should be archived or rewritten:

- GroupType-driven docs;
- event-centric-only architecture docs;
- duplicated roadmap docs;
- hardcoded template docs;
- docs that treat `resources` as future instead of canonical;
- docs that model verticals as separate apps.

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
