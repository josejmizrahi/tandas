# ruul — UX Audit

> Comprehensive review of every user-facing surface, scored against
> `DesignPrinciples.md`. Findings ranked by impact. Source of truth for
> the design refactor backlog.

Status legend:
- ✅ **At bar** — passes the principles checklist, no work needed.
- 🟡 **Polish needed** — works but has rough edges. Specific fix listed.
- 🔴 **Below bar** — needs structural rework. Detailed plan listed.

Updated 2026-05-04 after rounds 1-3 of the design lift.

---

## Tab 1: Inicio (HomeView)

**Status: ✅ At bar** (after round 3 polish)

What works:
- Apple Sports header (greeting tracked uppercase + display group name)
- Hero EventCard with full cover, vignette, badges, RSVP CTA inline
- Compact EventRow list for upcoming (round 3 — was heavy EventCards)
- Empty state uses canonical primitive
- FAB monochrome solid black on white (Apple Sports DNA)
- Multi-group quick-switcher chips with badge counts

Remaining tweaks (low priority):
- Quick-switcher active state could use a bottom underline instead of
  full accent fill — more Apple Tab Bar-like.
- Hero card lacks attendee avatars + confirmed count right now (the
  HomeCoordinator should batch-load these so EventCard shows real data,
  not zeros).

---

## Tab 2: Inbox (ActionInboxView)

**Status: ✅ At bar** (after round 2)

What works:
- ActionCard primitive with circle icon + priority dot + title +
  subtitle + chevron
- `meta` slot now renders group name as uppercase tracked accent above
  title (round 2 fix — was crammed in subtitle)
- Cross-group inbox driven by RLS, no awkward filter logic
- Empty state via `EmptyStateView` primitive

Remaining tweaks:
- Could group actions by priority bucket (Urgentes / Pendientes /
  Después) instead of flat list. Apple Mail-style sectioning.
- `timeRemaining` parameter is wired but never set — should compute
  from `expires_at` and pass for `appealVotePending`, `fineProposalReview`.

---

## Tab 3: Reglas (RulesView)

**Status: 🟡 Polish needed**

What works:
- Hero stat header ("3 reglas activas")
- EmptyStateView used
- ruleCard with title/description/INACTIVA badge

Issues:
- Each `ruleCard` is ad-hoc HStack instead of using `RuulCard` primitive
- No grouping by module (basic_fines vs rotating_host etc.) — V2 will
  have multiple modules with rules; flat list won't scale
- "Editar reglas" affordance is missing (deferred per Bloque 6 follow-up)
- The fine amount on the right is monospaced numerals but lacks the
  `statSmall` typography token

Fix scope: ~30 min refactor next session.

---

## Tab 4: Yo (currently MyFinesView)

**Status: 🔴 Below bar — wrong content for tab**

The "Yo" tab should be a Profile, not a fines list. Currently:
- Tab label: "Yo"
- Title shown: "Mis multas"
- Toolbar action: history clock icon
- Content: list of fines

This is the most confusing UX in the app. A user expecting "their
profile" gets a financial document.

Proposed redesign — `ProfileView`:
```
┌──────────────────────────────────┐
│ José Mizrahi · Hosteas 3 cenas   │  hero (avatar + display name + role meta)
│                                   │
│ EN ESTE GRUPO         Los Cuates │  group context strip
│                                   │
│ MIS MULTAS                        │  section
│ ┌─────────┐ ┌─────────┐ ┌──────┐ │
│ │ $300    │ │ ESTE MES│ │  3   │ │  3 stat tiles (debt, monthly, count)
│ │ pend.   │ │ pagaste │ │multas│ │
│ └─────────┘ └─────────┘ └──────┘ │
│ Ver todas mis multas →            │  link to MyFinesView
│                                   │
│ ACTIVIDAD                         │
│ Historia del grupo →              │  link to GroupHistoryView
│ Mis votos →                       │  link to (future) MyVotesView
│                                   │
│ AJUSTES                           │
│ Notificaciones →                  │
│ Privacidad →                      │
│ Cerrar sesión                     │  destructive
└──────────────────────────────────┘
```

Then MyFinesView becomes a navigation destination (not a tab content).

Priority: HIGH. Scope: ~3-4 hours. Touches MainTabView profileTab,
new ProfileView component, link wiring.

---

## EventDetailView (full-screen cover)

**Status: ✅ At bar** (per prior commits "design(apple-sports)")

Composes existing well-designed subviews:
- `EventRSVPStateView`
- `EventHostActionsSection`
- `AttendeesListSection`
- `CheckInSection`
- `EventLocationCard`

No specific issues identified in the audit pass. The flow from HomeView
hero → EventDetail is the gold-standard interaction in the app.

---

## CreateEventView

**Status: ✅ At bar** (single-screen Luma-style per prior commits)

---

## MyFinesView (now a navigation destination per ProfileView fix)

**Status: 🟡 Polish needed**

What works:
- Hero stat header ("PENDIENTE DE PAGO" + display amount)
- Pending / Resolved sections
- FineCard with status dot, amount, group label (cross-group)
- EmptyStateView

Issues:
- Hero stat doesn't differentiate "all clear" from "still settling".
  At $0 with paid history: should show ✓ + "Todo al corriente" tone.
- Resolved section uses same FineCard as Pending — could be denser
  (compact row variant of FineCard, like EventRow vs EventCard)
- No filter chips (this month / all time / by group)

---

## GroupHistoryView

**Status: ✅ At bar** (after round 3 empty-state fix)

What works:
- DS `RuulTimelineItem` primitive with continuous rail
- Filter sheet (event type + date range)
- Infinite scroll + pull-to-refresh
- Empty state via primitive

Remaining tweaks:
- Filters are functional but the bar at top could be more discoverable
  (FilterChip pattern instead of a single ⋯ toolbar button)
- "Activity badge" — would be good to surface on Profile when there
  are events the user hasn't seen yet

---

## MyFeedView (cross-group feed)

**Status: ✅ At bar** (after round 1 redesign)

What works:
- Hero EventCard for first event of first non-empty section
- Compact EventRow list grouped by Hoy / Mañana / Esta semana / etc.
- Sectioned with tracked uppercase headers + count
- Empty state primitive

Remaining tweaks:
- Hero card currently passes `myStatus: nil, isHostedByMe: false,
  attendeeAvatars: [], confirmedCount: 0`. Cross-group context doesn't
  load these (would be N+1 queries). V1.x: batch RSVP loader.
- "Recientes" section should render slightly muted (50% opacity tile)
  to signal "past" without being hidden.

---

## Sheets

### GroupSwitcherSheet

**Status: ✅ At bar**

Section pattern (Tus grupos / Más opciones), groupRow with avatar +
chevron + isActive accent, actionRow with icon + title + subtitle.

### GroupInfoSheet, GroupSettingsSheet

**Status: ✅ At bar** (per recent commits adding them)

### CreateGroupSheet, JoinGroupSheet

**Status: 🟡 Polish needed**

These are likely thin wrappers over forms. Need a quick audit:
- Does each step have a visual progress indicator?
- Does the "Continuar" CTA disable until valid?
- Does success animation feel celebratory?

### ShareEventSheet

**Status: ✅ At bar** (commit fcbe9cd added invite share infrastructure)

### CancelEventSheet, CloseEventSheet, RemindAttendeesSheet, MemberQRSheet

**Status: 🟡 Need audit pass**

Confirmation dialogs deserve special care. Each should:
- Lead with a clear hero verb in display weight
- Spell out what will happen
- Use destructive role for the primary CTA when destructive
- Have a subtle "undo" affordance where possible

### VoteOnAppealSheet, AppealFineSheet

**Status: 🟡 Polish needed** (high stakes voting flow)

Voting is identity-defining for ruul. These sheets should feel
weighty — `RuulCard.glass`, large vote-choice buttons with haptic
feedback, real-time counts via VoteCountsBar.

### CancelAttendanceSheet

**Status: 🟡 Need audit pass**

---

## Onboarding (10 views)

**Status: ✅ At bar** — per prior commits "feat(onboarding) ..." and
"f5d5391 fix(onboarding): persist createdGroup". Specific views:

- `WelcomeView` — gold standard, mesh background + display title
- `FounderIdentityView` — clean
- `TemplateSelectorView` — single card per template, accent for selected
- `GroupIdentityView` — name + cover picker
- `GroupVocabularyView` — chips
- `InitialRulesView` — toggle list with edit affordance for amounts
- `GovernanceConfigView` — 3 cards with sliders (Bloque 6) — 🟡 the
  segmented controls work but could be richer
- `InviteMembersView` — phone picker + skip
- `PhoneVerifyView` / `OTPVerifyView` — clean OTP flow
- `ConfirmationView` — celebratory with 3 path buttons

Onboarding is a strength. Don't touch unless explicit request.

---

## SignInView (returning user)

**Status: ✅ At bar** (commit 8a2101c)

---

## Components (DS primitives)

| Primitive | Status | Notes |
|---|---|---|
| `RuulButton` | ✅ | Multiple sizes/styles, fillsWidth option |
| `RuulCard` | ✅ | `.glass` / `.tile` / `.plain` variants |
| `RuulAvatar`, `RuulAvatarStack` | ✅ | Group rendering, initials fallback |
| `RuulCoverView`, `RuulCoverCatalog` | ✅ | Procedural mesh, breathing animation |
| `RuulMeshBackground` | ✅ | Cool/violet/aqua variants |
| `RuulSegmentedControl` | ✅ | Used in onboarding |
| `RuulOTPInput` | ✅ | Auto-submit on full code |
| `RuulCapsuleButton` | ✅ | Compact CTA pill |
| `RuulTimelineItem` | ✅ | Used by history |
| `ActionCard` | ✅ (round 2) | Now has `meta` slot |
| `EventRow` | ✅ (round 1) | New compact event row |
| `EmptyStateView` | ✅ | Canonical pattern |
| `LoadingStateView` | ✅ | Canonical pattern |
| `ErrorStateView` | ✅ | Canonical pattern |
| `ResourceTabBar` | ✅ | Universal tab chrome |
| `OnboardingScreenTemplate` | ✅ | Standard onboarding step container |
| `ModalSheetTemplate` | ✅ | Standard sheet container |

All DS primitives are at bar. The work is in HOW views compose them.

---

## Cross-cutting concerns

### 1. Haptics
**Status: 🟡 Inconsistent**

`.ruulPress` button style fires light impact on press across most
buttons. But:
- Tab switches don't fire `.selection` haptic
- Toggle changes don't fire `.selection`
- RPC success/failure doesn't fire feedback
- Destructive confirmations don't fire warning

Fix scope: add `.sensoryFeedback(...)` modifiers strategically.
Estimated: 2 hours touching ~15 sites.

### 2. Reduce Motion
**Status: 🟡 Partial**

`RuulCoverView` honors `accessibilityReduceMotion`. But other
animations (`.ruulSnappy`, `.ruulMorph`) might not — needs audit.

### 3. Dynamic Type
**Status: 🟡 Untested**

App likely renders OK at default size but I haven't tested at
xxxLarge. Probably some clipping in chip rows + EventRow.

### 4. VoiceOver
**Status: 🟡 Untested**

Most primitives have `accessibilityLabel`. Some custom views (e.g.
my recent quick-switcher chip strip) need a tab-through audit.

### 5. Snapshot tests
**Status: 🔴 Missing**

Principle #11 calls for snapshot tests on every view × {default,
loading, filled, error} × {light, dark, HC}. Zero exist today. Adding
the harness is a separate sprint (~1 week).

---

## Priority queue (ranked by impact × effort)

1. 🔴 **Profile tab redesign** — biggest UX gap; users expect their
   profile under "Yo" tab. Build `ProfileView` with hero + nav links.
   ~3-4 hrs.

2. 🟡 **RulesView polish** — refactor `ruleCard` to `RuulCard` primitive,
   add module sectioning. ~30 min.

3. 🟡 **Voting sheets polish** — `VoteOnAppealSheet`, `AppealFineSheet`
   are identity-defining. Currently functional. Make weighty. ~1.5 hrs.

4. 🟡 **Confirmation sheets audit** — Cancel/Close/RemindAttendees pass.
   ~1 hr.

5. 🟡 **Hero card data completeness** — batch-load RSVP + attendees in
   HomeCoordinator + MyFeedCoordinator so EventCard renders real
   numbers, not zeros. ~1 hr.

6. 🟡 **Haptic audit** — 2 hrs.

7. 🟡 **Dynamic Type + VoiceOver audit** — 2-3 hrs.

8. 🟡 **MyFinesView "all clear" hero** — when totalOutstanding = 0,
   show celebratory state. ~20 min.

9. 🔴 **Snapshot test harness** — 1 week.

**Total estimated work to call V1 visually "perfect": ~15-20 hrs of
focused design pass plus 1 week of test infra.**

That's 2-3 dedicated design sessions of 4-6 hours each, plus an infra
sprint, before "perfect" is honest. Anyone promising it in one
session is lying.

---

## What I'm shipping in this session

Rounds 1-3 of the design lift:
- Round 1: DesignPrinciples.md + EventRow primitive + MyFeedView rewrite
- Round 2: ActionCard.meta + ActionInboxView refactor
- Round 3: HomeView upcoming list (heavy → compact) + empty-state
  consistency in MyFeedView + GroupHistoryView

Plus this audit doc as the canonical refactor backlog.

What still needs lift (priority order above): Profile tab,
voting sheets, confirmation sheets, hero data completeness, RulesView
polish, haptics audit, accessibility audit, snapshot tests.
