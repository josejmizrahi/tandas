# RuulUI conventions

Quick reference for "which primitive do I reach for". Keep this file
in sync as the DS evolves; PRs touching `Primitives/` or `Patterns/`
should update the row below.

## Surfaces (screens, sheets, cards)

| Need                         | Use                                    |
|------------------------------|----------------------------------------|
| Screen with active group     | `.ruulAmbientScreen(palette: app.activeGroup.map { RuulCoverPalette.deterministicCover(for: $0.id).palette })` |
| List/dashboard screen        | `.ruulAmbientScreen(palette: nil)` (canvas only) |
| Sheet (edit / picker / quick action) | `.sheet(isPresented:) { ... }.presentationDetents([.medium, .large])` — swipe-down dismiss OK |
| Takeover (wizard / OTP / camera) | `.fullScreenCover(isPresented:) { ... }` — no swipe-down |
| Card body (default)          | `.ruulCardSurface(.glass)` — no chrome, paired with `RuulSeparatedRows` for separator |
| Card body (elevated)         | `.ruulCardSurface(.solid)` — opaque + soft elevation |
| Card body (inset row)        | `.ruulCardSurface(.recessed)` |

## Lists

| Need                         | Use                                    |
|------------------------------|----------------------------------------|
| Repeating rows + separator   | `RuulSeparatedRows(items:) { row }` |
| Section header (CAPS + count)| `RuulListSectionHeader("LABEL", count: n)` |
| Section header w/ trailing   | `RuulListSectionHeader("LABEL") { trailing }` |
| Empty state                  | `ContentUnavailableView { Label("…", systemImage: "…") } description: { Text("…") } actions: { Button("CTA") { … } }` |
| Error state                  | `ContentUnavailableView { Label("…", systemImage: "exclamationmark.triangle") } description: { Text(msg) } actions: { Button("Reintentar") { … } }` |
| Loading state                | `RuulLoadingState()` |

## Identity surfaces (cover hero, ambient)

| Need                         | Use                                    |
|------------------------------|----------------------------------------|
| Resource detail cover        | `ResourceCoverHero(palette:height:...)` — pass `palette` + per-type `height` |
| Full-screen ambient layer    | `RuulAmbientBackground(palette:style:)` — `.soft` for global, `.vivid` for hero-adjacent |
| Per-group palette            | `RuulCoverPalette.deterministicCover(for: group.id).palette` (UUID-determined cover from catalog) |
| Per-resource palette         | `ResourceAmbientPalette.resolve(for: ctx)` |

## Inputs, buttons, badges

| Need                         | Use                                    |
|------------------------------|----------------------------------------|
| Primary CTA                  | `RuulButton(.., style: .primary, size: .large)` |
| Soft glass input             | `RuulTextField` / `RuulPhoneField` (already glass-fill) |
| Status pill (positive/etc.)  | `RuulBadge(tone:)` |
| Selectable filter chip       | `Button(...) { ... }.buttonStyle(isSelected ? .borderedProminent : .bordered).controlSize(.small)` |
| Solid CTA over an image      | hardcoded `Color.ruulImagePillSolid` + `ruulOnImageInverse` (Tripsy pattern; deliberate override) |

## Don't

- Don't put `.ruulAmbientScreen(palette: …)` inside a modal — the
  modal's `.fullScreenCover` chrome already paints the canvas.
  Adding another canvas layer just stacks.
- Don't hand-roll section headers — use `RuulListSectionHeader`.
- Don't hand-roll lists with `VStack { ForEach }` — use
  `RuulSeparatedRows` so spacing + hairline match every other list.
- Don't reach for `Color.gray` / raw hex / `cornerRadius: 12` — pick
  the matching token (`RuulColors`, `RuulRadius`, `RuulSpacing`,
  `RuulOpacity`, `RuulSize`).
- Use `.sheet(isPresented:) { ... }.presentationDetents([.medium, .large])`
  for edit / picker / quick-action flows (swipe-down dismiss is safe).
  Reserve `.fullScreenCover(...)` for true takeovers: wizards, OTP,
  camera, photo viewer, splash. (Apple HIG; reverses the 2026-05-15
  "every modal is fullScreenCover" policy.)

## Tokens

- **Radii**: `RuulRadius.sm/.md/.lg/.xl` or aliases
  `small/.medium/.large/.extraLarge/.card/.hero/.pill/.circle`
- **Spacing**: `RuulSpacing.s0…s12` or aliases `xxs/xs/sm/md/lg/xl/xxl`
  (+ `.micro` for 6pt, `.s0_5` for 2pt)
- **Opacity**: `RuulOpacity.subtle (.08) / .medium (.14) / .disabled (.5)`
- **Color**: `Color.ruulBackgroundCanvas / .ruulSurface / .ruulText* /
  .ruulSeparator / .ruulFillGlass / .ruulOnImage* / etc.`
- **Size**: `RuulSize.avatar* / .iconBadge* / .icon* / .heroBanner /
  .heroLarge / .coverHero / .blurAmbient`
- **Typography**: SwiftUI native — `.largeTitle/.title/.title2/.headline/
  .body/.subheadline/.footnote/.caption/.caption2` with optional
  `.weight(.semibold)` / `.monospaced()` / `.monospacedDigit()`. No custom
  font system; SF Pro across the app.
