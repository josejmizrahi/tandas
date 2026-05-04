# Design System — Deferred Components

Sprint 0 (DS adjustments) ships only the primitives V1 actually consumes.
The components below are reserved for later phases; documented here so
the architecture knows about them and we don't accidentally build
duplicates when each phase lands.

## Deferred — Fase 4 (custom rule editor)

These primitives are part of the visual rule-builder UI. Not needed
until end-users can compose their own rules; in V1 (Cena recurrente)
the rules are pre-defined at template install time so no editor is
required.

| Primitive | Purpose | Notes |
|---|---|---|
| `RuulRuleBuilder` | Top-level canvas for assembling WHEN/IF/THEN rules visually | Full-screen editor host. Likely uses Layout protocol for non-rectangular flow. |
| `RuulEventChip` | Trigger event selector chip ("RSVP submitted", "Event closed") | Each `SystemEventType` gets a chip with icon. Probably composable from existing `RuulChip`. |
| `RuulConditionRow` | Editable condition row ("if amount > $500") | Type picker + operand picker + value input. Inline-editable. |
| `RuulConsequenceCard` | Card representing a consequence ("Generate fine $200") | One per `ConsequenceType`. |
| `RuulFlowConnector` | Animated arrow between trigger → conditions → consequences | Path-based, supports horizontal + vertical layouts. |
| `RulePreviewSheet` | Sheet that simulates a rule against real recent events | "Esta regla se habría disparado 3 veces en el último mes". |

## Deferred — Fase 2 (template "Recurso compartido")

| Primitive | Purpose | Notes |
|---|---|---|
| `RuulSlotCard` | Card representing an assignable slot (boleto, cupo, lugar) | Shows occupant + cycle position. |
| `RuulRotationVisualizer` | Circular or linear visualization of rotation order | "Tu turno es el 4 de 8". |

## Deferred — Fase posterior

| Primitive | Purpose | Notes |
|---|---|---|
| `RuulHealthIndicator` | Multi-segment "group health" bar | Composes attendance / payment / participation into one signal. |
| `GroupHealthDashboard` (pattern) | Full dashboard view stitching `RuulMetricCard` + `RuulHealthIndicator` + history | Owns the "is this group healthy?" question. |
| `HistoryTimelineView` (pattern, full) | Searchable + filterable timeline | V1 ships a minimal version using `RuulTimelineItem` directly in a `ScrollView`. |
| `SystemEventBadge` | Inline badge that surfaces a system-event type tag | Optional in V1 — used only if inbox/timeline rows benefit. Decide per-feature. |

## Convention reminders for future builders

- Always start from existing primitives (`RuulCard`, `RuulButton`,
  `RuulChip`, etc.) before introducing a new one. Adding variants is
  preferred over net-new types.
- Apple Sports / Luma flat monochrome rule still applies: status comes
  from a colored 8pt dot + uppercase tracked label, never a tinted
  background fill in chrome surfaces.
- Use `RuulTypography.sectionLabel` / `sectionLabelLg` for tracked
  uppercase text and `statSmall` / `statMedium` / `statHero` for
  numerals — never hand-roll `.font(.system(size:design:.monospaced))`.
- Use `RuulSpacing.sN` tokens, not magic numbers.
- Every primitive ships with `#if DEBUG #Preview` and an
  `accessibilityLabel`.
