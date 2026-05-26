# Human Layer Simplification — 2026-05-18

**Status:** Doctrine + implementation plan. UX-only pass. Compatible with the 2026-05-17 Consistency Audit freeze (no new primitives, types, capabilities, or backend changes — exposure changes only).

**Scope guard:** This document does NOT modify the ontology, the resource type canon, the capability catalog, the rule engine, the governance hierarchy, atoms/projections, or the ledger. It modifies labels, navigation grouping, toolbar partitioning, and creation/edit flow scope only.

**Canonical citation:** [[project_vision_canonical]] (Vision.md), [[project_resource_creation_redesign]], [[feedback_rules_ux_human]], [[project_universal_rule_templates]], [[project_consistency_audit_freeze]].

---

## 0. TL;DR

The architecture is solid. The ontology is canonical. The doctrine drift in the user-facing layer is **mostly contained**:

| Surface | Verdict | Action needed |
|---|---|---|
| Resource Creation (new coordinator) | ✅ Compliant | None — keep as primary, gate legacy wizard behind Advanced |
| Toolbar `+` / `⚙️` partition | ✅ Compliant | None |
| Resource Detail stubs / sections | ✅ Compliant | None |
| **Resource Detail tab structure** | ⚠️ 4 tabs, missing People + Money as first-class | **Promote People + Money; rename or fold Vínculos** |
| **Rule Composer copy** | ⚠️ Trigger / Y/O/NO jargon visible | **Rewrite 6 strings to plain Spanish** |
| Home screen labels | ⚠️ "Slots", "MEMORIA", PENDIENTES dup | **Rename 3 strings, disambiguate one section** |
| Governance permission labels | ⚠️ "Votación 2/3" / supermajority enum | **Friendly labels** |

Total surgical fixes: ~25 string changes, 1 tab restructure, 1 disambiguation. No ontology changes. No new screens.

---

## A. Human Layer Map

> What users see, do, and never need to learn.

### A.1 The five concepts (everything else is infrastructure)

| Human concept | Maps internally to | Where it lives in the UI |
|---|---|---|
| **Things** | Resources (event, fund, asset, space, slot, right) | Home feed, Resource Detail Overview tab, Create button |
| **People** | Members + roles + custody assignments | Resource Detail → People tab, Group → Members |
| **Money** | Fund balance, contributions, expenses, fines (paid/unpaid) | Resource Detail → Money tab, Group → Treasury |
| **Rules** | Rules + permissions + governance toggles | Resource Detail → Rules tab, Group → Acuerdos |
| **Activity** | History + system events + atoms | Resource Detail → Activity tab, Inbox, Home → Historial |

### A.2 What stays hidden

The user never needs to encounter — and our UX never names — these internal concepts:

`capability`, `projection`, `atom`, `rule shape`, `resource_type`, `ledger`, `trigger`, `consequence`, `governance hierarchy`, `governance scope`, `phase_target`, `module`, `intent` (the noun), `variant` (the noun), `link`, `vínculo`, `system event`, `precedence`, `dispatcher`, `policy`, `bounded context`, `domain event`.

### A.3 What humans can do (universal verbs)

Across every Thing, the user can: **invite**, **assign**, **transfer**, **track money**, **add a rule**, **see what happened**, **share**, **archive**. The full action vocabulary lives in `DefaultIntents.swift` and is already clean — protect it.

---

## B. UX Leak Audit

Consolidated from 5 parallel surface audits. Sorted by severity. File:line cited where applicable.

| # | Surface | Current text / behavior | Leak classification | Severity | Fix |
|---|---|---|---|---|---|
| 1 | `RuleComposerView.swift:180` | "Cuándo se **dispara**" | Ontology (trigger) | **HIGH** | "Cuándo sucede" |
| 2 | `RuleComposerView.swift:204` | "Elegir / Cambiar **disparador**" | Ontology (trigger) | **HIGH** | "Elegir / Cambiar cuándo" |
| 3 | `RuleComposerView.swift:215, 359, 385` | "Condiciones (Y / O / NO)", "Combinar como O", "Cambiar Y ⇄ O" | Architecture (boolean algebra) | **HIGH** | "Todas / Cualquiera / Ninguna"; "Cambiar: todos ↔ cualquiera" |
| 4 | `ResourceDetailTab.swift:14-44` | Tab "Vínculos" present; tabs "People" + "Money" absent | Ontology (resource_links graph) | **HIGH** | Promote People + Money to first-class tabs; rename Vínculos → "Relacionado" or fold into Overview when empty |
| 5 | `HomeView.swift:394` | "Aún no hay **slots**" empty-state | Ontology (resource_type leak) | **HIGH** | "Aún no hay turnos disponibles" — and tokenize via variant.humanName so slot→turno, slot→reserva, slot→cupo follows the resource's own copy |
| 6 | `HomeView.swift:540` | "MEMORIA DEL GRUPO" section header | Jargon (opaque metaphor) | **MED** | "Historial del grupo" |
| 7 | `HomeView.swift:476` + tab "Pendientes" | "PENDIENTES" home section + "Pendientes" tab — same label, different scope | Workflow (cognitive overlap) | **MED** | Home section → "Por hacer aquí" (this group); Tab stays "Pendientes" (all groups) |
| 8 | `GovernanceView.swift:233-239` | `supermajorityVote` / "Votación 2/3" enum surfaced literally | Architecture (enum leak) | **MED** | "Dos tercios de votos" — friendlier label table for all PermissionLevel cases |
| 9 | Multiple action labels include "Crear **slot** aquí" | Ontology (slot noun) | Low-Med | Defer (acceptable when slot has no friendlier vertical name; revisit if variant copy supplies one) |
| 10 | `ResourceTypeChrome` subtitles in feed ("Fondo", "Activo", "Derecho") | Ontology lite | LOW | Hide chrome subtitle in single-group view; show only in multi-group / cross-group contexts |
| 11 | Home Inbox tab label "Pendientes" | Mild jargon | LOW | Keep — "Pendientes" is colloquial enough, just disambiguate from item 7 |
| 12 | Stubs ("VOTACIÓN", "ASIGNACIÓN", "RECURRENCIA", etc.) | None | — | ✅ Already clean |
| 13 | Resource Creation wizard (new) | None | — | ✅ Already clean |
| 14 | Toolbar `+`/`⚙️` split | None | — | ✅ Already clean |
| 15 | Rule template gallery names | None observed | — | ✅ Already universal (post-audit close) |

**Categories represented:** ontology (×6), architecture (×3), jargon (×2), workflow (×1), governance internals (×1).

**Coverage:** Auto-detected forbidden vocab `(capability|projection|atom|shape|event_type|phase_target|scope|module|intent|variant)` does NOT appear in user-facing strings outside the 4 high-severity items above. The architecture audit close (2026-05-14) already cleaned the deepest leaks.

---

## C. Navigation Simplification Plan

### C.1 Resource Detail: converge to the universal 5-tab structure

**Current** (`ResourceDetailTab.swift:14-44`): General · Actividad · Reglas · Vínculos
**Target:** Overview · People · Money · Rules · Activity (5 universal) + optional contextual (Schedule, Access, Usage, History) shown only when the corresponding capabilities are attached and have non-empty content.

| Move | From | To | Why |
|---|---|---|---|
| Promote | People section (currently inside Overview when assignment/custody/RSVP cap attached) | First-class tab "Gente" | Doctrine A.1 — People is one of the 5 human concepts |
| Promote | Money section (currently inside Overview when fund/expense/fine cap attached) | First-class tab "Dinero" | Doctrine A.1 — Money is one of the 5 human concepts |
| Rename or fold | Tab "Vínculos" | Option A: rename to "Relacionado"; Option B: fold into Overview as a "Relacionado" section, hide tab when count = 0 | "Vínculo" = graph-model leak; humans say "qué está conectado con esto" |
| Keep | Tab "General" | Overview (Spanish: "General" is fine, "Resumen" alternative) | Canonical #1 |
| Keep | Tab "Reglas" | Rules | Canonical #4 |
| Keep | Tab "Actividad" | Activity | Canonical #5 |

**Tab visibility rule:** Each tab renders only if it has at least one section to show. People/Money tabs disappear silently for resources with no capability driving them (e.g. a pure Space with no assignments and no fund). Same gating model that already governs stubs.

**Out of scope this pass:** Adding Schedule / Access / Usage / History tabs. They surface as Overview sections today; promote only when at least two sections exist on the same domain (revisit post-Beta 1).

### C.2 Home: kill the three home-screen leaks

| Action | Surface | Change |
|---|---|---|
| Rename | `HomeView.swift:540` | `MEMORIA DEL GRUPO` → `Historial del grupo` |
| Rename | `HomeView.swift:476` | Home section `PENDIENTES` → `Por hacer aquí` (or `Tu turno` when the items are all addressed to you) |
| Tokenize | `HomeView.swift:394` empty state | Replace literal "Aún no hay slots" with copy driven by `variant.humanName` for the dominant resource type in the current group |
| Defer | Resource type chrome subtitle | Hide in single-group view; show in multi-group/cross-group lists only |
| Memory stat | `decisiones tomadas` | `Acuerdos alcanzados` (also less judgmental copy) |

### C.3 Rule Composer: replace the 6 jargon strings

| File:line | Old | New |
|---|---|---|
| `RuleComposerView.swift:180` | "Cuándo se dispara" | "Cuándo sucede" |
| `RuleComposerView.swift:204` | "Elegir disparador" / "Cambiar disparador" | "Elegir cuándo" / "Cambiar cuándo" |
| `RuleComposerView.swift:215` | "Condiciones (Y / O / NO)" | "Condiciones (todas / cualquiera / ninguna)" |
| `RuleComposerView.swift:359` | "Combinar con siguiente como O" | "Combinar con siguiente (cualquiera)" |
| `RuleComposerView.swift:385` | "Cambiar Y ⇄ O" | "Cambiar: todos ↔ cualquiera" |
| `RuleComposerView.swift:403` | "Excepto si (cualquiera bloquea)" | "Excepto cuando…" |

Behavior unchanged. Just relabel. Conditions panel stays available only to founders / power users (no change to gating).

### C.4 Governance: friendlier permission level labels

`PermissionLevel` enum keys stay (founder / anyMember / majorityVote / supermajorityVote). Add a `displayLabel` mapping in the view layer:

| Enum | Display |
|---|---|
| `founder` | "Solo el fundador" |
| `anyMember` | "Cualquier miembro" |
| `majorityVote` | "Mayoría simple (más de la mitad)" |
| `supermajorityVote` | "Dos tercios" |

No backend change. No rule engine change.

### C.5 Settings discoverability (no structural change)

`⚙️` already holds the right items (Editar / Archivar). Two additions over the next pass — both hidden behind ⚙️, not promoted to `+`:

- Legacy `ResourceWizardCoordinator` (the old multi-step wizard) → `⚙️ → Avanzado → Editor de plantilla`. Already correctly gated; document the gate.
- Permissions / roles edit (currently in Group → Governance) → reachable from any Resource Detail's `⚙️ → Permisos` as a shortcut. No new surface — just a deep link.

### C.6 What we are explicitly NOT doing

- Not removing tabs the user already relies on for navigation history.
- Not adding new resource types, capabilities, intents, variants, or rule templates (Consistency Audit freeze in force).
- Not changing the wizard (already compliant).
- Not touching the toolbar split (already compliant).
- Not removing the rule composer's advanced conditions panel — only relabeling.

---

## D. Vocabulary Replacement Table

Single source of truth. Lint candidate (forbid these substrings in user-facing copy, allow in `*.internal.swift` / comments / file names).

| Internal term | Human replacement | Notes |
|---|---|---|
| capability | (do not surface) | Hidden behind intents and contextual sections |
| capability dependency | (do not surface) | Resolved silently by silent-attach |
| projection | actividad / historial | Context-dependent |
| atom | (do not surface) | Pure infrastructure |
| rule shape | patrón (when referring to a template family) | Only in advanced contexts |
| resource_type | tipo de cosa / cosa (or use variant.humanName) | Never expose the snake_case |
| ledger | movimientos / historial de dinero | "Ledger" never in UI |
| trigger / triggered | cuándo / sucede | See Rule Composer fixes |
| consequence | qué pasa / resultado | |
| governance hierarchy | quién decide qué | |
| governance scope | dónde aplica | "Aplica a:" copy is OK; the word "scope" is not |
| phase_target | (do not surface) | Engine concept only |
| module | (do not surface) | Resolved as silent capability set per variant |
| intent (noun) | acción (verb form: "qué quieres hacer") | "Intent" is internal; user sees verbs |
| variant (noun) | tipo (use `variant.humanName` directly) | "Variant" is internal |
| link / vínculo | relacionado / conectado con | Tab + section rename per C.1 |
| event_type | (do not surface) | |
| system event | actividad reciente | When unavoidable, prefer "qué sucedió" |
| precedence | (do not surface) | Resolved silently |
| dispatcher | (do not surface) | |
| slot (raw) | turno / reserva / cupo (via variant.humanName) | Per group / variant choice |
| supermajorityVote | "dos tercios" | Per C.4 |
| memoria (jargon use) | historial | Per C.2 |
| pendientes (when ambiguous) | por hacer aquí / tu turno | Per C.2 |
| decisiones tomadas | acuerdos alcanzados | Per C.2 |

### Build-time enforcement (recommended, deferred to consolidation slice)

Add a Lefthook / CI lint that fails when any `.swift` file under `RuulFeatures` contains forbidden substrings inside `String` literals tagged with `// user-facing` or surfaced via `LocalizedStringKey`. Whitelist comments, file paths, identifiers, internal API names.

---

## E. Frontend Doctrine (canonical)

> **The user coordinates real things. Ruul handles the infrastructure.**
>
> **The ontology is the engine. The human layer is the product.**

### E.1 The five concepts the user is allowed to see

Things · People · Money · Rules · Activity. Everything else is named infrastructure and lives below the waterline.

### E.2 Surface invariants

1. **Universal Resource Detail.** 5 canonical tabs (Overview · People · Money · Rules · Activity), gated by content. Optional contextual tabs (Schedule · Access · Usage · History) appear only when at least two sections of that domain exist. Never any tab named after an internal concept.
2. **Toolbar split.** `[X] Title [+] [⚙️]`. `+` = human verbs only. `⚙️` = configuration only. Infrastructure lives behind ⚙️ with friction (and ideally behind ⚙️ → Avanzado).
3. **Creation flow.** Type → Variant → Minimal identity → Create → "¿Qué quieres hacer ahora?" (intents). No capability, rule, or governance setup during creation. Advanced stays reachable later.
4. **Capability invisibility.** User expresses intent → system silently attaches capabilities. No `Enable capability` toggle in primary UX. Capability management exists only in Governance → Advanced (founder).
5. **Rules in plain language.** "Cuándo sucede X → pasa Y". No `trigger`, `consequence`, `shape`, `atom`, `event_type`, `phase_target` in any user-visible string.
6. **Vocabulary discipline.** Forbidden term list (Section D) is enforced. Internal names stay in code, file names, comments, and engineering docs.

### E.3 Behavioral guarantees the doctrine preserves

- Ontology canon ([[project_ontology_constitution]]): unchanged.
- 6 resource types: unchanged.
- Universal rule templates ([[project_universal_rule_templates]]): unchanged; remain universal social patterns.
- Atom / Projection separation ([[project_constitution_audit]]): unchanged.
- Append-only ledger discipline: unchanged.
- Rule engine determinism ([[project_consistency_audit_freeze]]): unchanged.
- Governance hierarchy + scope precedence: unchanged behaviorally; only labels change.

### E.4 The 3-minute test (acceptance criterion)

A non-technical human, opening Ruul for the first time with no onboarding, should within 3 minutes be able to:

1. Understand what the app does (manage real things together with people).
2. Create a thing.
3. Invite people to it.
4. Track money on it.
5. Add at least one simple rule ("Si pasa X → entonces Y").
6. See what happened.

…without ever encountering, asking about, or needing to learn: capabilities, variants, projections, atoms, modules, rule shapes, governance hierarchy, ledger semantics, scope precedence, or any other internal concept.

### E.5 What this doctrine does NOT do

- Does not weaken governance.
- Does not bypass the rule engine.
- Does not remove advanced surfaces — pushes them behind ⚙️ → Avanzado with friction.
- Does not collapse resource types — they remain canonical internally; humans see them via `variant.humanName`.
- Does not lock founders out of power-user editing — the legacy wizard, raw rule editor, and capability inspector remain reachable for advanced sessions.

---

## F. Execution sequencing (small slices, each freeze-compatible)

All slices are UX-only. None touches schema, capabilities, rule engine, or ontology. All ship as label / structural changes inside `RuulFeatures` + `RuulUI` only.

**Slicing rule (founder, 2026-05-18):** **One cognitive decision per slice.** Never combine "rename A + add B + restructure C" in a single cut — that compounds disorientation and snapshot churn. Each slice ships, gets smoke-validated in simulator (Home / Rule Composer / Governance / Check-in / Resource Detail per resource type), and only then does the next slice start.

### Slice 1 — String fixes (shipped, 1 commit, ~25 strings)

- Rule Composer: 10 strings per C.3
- Home: 4 user-facing strings + 1 doc comment per C.2
- Governance permission labels: per C.4 (short forms for segmented picker)
- CheckInMethod.hostMarked English label fix (cross-package consistency with Governance)
- Acceptance: build + non-snapshot tests green; pre-existing `PrimitiveSnapshotTests` drift unrelated and pre-dates this slice (verified by stash-and-rerun on HEAD)

### Slice 2 — Resource Detail tab restructure (sub-sliced)

Split into 3 sub-slices to honor the "one cognitive decision per slice" rule. The original 4→5-tab + Money + Links restructure as a single cut would have churned every resource detail snapshot and re-oriented the user across two unrelated mental shifts at once.

#### Slice 2A — People as first-class tab (next)

- Add `.people` case to `ResourceDetailTab` only (no `.money`, no `.connections` change)
- Route people-domain capability-driven sections (custody, assignment, RSVP, host) to the new tab; sections without people content keep their current placement
- Tab visibility: render only when at least one section routes here
- Snapshot tests per resource type: confirm sections appear under People when their gating capability attaches
- Acceptance: every resource type still shows all current sections; people-related sections move tab; no other tab changes

#### Slice 2B — Money as first-class tab (after 2A ships + validates)

- Add `.money` case to `ResourceDetailTab`
- Route money-domain sections (fund balance, contributions, expenses, fines, valuation) to the new tab
- Same gating + snapshot discipline as 2A
- Acceptance: money sections move tab; people and rules stay where 2A left them

#### Slice 2C — Vínculos rename or fold (after 2B ships + validates)

- Decision between Option A (rename `.connections` → "Relacionado") and Option B (fold into Overview when empty, hide tab) — defer until 2A + 2B reveal what the tab actually looks like with the People + Money tabs in place
- Single string + visibility predicate change, no section routing changes
- Acceptance: tab name (or absence) is the only diff

### Slice 3 — Vocabulary lint + memory write (after Slice 2 series ships)

- Add Lefthook check for forbidden substrings in user-facing strings (whitelist comments, identifiers, file paths)
- Add `Plans/Active/HumanLayerSimplification.md` reference to MEMORY.md (shipped with Slice 1)
- Acceptance: lint passes on current codebase post-Slice 1 + 2A/2B/2C

### Out of scope this track (revisit post-Beta 1)

- Schedule / Access / Usage / History contextual tabs
- Multi-group cross-resource view chrome
- Rule template gallery copy refresh (already universal; cosmetic pass only)
- Onboarding rewrite to land the "3-minute test"

---

## G. Compliance check against the brief

| Brief constraint | Status |
|---|---|
| Do NOT redesign ontology | ✅ Untouched |
| Do NOT add new resource types | ✅ Untouched |
| Do NOT rewrite backend | ✅ Untouched |
| Do NOT remove atoms / projections / rules | ✅ Untouched |
| Do NOT weaken governance | ✅ Labels only |
| ONLY: cognitive simplification | ✅ |
| ONLY: navigation stabilization | ✅ C.1, C.2 |
| ONLY: UX humanization | ✅ D, C.3, C.4 |
| ONLY: infrastructure concealment | ✅ E.2 #4, F Slice 3 lint |

Compatible with Consistency Audit freeze ([[project_consistency_audit_freeze]]) — no new primitives / types / capabilities / features. Truth>Projection>Cache>UI invariants intact.
