# ruul — Design Principles

> What "Apple-grade" means for ruul, concretely. Every new view should
> pass these checks before merge. Existing views below the bar get
> queued for refactor.

The reference apps for our visual language:
- **Apple Invites** — hero covers, white-text overlays, vignettes, day-grouped lists
- **Apple Sports** — flat monochrome chrome, big numerals, uppercase tracked labels, status as colored dot + label (never full-tinted backgrounds in chrome)
- **Apple Wallet** — list rows with subtle thumbnail + monospace amount on the right
- **Luma** — empty states that read like a friend, copy-first design

---

## 1. The cover IS the card

Hero events / groups / fines render the cover (image OR procedural mesh) as
the **entire** card surface. Content overlays in white over a vignette.

DO:
```swift
ZStack(alignment: .bottomLeading) {
    cover.aspectRatio(16/11, contentMode: .fill)
    vignetteGradient
    topBadgesOverlay   // status pills
    bottomContentOverlay  // date + title + meta in white
}
.clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg))
```

DON'T:
- Cover as a small thumbnail on the side with white card body next to it
  (Wallet pattern is OK for compact list rows but never for hero).
- White cards on white background — kills hierarchy.
- Glass on content surfaces (glass is for floating chrome only).

Reference: `EventCard.swift` (Features/Events/Subviews/) is the gold
standard.

## 2. Two card densities only

For lists, we use TWO formats — never three:

**Hero card** (full cover, ~190pt tall): 1-2 per screen, the focus item.
Use for: next event in HomeView, "tu turno" in rotation views, the open
appeal awaiting your vote.

**Compact row** (cover thumb on left ~64x64, content right): scales to many
items per screen. Use for: feeds, history timeline, fines list.

The compact row is the workhorse. Define it once (`EventRow`,
`FineRow`, `HistoryRow`) and reuse across views.

## 3. Date language, not date strings

Every datetime in user-facing UI uses Apple's relative idioms:
- Today / today + time — "HOY · 9:00 PM"
- Tomorrow — "MAÑANA · 9:00 PM"
- This week — "JUE · 9:00 PM"
- Future — "JUE 12 MAR · 9:00 PM"
- Past — relative ("hace 3 días") in lists, absolute in detail

Helpers exist in `Date+EventFormatting.swift`:
- `.ruulShortTime`
- `.ruulShortDate`

DON'T use `DateFormatter` ad hoc with a custom format string. If a format
isn't covered by helpers, add a helper.

## 4. Status as colored dot + uppercase tracked label

Status indicators are 8pt color dots + tracked uppercase text. No tinted
background fills on chrome surfaces (only on overlays over images).

```swift
HStack(spacing: 6) {
    Circle().fill(.ruulSemanticSuccess).frame(width: 8, height: 8)
    Text("CONFIRMADO")
        .ruulTextStyle(RuulTypography.sectionLabel)  // tracked uppercase
        .foregroundStyle(.ruulTextPrimary)
}
```

Exception: pills overlaid on photo covers DO get full-color backgrounds
(white text on red/green capsule) so they read against any image.

## 5. Typography rhythm (no ad-hoc fonts)

Every text uses tokens. Hierarchy:
- `displayLarge` / `displayMedium` — hero titles (1 per screen)
- `title` / `headline` — section heads, card titles
- `body` — prose, list content
- `caption` — secondary info, metadata
- `sectionLabel` / `sectionLabelLg` — uppercase tracked labels
- `statHero` / `statMedium` / `statSmall` — numerals (Apple Sports pattern)

Never use `.font(.system(size: 18, weight: .medium))` directly. If you
need a new size/weight, add a token first.

## 6. Spacing on the 4pt grid only

All paddings/spacings: `RuulSpacing.s1` through `RuulSpacing.s12` (4–48pt).
No magic numbers like `padding(7)`.

## 7. Motion is mandatory, but subtle

Every state change should animate. Use the existing animation tokens:
- `.ruulSnappy` — for state toggles, focus changes
- `.ruulMorph` — for layout swaps (e.g. step transitions)
- `.spring(...)` only for hero transitions

Press feedback: every interactive surface uses `.buttonStyle(.ruulPress)`
which scales 0.97 + opacity 0.92 on press.

Honor `Reduce Motion` — if a system setting suppresses animations, our
defaults respect it (the tokens already do).

## 8. Haptics on every meaningful tap

- Selection feedback (`.selection`) on tab switches, chip taps
- Light impact on button presses that change route
- Success on RPC completion (`SensoryFeedback.success`)
- Error on RPC failure
- Warning before destructive actions

DON'T fire haptics on every tap (anti-pattern: cancellation, plain links,
non-destructive nav back).

## 9. Empty states are conversations

Every list view has an empty state. Three required parts:
1. **SF Symbol** composed for the domain (`tray`, `calendar.badge.clock`)
2. **Title** in a friendly voice — "Sin pendientes", "Todo al corriente"
3. **Body** — one sentence, conversational
4. **Optional CTA** — the next concrete action

Use `EmptyStateView` from `DesignSystem/Patterns/`. If a screen needs
something custom, copy that file's structure, don't reinvent.

## 10. Loading + error states match empty states

Same component hierarchy: SF Symbol + title + body. Never show a bare
ProgressView (acceptable only for splash / bootstrap).

Use `LoadingStateView` and `ErrorStateView`.

## 11. Accessibility is part of the build

Required on every PR:
- Every interactive element has an `accessibilityLabel`.
- Dynamic Type supported up to `xxxLarge` — test at the largest size.
- VoiceOver pass: tab through the screen, every element should make
  sense out of context.
- Color contrast: tested against light + dark + high-contrast.

## 12. Composition over special-casing

If a card needs a "version with X added", add a parameter to the
existing component, NOT a new component. Three "EventCard variants" is
worse than one with three optional inputs.

Exception: when the layouts diverge fundamentally (hero vs row), they're
different components by design (#2).

---

## How to evaluate a view against this doc

1. Open the view's file. Does it use tokens for ALL spacing, color,
   typography, animation? If no, refactor.
2. Does it reuse existing primitives (`RuulCard`, `RuulButton`,
   `RuulAvatar`, `RuulCoverView`) or roll its own? If rolls own, refactor.
3. Status indicators: dot+label? Date language: relative? Loading state:
   `LoadingStateView`? Empty state: `EmptyStateView`?
4. `.buttonStyle(.ruulPress)` on every interactive surface?
5. Accessibility labels present?

If 4 of 5 fail, queue for refactor sprint.

## Refactor priority queue

Views below the bar (need lift before V1 ships):

1. `MyFeedView` (Bloque 14.1) — flat tiles, no covers, generic card style.
   **REFACTORED 2026-05-04 — flagship exemplar.**
2. `ActionInboxView` (Bloque 14.2) — group label crammed into subtitle,
   no cover thumbs.
3. `MyFinesView` group label rendering (Bloque 14.3) — the chip is OK
   but the row could be more Wallet-like.
4. HomeView quick-switcher chip strip (Bloque 14.4) — works but flat;
   needs visual rhythm with active group state.
5. `GroupHistoryView` (Bloque 14.7) — generic timeline; see if
   `RuulTimelineItem` primitive needs uplift.
6. Onboarding views (audit) — `GovernanceConfigView` could use better
   pickers; rest are ok.

Existing views already at bar (don't touch):
- `EventCard` — gold standard
- `RSVPStateView` — Apple Sports / Luma rewrite
- `HomeView` header + sections
- `WelcomeView`, `LoginView`
