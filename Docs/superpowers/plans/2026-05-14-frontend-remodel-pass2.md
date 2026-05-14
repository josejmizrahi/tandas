# Frontend Remodel — Pass 2: AppShell canonical 5-tab inventory

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy 5-tab inventory (`home · group · create · decisions · profile`) with the AppShell canonical 5-tab (`home · inbox · create · activity · profile`). Delete `Features/Group/`. Centralize Create with a TypePicker. Unify `Features/Groups/` sub-folders.

**Branch:** `pass2/appshell-canonical` (worktree created via EnterWorktree).

**Test command:** `make -C ios test` (xcodebuild + iPhone 17 Pro simulator). Baseline: 182 tests / 37 suites green.

**Tech stack:** Same as Pass 1 — Swift 6 strict concurrency, SwiftUI iOS 26, `@Observable`, Swift Testing.

## Surface map (post-Pass-1 state)

- `Features/Shell/` — RootShell, RootShellState, RootRouter, RootShellSheets, Tabs/{Home,Group,CreateTabIntercept,Decisions,Profile}Tab.swift
- `Features/Group/` — 7 files (GroupTabView 507L deprecated, plus Overview/Members/Money/More sub-tabs) — **all dies in Pass 2**
- `Features/Groups/` — 9 sheets (CreateGroupSheet, GroupSwitcherSheet, etc.)
- `Features/Inbox/` — InboxCoordinator + ActionInboxView (sub-section of Home today)
- `Features/History/` — GroupHistoryCoordinator + GroupHistoryView + HistoryTabView (linkout today)
- `Features/Rules/` — RulesView etc. (was Decisions tab content)
- `RootShellState.RootTab` — `home, group, create, decisions, profile` (Pass 2 changes)

## Tasks

### Task 1 — Baseline + worktree marker

- [ ] Verify clean state, run `make -C ios test`, empty commit baseline marker.
- [ ] Commit: `chore(pass2): start appshell-canonical branch`

### Task 2 — Rename `RootTab.group → .inbox` and `.decisions → .activity`

Update the enum in `RootShellState.swift`. Update `handleTabSelection` in `RootRouter.swift` if it references the old names anywhere. Then update `RootShell.swift` TabView body: swap GroupTab + DecisionsTab for new InboxTab + ActivityTab placeholders (one-line wrappers that just render `Color.clear` for now — Tasks 3 + 4 fill them in).

- [ ] `make -C ios build` green
- [ ] `make -C ios test` green (need to update any tests referencing `.group` or `.decisions`)
- [ ] Commit: `feat(shell): rename RootTab .group→.inbox, .decisions→.activity`

### Task 3 — Build `Features/Inbox/Views/InboxView.swift` with filter chips

Existing `ActionInboxView.swift` is the inbox renderer. Create a new `InboxView.swift` that wraps it with a horizontal filter-chips strip at the top:
- Chips: `All · Urgent · Approvals · Votes · Payments · Requests · Confirmations · Reminders`
- Selecting a chip filters the underlying `InboxCoordinator.actions` by mapping each chip → set of `actionType` values
- Default selection: `All`
- Chip style: `RuulChip` if it exists; otherwise a tracked-uppercase pill with selected/unselected states using DS tokens

Then update `InboxTab.swift` (from Task 2 placeholder) to render `InboxView(coordinator:)` with `@Environment(RootRouter.self) private var router` to wire the action-tap handler:
- The handler dispatches per actionType to `router.openX()` methods (use the same dispatch logic that's in `HomeTab.onInboxActionTap`).

Update `HomeView.swift` to remove the embedded "Pendientes" section (it's a top-level tab now). Keep `NeedsAttention` as a preview with urgency ≥ medium.

- [ ] `make -C ios build` green
- [ ] `make -C ios test` green
- [ ] Commit: `feat(inbox): promote Inbox to top-level tab with filter chips`

### Task 4 — Rename `GroupHistoryView` → `ActivityView`, move to `Features/Activity/`

```bash
mkdir -p ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Activity/Views
mkdir -p ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Activity/Coordinator
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/History/Views/GroupHistoryView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Activity/Views/ActivityView.swift
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/History/GroupHistoryCoordinator.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Activity/Coordinator/ActivityCoordinator.swift
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/History/Views/HistoryItemPresentation.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Activity/Views/HistoryItemPresentation.swift
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/History/Views/HistoryTabView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Activity/Views/ActivityTabView.swift
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/History/Views/SystemEventDetailView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Activity/Views/SystemEventDetailView.swift
```

Rename types via sed across `ios/`:
- `GroupHistoryView` → `ActivityView`
- `GroupHistoryCoordinator` → `ActivityCoordinator`
- `HistoryTabView` → `ActivityTabView`

Add filter chips to `ActivityView`: `All · Money · Resources · Governance · Members` (5 categories). Filter maps to `system_event.event_type` prefix or category.

Update `ActivityTab.swift` (from Task 2 placeholder) to render the new `ActivityView(coordinator:)`.

Update `RootShellState.swift` to add `activityCoordinator: ActivityCoordinator?` field (replacing `groupHistoryCoordinator`). Update `RootShell.rebuildCoordinators` to construct ActivityCoordinator instead.

- [ ] `make -C ios build` green
- [ ] `make -C ios test` green
- [ ] Commit: `feat(activity): promote Activity to top-level tab, rename from History`

### Task 5 — Delete `Features/Group/` and distribute content

The 7 files in `Features/Group/`:
- `Views/GroupTabView.swift` (507L, deprecated in Pass 1) — DELETE outright
- `Overview/GroupOverviewSubTab.swift` (449L) — distribute content to HomeView (member ramp section + recent activity preview) or to GroupInfoSheet; whichever fits
- `Members/MembersSubTab.swift` + `Members/MembersSubTabCoordinator.swift` — fold into `GroupInfoSheet` as a "Members" section
- `Money/GroupMoneyView.swift` (394L) + `Money/GroupMoneyCoordinator.swift` — move to `Features/Activity/Views/MoneyView.swift` so users access via Activity tab + Money filter, OR fold into `ProfileView.MyBalances` (cross-group view of money). Pick the simpler option.
- `More/GroupMoreSubTab.swift` — distribute remaining entries (link out to GroupSettingsSheet, ProfileView settings)

Update `GroupTab.swift` (still exists from Task 2 — it was a wrapper around GroupTabView) — DELETE the wrapper (it's unused once .group is renamed to .inbox).

Verify zero remaining references to deleted types.

- [ ] `make -C ios build` green
- [ ] `make -C ios test` green
- [ ] Commit: `refactor(groups): delete Features/Group/ — content distributed to Home/Activity/Sheets`

### Task 6 — TypePicker in `ResourceWizardSheet`

Add a tile catalog at the top of `ResourceWizardSheet.swift`:
- 6 category tabs: `Popular · Coordination · Money · SharedThings · Governance · Custom`
- Each category renders tiles for the resource types creatable in the active group
- Driven by `CapabilityResolver.creatableTypes(group:)` (verify this method exists; if not, add it as a one-liner that returns `[ResourceType]` filtered by enabled modules + template + permissions)
- Tap a tile → `ResourceWizardCoordinator` pre-fills the type and routes to the builder

Pass 2 only adds the TypePicker UI — the per-type builders are pre-existing.

- [ ] `make -C ios build` green
- [ ] `make -C ios test` green
- [ ] Commit: `feat(create): TypePicker with 6 categories in ResourceWizardSheet`

### Task 7 — Unify `Features/Groups/` structure

Create sub-folders:

```bash
mkdir -p ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/{Switcher,Settings,Members,Invites}
```

Move existing files:
- `CreateGroupSheet.swift` → `Invites/CreateGroupSheet.swift` (group creation is invite-adjacent)
- `JoinGroupSheet.swift` → `Invites/JoinGroupSheet.swift`
- `GroupSwitcherSheet.swift` → `Switcher/GroupSwitcherSheet.swift`
- `GroupInfoSheet.swift` → `Switcher/GroupInfoSheet.swift` (group info presented from switcher)
- `GroupSettingsSheet.swift` → `Settings/GroupSettingsSheet.swift`
- `GovernanceSettingsView.swift` → `Settings/GovernanceSettingsView.swift`
- `GroupRulesCoordinator.swift` → `Settings/GroupRulesCoordinator.swift`
- `GroupRulesSettingsView.swift` → `Settings/GroupRulesSettingsView.swift`
- `EditMembersSheet.swift` → `Members/EditMembersSheet.swift`

Plus any MembersSubTab content folded into `Members/` from Task 5.

Type names unchanged → zero callsite updates needed.

- [ ] `make -C ios build` green
- [ ] `make -C ios test` green
- [ ] Commit: `refactor(groups): unify Features/Groups/ into Switcher/Settings/Members/Invites`

### Task 8 — Final metrics + PR

Verify:
- `RootTab.allCases` == `[.home, .inbox, .create, .activity, .profile]`
- `Features/Group/` directory removed
- `Features/Inbox/Views/InboxView.swift` exists
- `Features/Activity/Views/ActivityView.swift` exists
- 0 references to `GroupTabView`, `GroupOverviewSubTab`, `MembersSubTab`, `GroupMoreSubTab`, `GroupHistoryView`, `GroupHistoryCoordinator`

Push branch + open PR.

- [ ] Final marker commit + metrics report
- [ ] `git push origin HEAD:pass2/appshell-canonical`
- [ ] `gh pr create ...`

## Risks

- **Deeplinks**: any deeplink targeting `.group` or `.decisions` needs to reroute. Pass 1 deeplinks (event, ruleChange) target detail/edit sheets, not tabs — they survive.
- **InboxCoordinator dispatch logic**: pulling out from HomeTab requires preserving the `onInboxActionTap` async dispatch chain. The router has `openX()` helpers; reuse them.
- **GroupMoneyView**: 394L of money UI. Folding into ProfileView or Activity may need additional context. If too risky, leave as a `Features/Money/` folder its own task.
- **GroupOverviewSubTab**: 449L — its content might not have a clean home in HomeView. If a section is genuinely vertical-specific (e.g. "founder onboarding banner"), park it in GroupInfoSheet.

## DoD

- 5 tabs literal match with AppShell.md (`home · inbox · create · activity · profile`)
- `Features/Group/` removed entirely
- `Features/Groups/` organized into 4 sub-folders
- All tests green; 182+ count preserved (may add a few new tests for the renamed types)
- Manual smoke (founder): tab inventory matches; inbox chips filter correctly; activity timeline renders; group switcher still works.
