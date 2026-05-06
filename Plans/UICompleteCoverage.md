# Plan — Complete UI Coverage of Backend

> Goal: every backend feature (table / RPC / edge function) has a
> matching iOS surface. No dead backend code. No orphan UI.
> Apple-grade quality across all of it.

This is the canonical plan for the multi-session UI completeness sprint.
Read top-to-bottom before touching code. The next session executes the
priority queue (section 4).

---

## 0. Read first (mandatory bootstrap)

1. `Docs/DesignPrinciples.md` — the bar. Every new view passes this checklist.
2. `Docs/UXAudit.md` — view-by-view current status with detailed fixes.
3. `Docs/Platform.md` — the 7 primary citizens + reactive flow.
4. `Plans/Phase1.md` — overall V1 plan with 13 bloques + decision log.

**Working directory**: `/Users/jj/code/tandas`. NOT `/Users/jj` (qb19).

**Build recipe** (use exactly):
```bash
cd /Users/jj/code/tandas/ios && xcodegen generate >/dev/null 2>&1 \
  && xcodebuild -scheme Tandas -project Tandas.xcodeproj \
       -destination 'generic/platform=iOS' -configuration Debug build 2>&1 \
  | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|\*\* )" | head -10
```

**Device install** (after BUILD SUCCEEDED):
```bash
APP_PATH="/Users/jj/Library/Developer/Xcode/DerivedData/Tandas-boyegkhwdcwcfycscxyuqxpgapwa/Build/Products/Debug-iphoneos/Tandas.app"
xcrun devicectl device install app \
  --device E63668BF-3B28-5F51-B678-519B203E48CC \
  "$APP_PATH" 2>&1 | tail -3
```

---

## 1. Best practices specific to this project

Distilled from prior sessions. Violating these wastes hours.

### Architecture
- **Repositories are actors** (`AppealRepository`, `FineRepository`, etc.). Coordinators are `@Observable @MainActor`. Views are SwiftUI structs with no business logic.
- **Mock + Live** for every repo. Mock first; tests use Mock.
- **Single source of truth**: `AppState` holds session + active group + repo refs. Coordinators consume from there.
- **Two card densities only**: hero (full cover) and compact row (thumbnail + content). See `EventCard` (hero) vs `EventRow` (compact).
- **Composition over variants**: add a parameter to an existing primitive before creating a new component (DesignPrinciples #12). Example: `ActionCard.meta` slot was added instead of `ActionCardWithGroupLabel`.

### Visual
- **Cover IS the card** for heroes. Vignette + white text overlay. Reference `EventCard.swift`.
- **Status as colored dot + uppercase tracked label**. Never tinted background fills on chrome (only on photo overlays).
- **Date language, not date strings**: use `Date.ruulRelativeDescription`, `.ruulShortTime`, `.ruulShortDate`. Never `DateFormatter` ad-hoc.
- **Spacing on 4pt grid only**. `RuulSpacing.s1` to `s12`. Magic numbers are bugs.
- **Typography tokens only**. `RuulTypography.displayLarge`, `headline`, `body`, `caption`, `sectionLabel`, `statSmall`, etc. Never `.font(.system(size: 18, ...))`.
- **`.buttonStyle(.ruulPress)`** on every interactive surface (haptic + scale 0.97 + opacity).
- **Group context navigation**: use a `Menu` attached to the group name in headers. NOT a chip strip. NOT a separate icon. The group-name-as-Menu is the iOS-native pattern (Calendar.app, Mail.app).

### Empty / loading / error
- Use `EmptyStateView` primitive. Custom inline empty states are technical debt.
- Use `LoadingStateView` and `ErrorStateView` primitives. Bare `ProgressView()` only for splash/bootstrap.

### Rule engine + system events
- `SystemEventType` enum must include EVERY case the server emits. If you add a new RPC that inserts a `system_events` row, add the case to the Swift enum or the iOS decoder will crash at read time. Bug latent ≥ 3 times in past sessions.
- Same for `ConditionType` and `ConsequenceType` — Swift enum and `_shared/ruleEngine.ts` evaluators must be in sync.

### Build + filesystem
- **SourceKit lies**. Errors like `Cannot find type X` in editor are false positives. Trust `xcodebuild build` output only.
- **xcodegen generate** when adding/renaming/deleting Swift files. Skipping it means new files don't compile.
- **macOS is case-insensitive**. `Docs/` and `docs/` are the same path on disk but different in git. Be deliberate. Already paid this cost once.
- Always `cd /Users/jj/code/tandas/ios` before `xcodebuild`.

### Permissions / governance
- **Never hardcode `member.role == "admin"`**. Always go through `GovernanceService.canPerform(action, member, in: group, context:)`.
- For `.closeEvents` action, pass `.event(hostId: event.hostId)` as context.
- `.requiresVote` decisions: caller opens a `Vote` via `VoteRepository.startVote` and reacts on `voteResolved`.

### Cross-group views
- All "my X" views (inbox, fines, history) read from RLS-scoped queries with no `group_id` filter. Display the group label per row when the user has 2+ groups.
- See `MyFeedView`, `ActionInboxView`, `MyFinesView` for the pattern.

### Git + commits
- Commit per coherent change (one feature / one fix / one refactor). Don't bundle unrelated changes.
- Commit message: subject line + blank + body explaining what + why. Trailers like `Co-Authored-By: claude-flow <ruv@ruv.net>` are convention.

---

## 2. Backend inventory — what exists in prod

### Tables (25)
- **Identity**: `profiles`, `groups`, `group_members`, `invites`, `notification_tokens`, `otp_codes`
- **Events**: `events`, `event_attendance`, `resources`, `system_events`, `user_actions`
- **Voting**: `votes`, `vote_casts`, `appeals`, `appeal_votes`, `vote_ballots` (legacy)
- **Fines**: `fines`, `fine_review_periods`
- **Money / fund**: `pots`, `pot_entries`, `expenses`, `expense_shares`, `payments`
- **Templates / rules**: `templates`, `rules`

### RPCs (51)
**Currently consumed by iOS**:
`create_group_with_admin`, `join_group_by_code`, `update_group_config`,
`create_event_v2`, `set_rsvp_v2`, `check_in_v2`, `close_event`, `cancel_event`,
`propose_rule`, `seed_dinner_template_rules`,
`start_appeal`, `cast_appeal_vote`, `close_appeal_vote`,
`pay_fine`, `record_system_event`, `mark_invite_used`,
`group_setting`, `group_governance_level`,
`start_vote`, `cast_vote`, `finalize_vote` (Bloque 4, no UI consumer yet),
`promote_from_waitlist`.

**Has RPC but NO UI entry** (the gap):
- `issue_manual_fine` — host can issue fine without rule engine
- `void_fine` — admin/host can void
- `officialize_fine` — manual officialize (cron does it; UI for edge cases)
- `close_event_no_fines` — close without firing rules
- `set_turn_order` — change rotation order
- `roll_event_series` — recurrence series management
- `create_expense_with_shares` — expense splitter
- `close_pot` — pot/fund finalization

### Edge Functions (11)
Cron + sync, all deployed:
- `process-system-events`, `evaluate-event-rules`, `auto-close-events`, `auto-generate-events`
- `finalize-votes`, `finalize-fine-reviews`, `send-fine-reminders`, `emit-deadline-events` (Bloque 8)
- `send-otp`, `verify-otp`, `send-whatsapp-invite`
- Stubs: `send-event-notification` (APNs not configured), `generate-wallet-pass` (cert not configured)

---

## 3. Existing UI surfaces

| Surface | Status |
|---|---|
| **Onboarding** (11 views) | ✅ at bar |
| **HomeView** | ✅ at bar (round 3 + Menu refactor) |
| **EventDetailView** + subviews | ✅ at bar |
| **CreateEventView** / **EditEventView** | ✅ at bar |
| **PastEventsView** | ✅ at bar |
| **CheckInScannerView** | ✅ at bar (camera-only) |
| **ActionInboxView** | ✅ at bar (round 2) |
| **RulesView** (read-only) | 🟡 polish needed |
| **MyFinesView** + **FineDetailView** | ✅ at bar |
| **ReviewProposedFinesView** | 🟡 audit needed |
| **VoteOnAppealSheet** + **AppealFineSheet** | 🟡 weighty pass needed |
| **MyFeedView** (cross-group) | ✅ at bar (round 1) |
| **GroupHistoryView** | ✅ at bar (round 3) |
| **ProfileView** (round 4 NEW) | ✅ at bar |
| **GroupSwitcherSheet/InfoSheet/SettingsSheet** | ✅ at bar |
| **CreateGroupSheet** / **JoinGroupSheet** | 🟡 audit needed |
| **CancelEventSheet/CloseEventSheet/RemindAttendeesSheet/MemberQRSheet** | 🟡 audit needed |
| **ShareEventSheet** | ✅ at bar |
| **CancelAttendanceSheet** | 🟡 audit needed |

---

## 4. Priority queue — what's missing, ranked

Format: `[priority] surface — backend it covers — effort`

### P0 — Identity-defining gaps (build first)

1. ~~**EditRulesView + EditRuleSheet**~~ ✅ shipped 2026-05-05 (commits `b86876b..b07f6b8`)
   - Backend: `rules` table, `propose_rule` RPC, `governance.whoCanModifyRules`
   - Today: RulesView is read-only. Founders can't edit amounts, toggle, add. Killer for V1 daily use.
   - Effort: ~4-5h
   - DoD: Founder (or other based on governance) can toggle rule active, edit fine amount, add new rule from template, archive rule. Goes through GovernanceService gate.
   - **Known follow-ups from V1 implementation:**
     - **`RuleSummaryFormatter` unintegrated** (~1h, P3). Implemented in `Features/Rules/RuleSummaryFormatter.swift` but `EditRuleSheet`'s "CÓMO FUNCIONA" section currently shows `rule.description` as fallback because `GroupRule` does not carry `trigger` + `conditions` fields (only the platform `Rule` model does). Hydrate `GroupRule` with the decoded trigger + conditions on `RuleRepository.list(...)` so the formatter actually renders. Code is dead until then.
     - **Spec process improvement**: the spec assumed `finalize_vote` archived rules on `rule_repeal` pass — it didn't. Migration 00026 was added mid-execution to close the gap. Future specs that touch existing RPCs/triggers should include a "Backend assumptions verified" section with concrete `grep`/SQL queries against the actual function bodies before approval.

2. **GovernanceSettingsView**
   - Backend: `groups.governance` jsonb, `updateGovernance` repo method
   - Today: only set during onboarding step 6. After that, unreachable.
   - Effort: ~2-3h
   - DoD: Linked from RulesView and from ProfileView/Group settings. Same form as `GovernanceConfigView` but for an existing group. Triggers a vote when whoCanModifyGovernance != founder.

3. ~~**AddManualFineSheet**~~ ✅ shipped 2026-05-06 (commits `4499cc9..0bb7c7a`)
   - Backend: `issue_manual_fine` RPC
   - ~~Today: no entry point. Host can't fine someone outside the rule engine.~~
   - Effort: ~2h
   - DoD: Reachable from EventDetailView host actions. Member picker + amount + reason. Fine appears as `is_manual=true`, `auto_generated=false`, status `officialized`.

4. **VoidFineSheet** (host/admin action)
   - Backend: `void_fine` RPC
   - Today: no entry point.
   - Effort: ~1h
   - DoD: Reachable from FineDetailView for host/admin. Confirmation dialog with reason input. `void_fine` updates the row and emits a system event.

5. **OpenVotesView** + generic vote creation
   - Backend: `votes` (vote_type), `start_vote`, `cast_vote`, `finalize_vote`
   - Today: only `fine_appeal` has UI. The other 6 types (`rule_change`, `member_removal`, `fund_withdrawal`, `role_assignment`, `general_proposal`, `slot_dispute`) have zero entry points.
   - Effort: ~5-7h
   - DoD: New Universal/Voting/ section with `OpenVotesListView` (lists all open votes regardless of type), per-type detail views (or a generic one rendering `payload`), and per-type creation sheets. V1 minimum: `general_proposal` (any member can propose anything textual) and `rule_change` (founder or vote can change a rule).

### P1 — High-impact gaps

6. **Member management** in `GroupInfoSheet`
   - Backend: `group_members.roles[]`, `removeMembers` action, `set_turn_order`
   - Today: members shown as read-only list with admin badge.
   - Effort: ~3-4h
   - DoD: Long-press / context menu on a member: "Promover a admin", "Quitar del grupo" (gated by GovernanceService). Reorder turn handles via drag.

7. **Active Modules toggles**
   - Backend: `groups.active_modules`, `ModuleRegistry`
   - Today: invisible to user.
   - Effort: ~2-3h
   - DoD: New section in `GroupSettingsSheet` listing the 5 V1 modules with toggles. Disabling a module hides its UI surfaces but preserves data. Validates dependencies before save (`ModuleRegistry.validate`).

8. **Hero card data completeness**
   - Backend: existing RSVP / event_attendance / event_seat_count
   - Today: HomeView and MyFeedView hero cards pass `confirmedCount: 0, attendeeAvatars: [], myStatus: nil` because no batch loader.
   - Effort: ~2h
   - DoD: New `EventEnrichment` repo method that batch-loads RSVPs + attendees per event; coordinators populate hero cards properly.

9. **Avatar upload to Supabase Storage**
   - Backend: existing `avatars` bucket spec; upload missing
   - Today: PhotosPicker captures, never uploads.
   - Effort: ~2h
   - DoD: Bucket created (RLS: user can write own avatar URL), upload via `client.storage.from("avatars").upload(...)`, profile updated with public URL. Profile + Member rows show real avatar.

10. **Group cover edit (post-creation)**
    - Backend: `groups.cover_image_name`, `update_group_config`
    - Today: only set at onboarding step 3.
    - Effort: ~1h
    - DoD: GroupSettingsSheet exposes cover picker. Saves via existing RPC.

### P2 — Money + V2 features (likely a separate sprint)

11. **Pot / fund views** (`pots`, `pot_entries`)
    - Backend exists; zero UI.
    - Effort: ~6-8h
    - DoD: PotDetailView with balance, deposits/withdrawals timeline, contribute button, propose-withdrawal button (creates a vote of type `fund_withdrawal`), `close_pot` action for treasurer/founder.

12. **Expense splitter** (`expenses`, `expense_shares`)
    - Backend exists; zero UI.
    - Effort: ~6-8h
    - DoD: AddExpenseSheet with amount/payer/participants/split mode (equal/percentage/exact), settle screen showing who-owes-whom.

13. **Payment recording** (`payments`)
    - Backend exists; zero UI.
    - Effort: ~3-4h
    - DoD: PaymentMethodSheet for the user to record an external payment (cash/transfer) which marks fines paid.

14. **Notification preferences** (`notification_tokens`)
    - Backend exists; settings UI missing.
    - Effort: ~1-2h
    - DoD: Section in SettingsSheet — toggles per category (events, fines, votes, mentions). Persists to a new `notification_preferences` jsonb on profile.

### P3 — Polish + cross-cutting

15. **VoteOnAppealSheet weighty pass** — make voting feel weighty (haptics, RuulCard.glass, real-time counts via VoteCountsBar). ~1.5h
16. **Confirmation sheets audit** — Cancel/Close/RemindAttendees pass against principles. ~1h
17. **MyFinesView "all clear"** — celebratory state when totalOutstanding=0. ~30min
18. **RulesView polish** — ruleCard → RuulCard primitive, group by module. ~30min
19. **Haptic audit** — sensoryFeedback on tab switches, RPC outcomes, destructive confirmations. ~2h
20. **Dynamic Type + VoiceOver audit** — test xxxLarge, tab through with VoiceOver. ~3h
21. **Snapshot test harness** — establish per-view × theme snapshots. ~1 week
22. **Reduce Motion audit** — verify all `.ruulSnappy` / `.ruulMorph` honor the system flag. ~1h

---

## 5. Definition of done — per surface

Every new surface must satisfy:

- [ ] Reads `Docs/DesignPrinciples.md` checklist as part of the PR (not metaphorically — explicitly tick each item in commit body).
- [ ] Uses tokens for ALL spacing, color, typography, animation. Zero magic numbers.
- [ ] Reuses existing primitives (`RuulCard`, `RuulButton`, `RuulAvatar`, `RuulCoverView`, `EventCard`, `EventRow`, `ActionCard`, `RuulTimelineItem`) or adds a parameter to one rather than rolling its own.
- [ ] Empty / loading / error states use canonical primitives (`EmptyStateView` / `LoadingStateView` / `ErrorStateView`).
- [ ] `.buttonStyle(.ruulPress)` on every interactive surface.
- [ ] Date display uses `Date.ruulRelativeDescription` / `.ruulShortDate` / `.ruulShortTime` — no ad-hoc DateFormatter.
- [ ] Status indicators are colored dots + uppercase tracked labels.
- [ ] AccessibilityLabel on every interactive element.
- [ ] Smoke tested at Dynamic Type xxxLarge.
- [ ] Quick VoiceOver pass.
- [ ] Cross-group considered: if the data is per-group, decide whether to scope to active group or aggregate across — usually aggregate for "my X" views.
- [ ] Permission gates go through `GovernanceService`, never `member.role == "admin"`.
- [ ] If new SystemEvent emitted, case added to Swift `SystemEventType` enum AND `HistoryItemPresentation` switch AND `Docs/EventTypes.md`.
- [ ] If new ConditionType / ConsequenceType, same drill across the type enum + ts evaluator + corresponding Doc.
- [ ] Build passes via the recipe at the top.
- [ ] Installed to iPhone via `devicectl` and tested manually.
- [ ] One commit per surface with message format `feat(<scope>): <surface>`.

---

## 6. How to start

Pick the top P0 item (`EditRulesView`). Read its DoD. Estimate. If estimate is > 6 hours of focused work, split it into sub-PRs (e.g. EditRuleSheet first, then RulesView entry points).

**Do NOT batch multiple P0 items in one PR.** They each have separate
review / rollback semantics.

**Update this doc** as items land — strike them through, add new findings.

When the P0 list is empty, V1's identity is whole. P1+ is polish on top.

---

## 7. Open questions for the user (decide before starting)

1. **EditRulesView scope**: just toggle + edit amount, or full add-rule
   form? Adding a rule means picking trigger / conditions / consequences
   from menus — that's substantial. V1.0 = toggle + edit amount only?

2. **Generic Vote types in V1**: which non-`fine_appeal` types are
   actually shipping? Recommendation: `general_proposal` + `rule_change`.
   The others (`member_removal`, `fund_withdrawal`, `role_assignment`,
   `slot_dispute`) ship with their respective features.

3. **Manual fine UX**: should manual fines auto-officialize (skip the
   24h grace period) since the host issued them deliberately? Or go
   through the same flow as auto-proposed?

4. **Member removal**: voting required by default per current
   governance. Should the UI default to "propose vote" rather than
   "remove now" for clarity?

5. **Pot / fund**: defer to V2 explicitly? They're in the schema but
   may be premature. Decide before estimating P2.
