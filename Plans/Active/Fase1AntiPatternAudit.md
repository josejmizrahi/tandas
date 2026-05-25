# FASE 1 — Anti-Pattern Call-Site Audit

**Status**: Read-only call-site classification, written 2026-05-19.
**Scope**: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/` (209 files) + `ios/Packages/RuulUI/Sources/RuulUI/` (89 files).
**Doctrine**: `~/Library/.../memory/fase1_native_refactor_doctrine.md` (decisions #4 and #5).
**Companion**: `Plans/Active/Fase1NativeAudit.md` §3-§5 supplies primitive-level decisions; this doc enumerates concrete call sites.

Each table column:
- **file:line** — exact location
- **usage context** — what the modifier wraps / where it appears in the view tree
- **KEEP / DELETE / AUDIT_FURTHER** — classification per doctrine
- **rationale / native replacement**

---

## Section A — `.glassEffect()` / `.ruulGlass()`

**Pattern.** Liquid Glass material applied via either the native iOS 26 `.glassEffect(in:)` API or the Ruul wrapper `.ruulGlass(_:material:tint:interactive:)` (defined in `RuulUI/Modifiers/GlassEffect+Ruul.swift`).

**Doctrine decision #5.** Glass survives ONLY where Apple uses it: floating toolbar, bottom action surfaces, transient overlays, media-like chrome, compact controls over content. Glass DIES on: every card, every sheet, backgrounds, giant glass panels, dashboard translucency.

### A.1 Call sites — RuulFeatures

| file:line | usage context | verdict | rationale / native replacement |
|---|---|---|---|
| `Features/Resources/CheckIn/CheckInScannerView.swift:81` | Header bar laid over the live camera scanner view (count of attendees) | **KEEP** | Compact control over media — exactly decision #5's "media-like chrome / compact controls over content". |
| `Features/Resources/CheckIn/CheckInScannerView.swift:106` | Recent check-in chip overlay on the camera scanner | **KEEP** | Transient overlay over media. |
| `Features/Resources/Detail/Adapters/EditEventView.swift:170` | Sticky bottom CTA bar (`Rectangle`) over a scroll content | **KEEP** | Bottom action surface — decision #5 explicitly allows. |
| `Features/Rules/EditRuleParamsSheet.swift:166` | Stepper row inside a form-style edit sheet | **DELETE** | Inline form row, not floating. Replace with native `Section { LabeledContent { Stepper } }` inside a `Form`. |
| `Features/Rules/EditRuleParamsSheet.swift:274` | Inline error message tile inside the same sheet | **DELETE** | Inline form footer. Replace with `Section { } footer: { Text(error).foregroundStyle(.red) }` or a `.alert`. |

### A.2 Call sites — RuulUI

| file:line | usage context | verdict | rationale / native replacement |
|---|---|---|---|
| `Modifiers/GlassEffect+Ruul.swift:41` | The wrapper modifier implementation itself | **KEEP** | Infra. Thin wrapper around native `.glassEffect()` — this is the canonical way other code adopts glass. |
| `Patterns/EventCardStub.swift:71` | Card preview stub | **DELETE** | Card metaphor banned. Replace with `Section { Row }` in a `List`. |
| `Patterns/RSVPStateView.swift:49` | Status card inside RSVP pattern | **DELETE** | Card. Use grouped `Section` row. |
| `Patterns/RSVPStateView.swift:68` | Secondary card in the same pattern | **DELETE** | Same. |
| `Templates/DetailScreenTemplate.swift:57` | Full-screen template background `Rectangle` | **DELETE** | Template going away (Fase1NativeAudit §3.D). Use `NavigationStack` directly. |
| `Tokens/RuulGlass.swift:5` | Doc comment in the tokens file | n/a | Documentation only. Refresh when wrappers shrink. |
| `Primitives/RuulIconBadge.swift:40` | Circle icon-badge container | **AUDIT_FURTHER** | Decision #5 lists "compact controls over content" — a small badge *could* qualify, but `RuulIconBadge` is also drawn inside flat lists/forms (e.g. onboarding bullets in `GroupTourOverlay.swift:68`). Decide per call site: drop glass when inside `List`/`Form`, keep when over content. |
| `Primitives/RuulAvatarStack.swift:57` | Overflow `+N` circle on avatar stack | **DELETE** | Small chip on a small element — Apple stacks avatars over plain backgrounds. Replace with plain `Circle().fill(.secondary.opacity(0.15))`. |
| `Primitives/RuulTabBar.swift:44` | Capsule tab bar background | **DELETE** | Whole primitive is replaced by native `TabView` per Fase1NativeAudit §3.A. |
| `Primitives/RuulPicker.swift:66` | Custom dropdown body | **DELETE** | Primitive replaced by native `Picker(.menu/.wheel)`. |
| `Primitives/RuulDatePicker.swift:36` | Date-picker wrapper body | **DELETE** | Replace with native `DatePicker`. |
| `Primitives/RuulToast.swift:36` | Floating toast body | **DELETE** | Toasts forbidden by doctrine. Errors → `.alert`; success → no notification. |
| `Primitives/RuulPillButton.swift:68` | Pill-button Circle background | **DELETE** | Primitive replaced by `Button(...).buttonStyle(.glass / .bordered)`. |
| `Primitives/RuulOTPInput.swift:103` | OTP input wrapper | **DELETE** | OTP is a form field, not floating. Plain text fields inside a `Form` row. |
| `Primitives/RuulGroupSwitcher.swift:53` | Capsule "active group + chevron" that sits in the navigation header | **AUDIT_FURTHER** | Could be read as a compact control (toolbar-adjacent), but Apple usually puts this in the nav title or a `Menu` picker. Decision needed: rework as native `Menu { } label: { Label }` in toolbar — likely DELETE the glass capsule. |
| `Primitives/RuulHeaderActions.swift:18` | Capsule that bundles N `RuulPillButton`s as a floating header action group | **KEEP** | Floating toolbar surface — exactly decision #5's "floating toolbar". Caveat: the *internal* `RuulPillButton`s should still be replaced with native button styles. |
| `Primitives/RuulChip.swift:75` | Generic chip wrapper | **DELETE** | Chips are a SaaS tell. Use `Picker(.segmented)` for filters; inline tint for tags. |
| `Primitives/RuulSegmentedControl.swift:38` | Custom segmented control capsule | **DELETE** | Replace with `Picker(.segmented)`. |
| `Primitives/RuulButton.swift:120` | Button background when style is glass | **DELETE** | Use native `.buttonStyle(.glass)` (iOS 26) or `.bordered`. |
| `Primitives/RuulCard.swift:76` | Card background (the primary "every card has glass" violation) | **DELETE** | Cards forbidden. `Section { Row }` inside `List`. |

### A.3 Stats — Section A

- Total call sites: **26** (5 features + 21 RuulUI, excluding doc comments).
- **KEEP: 5** (~19%) — all are media-overlay or floating-toolbar surfaces.
- **AUDIT_FURTHER: 2** (~8%) — `RuulIconBadge`, `RuulGroupSwitcher`.
- **DELETE: 19** (~73%) — cards, sheets, dropdowns, toasts, form rows, primitives slated for removal.
- Infrastructure (keep wrapper, repurpose internals): `Modifiers/GlassEffect+Ruul.swift` — 1 file remains as the thin wrapper after deletions.

---

## Section B — Group-color theming

**Pattern.** Tinted ambient backgrounds, mesh gradients, per-group palettes applied to screens / sheets / backgrounds. Token surfaces: `RuulCoverPalette`, `GroupColorRamp`, `.ruulAmbientScreen(palette:)`, `RuulAmbientBackground`, `RuulMeshBackground`.

**Doctrine decision #4.** Per-group color survives ONLY in: avatars, tiny accents, event dots, small chips, calendar identity. DIES on: tinted screens, per-group backgrounds, gradients, ambient color dominance.

### B.1 Call sites — RuulFeatures

| file:line | usage context | verdict | rationale / native replacement |
|---|---|---|---|
| `Features/Inbox/Views/ActionInboxView.swift:21` | `.ruulAmbientScreen(palette: nil)` on the inbox screen | **DELETE** | Tinted screen background. Use `Color(.systemGroupedBackground)` (default for `List`/`Form`). |
| `Features/Rules/RulesView.swift:135` | Same modifier on Rules root | **DELETE** | Same. |
| `Features/Home/HomeView.swift:83` | Same modifier on Home tab | **DELETE** | Same. Plain `List`. |
| `Features/Activity/Views/ActivityView.swift:43` | Same modifier on Activity tab | **DELETE** | Same. |
| `Features/Group/Subscreens/GovernanceView.swift:52` | Same modifier on Governance screen | **DELETE** | Screen is being rebuilt as a `Form` (Fase1NativeAudit §7) — drop ambient background. |
| `Features/Rules/RuleDetailView.swift:74` | Same modifier on Rule detail | **DELETE** | Default `Form` background. |
| `Features/Resources/Detail/Sheets/AttendeesListSheet.swift:39` | Same modifier inside a sheet | **DELETE** | Sheets get system material chrome by default; ambient screen inside a modal is the worst case (decision #4 forbids this explicitly via "DELETE: tinted screens"). |
| `Features/Resources/Detail/Sheets/LinkResourcePickerSheet.swift:55` | Same inside another sheet | **DELETE** | Same. |
| `Features/Group/Subscreens/RulePresetsView.swift:81` | Same modifier on presets screen | **DELETE** | Same. |
| `Features/Profile/Views/MyLedgerView.swift:49` | Same modifier on user's money history | **DELETE** | Same. (Bonus: rename screen too — see Fase1NativeAudit §6.) |
| `Features/Members/Views/MemberDetailView.swift:77` | Same modifier on member detail | **DELETE** | Same. |
| `Features/Groups/Invites/CreateGroupSheet.swift:52` | Same modifier inside a sheet | **DELETE** | Sheet — drop. |
| `Features/Groups/Switcher/GroupSwitcherSheet.swift:68` | Same modifier inside the group switcher sheet | **DELETE** | Sheet — drop. |
| `Features/Groups/Invites/JoinGroupSheet.swift:52` | Same modifier inside another sheet | **DELETE** | Sheet — drop. |
| `Features/Onboarding/Invited/Views/InviteWelcomeView.swift:28` | `RuulAmbientBackground(palette: cover.palette, style: .vivid)` — invite hero "poster" screen | **AUDIT_FURTHER** | Invite welcome is closest to a marketing / hero surface (analogous to "login/welcome" per decision #2). Could justify a tinted screen. BUT the screen also includes a `posterCard` with the actual cover image (line 101+) which already carries identity. Likely DELETE the screen-wide ambient and keep only the poster card. Founder decision needed. |
| `Features/Onboarding/Invited/Views/InviteWelcomeView.swift:30` | `RuulMeshBackground(.aqua)` — fallback while invite preview loads | **AUDIT_FURTHER** | Same call site as above; the fallback is meant to prevent a black flash. If the ambient is removed, replace with `Color(.systemBackground)` while loading — flash is no longer ambient-tinted. |
| `Features/Onboarding/Founder/Views/ConfirmationView.swift:21` | `RuulMeshBackground(.violet)` — founder onboarding success screen | **AUDIT_FURTHER** | Onboarding/celebration moment. Decision #2 retains wordmark in onboarding; decision #4 bans tinted screens unconditionally. Tension is real. Default to DELETE per #4's "ambient color dominance" prohibition, unless founder explicitly preserves onboarding-only mesh. |

### B.2 Call sites — RuulUI

| file:line | usage context | verdict | rationale / native replacement |
|---|---|---|---|
| `Modifiers/RuulCoverPalette.swift:16` | Enum definition + deterministic mapping group.id → palette | **KEEP (scope-restricted)** | Decision #4 preserves group identity in avatars + event dots + calendar identity. Keep the type, restrict callers to those surfaces. |
| `Modifiers/RuulAmbientScreen.swift` (whole file) | `.ruulAmbientScreen(palette:style:)` modifier | **DELETE** | Modifier itself goes. Every feature call site is DELETE above. |
| `Primitives/RuulAmbientBackground.swift` (whole file, ~120 LOC) | The full-screen ambient primitive | **DELETE** | Only remaining caller after sweep is `InviteWelcomeView` which is AUDIT_FURTHER. If that goes too, the primitive can be deleted. |
| `Primitives/RuulMeshBackground.swift` (whole file) | Mesh-gradient hero background, variants `.cool / .violet / .aqua` | **AUDIT_FURTHER** | Only callers are onboarding (`OnboardingScreenTemplate`, `ConfirmationView`, `InviteWelcomeView` fallback) and `RuulFullScreenCover.swift:40`. If onboarding screens lose mesh, this file can go. |
| `Primitives/RuulFullScreenCover.swift:40` | `RuulMeshBackground(.violet)` inside the full-screen cover wrapper | **DELETE** | Generic cover should not impose a per-group/violet tint. Use plain `Color(.systemBackground)`. |
| `Templates/OnboardingScreenTemplate.swift:6,18` | Template parameter `mesh: RuulMeshBackground.Variant = .cool`, used as default background | **AUDIT_FURTHER** | Onboarding-specific. Tied to the AUDIT_FURTHER decision for `ConfirmationView` and `InviteWelcomeView`. If kept, scope strictly to onboarding; if removed, simplify template to a plain `Color(.systemBackground)`. |
| `Primitives/RuulGroupAvatar.swift:75` | `placeholder(ramp: GroupColorRamp)` — avatar fallback when no image | **KEEP** | Decision #4 explicitly allows avatars. Canonical surviving use of group color. |
| `Tokens/RuulSize.swift:25` | Doc comment referencing `RuulAmbientBackground` blur radius | n/a | Documentation only. Clean up after the primitive is deleted. |
| `CONVENTIONS.md:11,12,34,35,50` | Docs prescribing `.ruulAmbientScreen` usage | n/a | Docs need a rewrite once the modifier is deleted. |

### B.3 Stats — Section B

- Total call sites: **23** (17 features + 6 substantive RuulUI sites, excluding doc/comment-only).
- **KEEP: 2** (~9%) — `RuulCoverPalette` enum (scoped to avatars/dots), `RuulGroupAvatar` placeholder.
- **AUDIT_FURTHER: 5** (~22%) — `InviteWelcomeView` × 2, `ConfirmationView`, `OnboardingScreenTemplate`, `RuulMeshBackground` primitive (fate depends on onboarding decision).
- **DELETE: 16** (~70%).
- Likely outcome after AUDIT_FURTHER resolves: if onboarding loses mesh, ~21/23 = **91% deleted**.

---

## Section C — Custom motion (`RuulMotion.*`, `withAnimation(.ruul*)`)

**Pattern.** Custom spring presets — `.ruulSnappy`, `.ruulSmooth`, `.ruulMorph`, `.ruulTap`, `.ruulGroupSwitch` — wrapping `withAnimation` or `.animation(_:value:)`.

**Doctrine.** Subtle native motion only: `.default` / `.smooth`, native sheet/nav transitions, `contentTransition`, `symbolEffect`. DELETE custom presets.

### C.1 Call sites — RuulFeatures

| file:line | usage context | verdict | rationale / native replacement |
|---|---|---|---|
| `Features/Onboarding/Invited/Views/GroupTourOverlay.swift:35` | `withAnimation(.ruulMorph)` on overlay reveal | **DELETE** | Replace with `withAnimation { visible = true }` (default spring). |
| `Features/Onboarding/Invited/Views/GroupTourOverlay.swift:87` | `withAnimation(.ruulSmooth)` on dismiss | **DELETE** | Replace with default `withAnimation`. |
| `Features/Fines/Views/MyFinesView.swift:149` | `withAnimation(.ruulSnappy)` on segmented scope change | **DELETE** | Native `Picker(.segmented)` ships with built-in haptics + animation; remove explicit `withAnimation` entirely. |
| `Features/Auth/SignInView.swift:205` | `withAnimation(.ruulSnappy)` on auth state transition | **DELETE** | `withAnimation` default. |
| `Features/Activity/Views/ActivityView.swift:95` | `withAnimation(.ruulSnappy)` on filter chip selection | **DELETE** | Drop entire `withAnimation`; native `Picker` handles its own transition. |
| `Features/Onboarding/Founder/Views/PresetPickerView.swift:69` | `withAnimation(.ruulSnappy)` on preset selection | **DELETE** | `withAnimation` default or remove. |
| `Features/Resources/ResourceWizardSheet.swift:1030` | `withAnimation(.ruulSnappy)` on category selection inside wizard | **DELETE** | Wizard is being restructured anyway (Fase1NativeAudit §8 Wave 3). Drop custom spring. |

### C.2 Call sites — RuulUI

| file:line | usage context | verdict | rationale / native replacement |
|---|---|---|---|
| `Tokens/RuulMotion+DSAliases.swift` (whole file) | Aliases for legacy `RuulMotion` keys | **DELETE** | Token file going away with the motion tokens. |
| `Primitives/RuulTabBar.swift:52` | `withAnimation(.ruulTap)` on tab tap | **DELETE** | Primitive replaced by native `TabView`. |
| `Primitives/RuulPicker.swift:39` | `withAnimation(.ruulSnappy)` on option select | **DELETE** | Primitive replaced by native `Picker`. |
| `Primitives/RuulSegmentedControl.swift:19` | `withAnimation(.ruulSnappy)` on segment select | **DELETE** | Primitive replaced by `Picker(.segmented)`. |
| `Primitives/RuulToast.swift:105` | `withAnimation(.ruulSmooth)` on dismiss | **DELETE** | Toast primitive deleted. |

### C.3 Stats — Section C

- Total call sites: **12** (7 features + 5 RuulUI).
- **KEEP: 0**.
- **AUDIT_FURTHER: 0**.
- **DELETE: 12** (100%).
- Related sweep: `.animation(.ruul*, value:)` modifier call sites also exist (e.g. `CheckInScannerView.swift:110` uses `.animation(.ruulSmooth, value:)`, `RuulGroupSwitcher.swift:54` uses `.animation(.ruulGroupSwitch, value:)`). These are NOT in the primary grep but should be swept in the same PR — same token system, same disposal verdict.

---

## Section D — Heavy shadows (`RuulShadow.*`, `.ruulElevation`, custom `.shadow(...)`)

**Pattern.** Custom elevation tokens layered as drop shadows. Token surfaces: `RuulShadow` (mostly gutted 2026-05-15), `RuulElevation` (still active via `.ruulElevation(.sm/.md/.lg/.glass)`), and ad-hoc `.shadow(...)` calls.

**Doctrine.** Apple uses materials + separators, not shadows. DELETE most usages. Exception: text-on-image legibility shadows (HIG-allowed; Apple uses them on Photos, Maps, Music album art overlays).

### D.1 Call sites — RuulFeatures

| file:line | usage context | verdict | rationale / native replacement |
|---|---|---|---|
| `Features/Resources/Create/PostCreateIntentScreen.swift:178` | `.ruulElevation(.sm)` on post-create intent tile | **DELETE** | Use `Section` row inside `List`/`Form` — native separators replace shadow. |
| `Features/Resources/Create/Steps/ResourceTypePicker.swift:109` | `.ruulElevation(.sm)` on picker tile | **DELETE** | Same — replace with `List` selection row. |
| `Features/Resources/Create/Steps/ResourceVariantPicker.swift:98` | `.ruulElevation(.sm)` on variant tile | **DELETE** | Same. |
| `Features/Onboarding/Invited/Views/GroupTourOverlay.swift:55` | `.ruulElevation(.lg)` on tour card | **DELETE** | Card going away with `RuulCard` (Fase1NativeAudit §3.A). Even if onboarding overlay survives, native sheet shadow is sufficient. |
| `Features/Resources/Subviews/EventCard.swift:130` | `.shadow(color: Color.ruulImageTextShadow, radius: 2, x: 0, y: 1)` on event title text laid over cover image | **KEEP** | Text-on-image legibility shadow. HIG-allowed; Photos / Music / Maps all use this. Subtle (radius 2) so reads as legibility, not depth. |
| `Features/Resources/ResourceWizardSheet.swift:132` | `.ruulElevation(.sm)` on wizard tile | **DELETE** | Wizard is being restructured; drop elevation. |
| `Features/Resources/ResourceWizardSheet.swift:224` | `.ruulElevation(.sm)` on a second tile | **DELETE** | Same. |
| `Features/Onboarding/Invited/Views/InviteWelcomeView.swift:92` | `.shadow(color: Color.ruulImageTextShadow, radius: RuulSpacing.md, x: 0, y: 4)` on the group-name headline drawn over the ambient/poster image | **KEEP** | Text-on-image legibility shadow. Same reasoning as `EventCard.swift:130`. |
| `Features/Onboarding/Invited/Views/InviteWelcomeView.swift:130` | `.ruulElevation(.lg)` on the poster `ZStack` | **DELETE** | Poster card with depth shadow — replace with `.background(.regularMaterial)` or no chrome (the cover image alone carries weight). |
| `Features/Onboarding/Invited/Views/InviteWelcomeView.swift:174` | `.ruulElevation(.sm)` on a secondary surface | **DELETE** | Drop. |
| `Features/Inbox/Views/InboxView.swift:132` | `.shadow(radius: 4)` on a custom bottom-of-screen toast capsule | **DELETE** | Whole toast pattern is forbidden (see Section A / Fase1NativeAudit §3.A). Replace with `.alert` or remove. |

### D.2 Call sites — RuulUI

| file:line | usage context | verdict | rationale / native replacement |
|---|---|---|---|
| `Tokens/RuulShadow.swift:6` | File comment noting most callers deleted 2026-05-15 | n/a | Already gutted. Delete remainder. |
| `Tokens/RuulElevation.swift:32,34,36,39,40` | `.ruulElevation(_:)` implementation — applies `.shadow` for `.sm/.md/.lg/.glass` | **DELETE** | Delete the entire token + modifier per Fase1NativeAudit §2 / §8 Wave 1.4. |
| `Modifiers/RuulSurfaceStyle.swift:43` | `.ruulElevation(.sm)` inside the surface-style modifier | **DELETE** | Whole modifier goes (Fase1NativeAudit §5). |
| `Primitives/TemplatePickerCard.swift:49` | `.ruulElevation(.sm)` on template-picker card | **DELETE** | Replace primitive with `List` selection row. |
| `Primitives/RuulToast.swift:41` | `.ruulElevation(.lg)` on toast | **DELETE** | Toast primitive deleted. |
| `Primitives/RuulButton.swift:109` | `.ruulElevation(.sm)` on primary button | **DELETE** | Native `.borderedProminent` / `.glass` carry their own subtle depth. |
| `Primitives/RuulButton.swift:124` | `.ruulElevation(.sm)` on secondary button variant | **DELETE** | Same. |
| `Primitives/RuulCard.swift:77` | `.ruulElevation(.glass)` on `.tile` card | **DELETE** | Card primitive deleted. |
| `Primitives/RuulCard.swift:81` | `.ruulElevation(.sm)` on `.flat` card | **DELETE** | Same. |

### D.3 Stats — Section D

- Total call sites: **20** (12 features + 8 RuulUI, excluding token-file infrastructure that is already gutted).
- **KEEP: 2** (~10%) — both are text-on-image legibility shadows (`EventCard`, `InviteWelcomeView` headline).
- **AUDIT_FURTHER: 0**.
- **DELETE: 18** (~90%).
- Infrastructure deletion: `Tokens/RuulShadow.swift` + `Tokens/RuulElevation.swift` + `Modifiers/RuulSurfaceStyle.swift` go entirely (token bankruptcy after callers swept).

---

## Open questions / AUDIT_FURTHER items

These need a founder decision before the deletion PR can ship cleanly. Listed in priority order.

1. **(Section B) Onboarding & invite tinted screens.** Decision #4 ("DELETE: tinted screens") and decision #2 ("wordmark kept in onboarding") interact. Pending verdict for:
   - `InviteWelcomeView.swift:28` (`RuulAmbientBackground(palette: cover.palette, style: .vivid)`)
   - `InviteWelcomeView.swift:30` (`RuulMeshBackground(.aqua)` loading fallback)
   - `ConfirmationView.swift:21` (`RuulMeshBackground(.violet)` founder-onboarding celebration)
   - `OnboardingScreenTemplate.swift:6,18` (mesh background default for every onboarding step)
   - Fate of `RuulMeshBackground` primitive itself depends on the four above.
   - **Default reading:** decision #4 is unconditional and bans tinted screens; delete all four. If founder wants to preserve a tiny "hero / poster" moment for the invite-welcome, do it via the existing cover-image `posterCard` (line 101) only, not a screen-wide ambient.

2. **(Section A) `RuulIconBadge` glass.** Doctrine permits glass on "compact controls over content"; a small icon badge could qualify, but `RuulIconBadge` is also used flat inside lists/onboarding bullets. Two viable resolutions:
   - **a.** Strip the `.ruulGlass` from the primitive; let callers add glass when they sit over media.
   - **b.** Keep glass but add a `style: .flat / .glass` flag and migrate non-overlay callers to `.flat`.
   - Default: **a** (simpler, matches "thin wrappers around native" doctrine).

3. **(Section A) `RuulGroupSwitcher` glass capsule.** Currently a capsule with glass living in the navigation header. Apple's pattern for "switch active context" is a `Menu` in the nav title or toolbar, not a free-floating capsule. Likely DELETE the glass capsule entirely and rebuild as `Menu { } label: { Label("Active group name", systemImage: "chevron.down") }` placed in the toolbar.

4. **(Section C) Related `.animation(.ruul*, value:)` sites.** The primary grep (`withAnimation(.ruul*)`) misses ~6 sites where the modifier form is used. These are doctrinally identical (same custom motion tokens) but live outside the primary grep. List for sweep PR:
   - `Features/Resources/CheckIn/CheckInScannerView.swift:110` — `.animation(.ruulSmooth, value: …)`
   - `Primitives/RuulGroupSwitcher.swift:54` — `.animation(.ruulGroupSwitch, value: …)`
   - Re-grep `\.animation\(\.ruul` before the Wave 1 motion-purge PR.

5. **(Section D) `Color.ruulImageTextShadow`.** The KEEP'd legibility shadows reference this color token. If it's a custom semi-transparent black, that's fine; if it carries a brand tint, replace with plain `Color.black.opacity(0.5)`. Quick inspection task — does NOT block the broader audit.

---

## Aggregate stats across all four sections

| Section | Total sites | KEEP | AUDIT_FURTHER | DELETE | % delete |
|---|---:|---:|---:|---:|---:|
| A — Glass | 26 | 5 | 2 | 19 | 73% |
| B — Group-color theming | 23 | 2 | 5 | 16 | 70% |
| C — Custom motion | 12 | 0 | 0 | 12 | 100% |
| D — Heavy shadows | 20 | 2 | 0 | 18 | 90% |
| **Total** | **81** | **9** | **7** | **65** | **80%** |

Eighty percent of the call sites in the four banned-pattern surfaces are scheduled for deletion. The remaining 20% breaks down to:
- **9 KEEP sites** — bottom action surface (1), media-overlay toolbar/chip (2), floating header capsule infra (1), wrapper modifier (1), avatar group-color placeholder (1), text-on-image legibility shadows (2), and the `RuulCoverPalette` enum scoped to avatar/dot use (1).
- **7 AUDIT_FURTHER sites** — concentrated around onboarding (mesh / ambient backgrounds), small-control glass (`RuulIconBadge`, `RuulGroupSwitcher`), all gated on founder resolution of the open questions above.
