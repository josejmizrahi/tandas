# Frontend Remodel — Pass 3: hygiene sweep + iOS 26 polish

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the 101 `.font(.system(...))` ad-hoc sites, the 19 `DateFormatter()` ad-hoc sites, add SwiftLint rules to enforce going forward, apply iOS 26 polish (glass + scroll transitions + contentMargins) to floating chrome, and finish the Activity-tab filter chips deferred from Pass 2.

**Branch:** `pass3/hygiene-ios26-polish` (worktree).

**Test command:** `make -C ios test`. Baseline: 182 tests / 37 suites green.

**Out of scope (defer to future passes):**
- Subjective status-indicator audit (per-callsite design judgement)
- Subjective empty/loading/error state audit (DP §9-§10) — exception: cases that surface during the typography sweep
- VoiceOver / accessibility manual audit
- Haptics audit
- Removal of legacy `ResourceTypePickerView` (noted in Pass 2 close)

## Surface counts (baseline)

| Indicator | Count |
|---|---|
| `.font(.system(...))` direct calls in Features/ | 101 |
| `DateFormatter()` ad-hoc in Features/ | 19 |
| `RuulSpacing.` usage | 890 (already disciplined) |
| `RuulTypography.` usage | (varies; existing tokens may not cover every callsite) |
| Date helpers (`Date+EventFormatting`, etc.) | NONE — must be created |

## Tasks

### Task 1 — Baseline + worktree marker

- [ ] Verify clean state, run `make -C ios test`, empty commit baseline marker.

### Task 2 — Create Date+RuulFormatting helpers in RuulUI

Create `ios/Packages/RuulUI/Sources/RuulUI/Modifiers/Date+RuulFormatting.swift` with helpers that cover every formatter shape currently in use.

Discovery first (all 19 sites):

```bash
grep -rn "DateFormatter()" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/ \
  | grep -v ".build" | head -30
```

Read each site to capture the format string + locale + timezone in use. Build a catalog of helpers:

```swift
public extension Date {
    /// "9:00 PM" — short time, current locale
    var ruulShortTime: String { ... }
    /// "MAR 12" / "12 MAR" — short uppercase day+month
    var ruulShortDate: String { ... }
    /// "JUE 12 MAR" — short uppercase weekday+day+month
    var ruulShortDateWithWeekday: String { ... }
    /// "12 mar 2026" — sentence-case full
    var ruulMediumDate: String { ... }
    /// Apple-style relative: "Hoy", "Ayer", "Hace 3 días", "Mañana", "JUE 12 MAR"
    var ruulRelative: String { ... }
    /// Money-aware date for ledger entries
    var ruulLedgerDate: String { ... }
    // ... add as needed based on discovery
}
```

Aim for 6-10 distinct helpers. **No fewer**: undercounting means callsites stay on `DateFormatter()`. **No padding**: don't add helpers nothing uses.

- [ ] Commit: `feat(ui): Date+RuulFormatting helpers in RuulUI`

### Task 3 — Migrate 19 DateFormatter() sites to helpers

Mechanical sweep. For each site found in Task 2 discovery, replace with the matching helper. If a site uses a format the helpers don't cover, ADD the helper to Task 2's file (extending it) and use it.

After: `grep -rn "DateFormatter()" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/` returns 0.

- [ ] Build + test green
- [ ] Commit: `refactor(features): migrate 19 DateFormatter() sites to Date+RuulFormatting`

### Task 4 — Migrate `.font(.system(...))` sites to RuulTypography tokens

This is the biggest task. ~101 sites. Some are simple (`.font(.system(size: 14))` → `.ruulTextStyle(RuulTypography.body)`); others use weight/design combinations that may need a new token.

Strategy:
1. **Discovery sweep**: extract every distinct `.font(.system(...))` shape. Group by (size, weight, design).
2. **Match against existing tokens**: read `RuulTypography.swift` for current tokens. Build a mapping table (font shape → token).
3. **Identify gaps**: shapes with no matching token. For each gap, either (a) add a new token to `RuulTypography.swift` if it's used 3+ times, or (b) accept a minor visual change by mapping to the nearest existing token.
4. **Mechanical apply**: per file, replace `.font(.system(...))` with `.ruulTextStyle(RuulTypography.X)`.
5. Verify: `grep -rn "\.font(\.system" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/` returns 0.

Acceptable Pass 3 outcome: zero `.font(.system)` in Features/. New tokens added if justified by ≥3 use sites; otherwise nearest existing token wins (one-line visual change documented in the commit body).

- [ ] Build + test green
- [ ] Commit: `refactor(features): migrate 101 .font(.system) sites to RuulTypography tokens`

### Task 5 — SwiftLint custom rules

Add to `.swiftlint.yml` (create if absent):

```yaml
custom_rules:
  no_system_font:
    name: "No .font(.system(...))"
    regex: '\.font\(\.system\('
    match_kinds: [identifier, typeidentifier, argument]
    message: "Use RuulTypography tokens via .ruulTextStyle(...) instead of .font(.system(...)). Add a token to RuulTypography.swift if needed."
    severity: error
    excluded:
      - "ios/Packages/RuulUI/Sources/RuulUI/Tokens/RuulTypography.swift"
      - "ios/Packages/RuulUI/Sources/RuulUI/Tokens/RuulTypography+DSAliases.swift"

  no_ad_hoc_dateformatter:
    name: "No DateFormatter()"
    regex: 'DateFormatter\(\)'
    message: "Use Date+RuulFormatting helpers instead of DateFormatter(). Add a helper if needed."
    severity: error
    excluded:
      - "ios/Packages/RuulUI/Sources/RuulUI/Modifiers/Date+RuulFormatting.swift"
```

If `.swiftlint.yml` already exists with rules, append; don't replace.

If swiftlint isn't installed locally / in CI, document in the commit that the rules will only fire when run. Don't break the build.

- [ ] Confirm rules don't fail (zero violations expected after Tasks 3 + 4)
- [ ] Commit: `chore(lint): add no_system_font + no_ad_hoc_dateformatter custom rules`

### Task 6 — Activity tab filter chips (deferred from Pass 2)

Add filter chips to `ActivityView.swift` (in `Features/Activity/Views/`):
- Chips: `Todo · Dinero · Recursos · Gobernanza · Miembros`
- Each chip filters by `system_event.event_type` prefix or category
- Default selection: `Todo`
- Re-uses the chip styling pattern from InboxView (Pass 2)

- [ ] Build + test green
- [ ] Commit: `feat(activity): add filter chips (Todo/Dinero/Recursos/Gobernanza/Miembros)`

### Task 7 — iOS 26 polish on chrome

Apply iOS 26 modifiers where appropriate (only floating chrome — not content cards, per DP §1):

1. **`.glassEffect()`** on:
   - `GroupSwitcherHeader` (the pill header above tabs)
   - Sticky CTA in `UniversalResourceDetailView` (`DetailStickyFooterView`)
2. **`ScrollTransition`** on cards entering viewport (subtle scale 0.96 → 1.0):
   - `ResourceHeroCard` (in RuulUI Patterns)
   - Inbox action rows (in `ActionInboxView`)
   - Activity timeline rows (in `ActivityView`)
3. **`.contentMargins(.scrollIndicators, RuulSpacing.s4)`** on the main scrolls in `HomeView`, `ActivityView`, `InboxView`
4. **`.scrollEdgeEffectStyle(.soft)`** on the same lists
5. **`.symbolEffect(.bounce, value: ...)`** on counters that change:
   - Tab badge (Inbox)
   - RSVP count chip
   - Vote count

Each of these is a small additive modifier — no behavior change. Verify build green after each batch.

- [ ] Build + test green
- [ ] Commit: `feat(polish): iOS 26 glassEffect + ScrollTransition + contentMargins on chrome`

### Task 8 — Final metrics + PR

Verify:
- `.font(.system(...))` in `Features/` = 0
- `DateFormatter()` in `Features/` = 0
- SwiftLint rules in `.swiftlint.yml`
- Activity chips visible (visual smoke)
- iOS 26 polish modifiers in place (build green)
- All tests still green

Push branch + open PR.

- [ ] Final marker commit + metrics report
- [ ] `git push origin HEAD:pass3/hygiene-ios26-polish`
- [ ] `gh pr create ...`

## DoD

- 0 ad-hoc `.font(.system)` in `Features/`
- 0 ad-hoc `DateFormatter()` in `Features/`
- SwiftLint custom rules added (will fail future PRs that reintroduce ad-hoc patterns)
- Activity tab has filter chips
- iOS 26 modifiers applied to floating chrome (no glass on content cards)
- Tests green

## Risks

- Some `.font(.system(...))` calls use weight/design combinations no token covers — acceptable to fall back to nearest token with a documented one-line visual delta.
- `swiftlint` may not be installed; rules ship but only fire when run.
- iOS 26 modifiers (`scrollEdgeEffectStyle`, `symbolEffect(.bounce, value:)`) may require API availability checks if a fallback target is needed (we target iOS 26+ already, so this should be fine).
