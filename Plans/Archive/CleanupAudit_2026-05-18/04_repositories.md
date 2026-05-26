# Repository Layer Audit — Ruul iOS

## 1. Repository inventory (40 repos, 9,624 LOC)

| Repo | Proto | Live | Mock | LOC | Consumers | Verdict |
|---|---|---|---|---|---|---|
| GroupsRepository | Y | Y | Y | 1105 | 15 | REWRITE/SPLIT |
| RuleTemplateRepository | Y | Y | Y | 767 | 3 | SPLIT (catalog → data) |
| RuleRepository | Y | Y | Y | 667 | 5 | SPLIT (Intercepting → service) |
| EventRepository | Y | Y | Y | 474 | 8 | KEEP (large but cohesive) |
| AssetLifecycleRepository | Y | Y | Y | 441 | 0 | KEEP, no consumer yet |
| AppealRepository | Y | Y | Y | 420 | 3 | KEEP (cohesive workflow) |
| SpaceLifecycleRepository | Y | Y | Y | 409 | 0 | KEEP, no consumer yet |
| FundRepository | Y | Y | Y | 330 | 2 | KEEP |
| LedgerRepository | Y | Y | Y | 291 | 3 | KEEP |
| RightRepository | Y | Y | Y | 289 | 0 | KEEP, no consumer yet |
| FineRepository | Y | Y | Y | 288 | 5 | KEEP |
| VoteRepository | Y | Y | Y | 251 | 10 | KEEP |
| SlotLifecycleRepository | Y | Y | Y | 219 | 0 | KEEP, no consumer yet |
| GroupPolicyRepository | Y | Y | Y | 209 | 4 | KEEP |
| SystemEventRepository | Y | Y | Y | 196 | 2 | KEEP |
| ResourceSeriesRepository | Y | Y | Y | 188 | 1 | KEEP |
| SpaceRepository | Y | Y | Y | 186 | 0 | KEEP |
| ProfileRepository | Y | Y | Y | 185 | 3 | KEEP |
| InviteRepository | Y | Y | Y | 177 | 2 | KEEP |
| ResourceLinkRepository | Y | Y | Y | 174 | 0 | KEEP |
| ResourceCapabilityRepository | Y | Y | Y | 161 | 0 | KEEP |
| ResourceRepository | Y | Y | Y | 159 | 3 | KEEP |
| ClaimRepository | Y | Y | Y | 159 | 0 | KEEP |
| UserActionRepository | Y | Y | Y | 148 | 3 | KEEP |
| RSVPRepository | Y | Y | Y | 147 | 2 | MERGE → EventRepository or keep |
| ResourceDraftRepository | Y | Y | Y | 147 | 0 | KEEP |
| BookingRepository | Y | Y | Y | 139 | 0 | KEEP |
| SpaceProjectionRepository | Y | Y | Y | 136 | 0 | KEEP |
| VoteCastRepository | Y | Y | Y | 134 | 2 | KEEP (separate from VoteRepo by design) |
| GroupSummaryRepository | Y | Y | Y | 130 | 2 | KEEP (projection) |
| SlotRepository | Y | Y | Y | 128 | 0 | KEEP |
| BalanceRepository | Y | Y | Y | 119 | 1 | KEEP |
| PlaceholderMemberRepository | Y | Y | Y | 116 | 0 | KEEP |
| EventLifecycleRepository | Y | Y | Y | 104 | 0 | KEEP |
| RsvpActionRepository | Y | Y | Y | 88 | 0 | DELETE? (no consumers, overlaps RSVP) |
| NotificationTokenRepository | Y | Y | Y | 88 | 0 | KEEP (used by AppState) |
| CheckInRepository | Y | Y | Y | 85 | 2 | MERGE → RSVP (single eventId surface) |
| NotificationPreferenceRepository | Y | Y | Y | 73 | 0 | KEEP (used in view, see consumer note) |
| MyActivityRepository | Y | Y | Y | 67 | 0 | DELETE? (no consumers) |
| RuleShapeRepository | Y | Y | Y | 30 | 0 | KEEP (placeholder) |

Consumer counts grep `XxxRepository` in `RuulFeatures`; some repos are used via AppState (e.g. `NotificationToken`, `NotificationPreference`) and won't show up here — confirm before deleting.

## 2. Missing pieces

- **None on the doctrine axis.** Every repo has protocol + Live + Mock. Naming convention `MockXxxRepository` / `LiveXxxRepository` is consistent across all 40 files.
- **PermissionRepository** doesn't exist as a standalone repo — permission resolution lives inside `GroupPolicyRepository.resolve(...)` and a server `has_permission` RPC. Doctrine doesn't require it as a separate repo; current placement is acceptable.

## 3. Monster repos (>400 LOC)

| Repo | LOC | Why | Suggested split |
|---|---|---|---|
| **GroupsRepository** | 1105 | 70 funcs across groups, members, invite code, avatar, modules, archive, RolesV2, governance jsonb | Split into: `GroupsRepository` (CRUD + list/get), `GroupMembersRepository` (members, turn order, remove, leave), `GroupRolesRepository` (assign/unassign/upsert/delete role, permissions), `GroupAvatarRepository` (storage upload), `GroupModuleRepository` (`setModule`). Keep `updateGovernance` in main since it's a single field. |
| **RuleTemplateRepository** | 767 | ~70% of the file is a hard-coded `defaultBetaCatalog: [RuleBuilderTemplate]` (19 templates) + a static `triggerResourceTypes` map. Repo file holds catalog data. | Extract `RuleTemplateCatalog.swift` (static catalog → `RuulCore/Templates/`); repo file shrinks to ~150 LOC of CRUD + RPC. |
| **RuleRepository** | 667 | Contains `MockRuleRepository`, `LiveRuleRepository`, **and** `InterceptingRuleRepository` (a governance-policy-orchestration decorator) | Move `InterceptingRuleRepository` → `Services/RuleGovernanceCoordinator.swift`. It's a domain service that composes 3 repos + opens votes — not a repo. |
| **EventRepository** | 474 | 14 cohesive funcs all about events | KEEP as-is. |
| **AssetLifecycleRepository** | 441 | 10 lifecycle verbs (custody/maintenance/damage/transfer/valuation/check-in-out/usage) | KEEP — verbs are a single bounded workflow. |
| **AppealRepository** | 420 | 8 funcs across read + write of appeal-vote workflow | KEEP — coherent. |

## 4. Duplicated scope

- **RSVPRepository / RsvpActionRepository / CheckInRepository** — three repos all touching the RSVP table. `RsvpActionRepository` has zero consumers; `CheckInRepository` is a 3-func wrapper on top of what `RSVPRepository.setRSVP` already does. Recommendation: MERGE CheckIn into RSVP, DELETE RsvpActionRepository.
- **VoteRepository / VoteCastRepository** — both touch voting. Currently split read (`Vote`) vs write (`VoteCast`). Acceptable per doctrine; KEEP.
- **AppealRepository** also handles `castVote`/`closeVote` against an `appeals` workflow — overlaps conceptually with `VoteRepository`. Per current schema appeals are a separate `appeals` table; KEEP separate.
- **EventRepository ↔ EventLifecycleRepository / SpaceRepository ↔ SpaceLifecycleRepository / SpaceProjectionRepository / AssetLifecycleRepository / SlotRepository ↔ SlotLifecycleRepository** — intentional CRUD-vs-lifecycle separation, matches ontology constitution. KEEP.
- **GroupsRepository.removeMember vs leaveGroup vs setTurnOrder vs assignRole** — member-management surface is sprawled. See Section 3 split.

## 5. Domain / transport mixing

| Repo | Mixing |
|---|---|
| **InterceptingRuleRepository** (inside `RuleRepository.swift`) | Pure domain orchestration: calls `policyRepo.resolve`, builds `PendingChangeEnvelope`, opens a vote, composes/decomposes audit envelopes. Should be a Service. |
| **RuleTemplateRepository** | Holds template catalog data (~570 LOC of `RuleBuilderTemplate(...)` literals + `triggerResourceTypes` static map). Catalog ≠ transport. |
| **MockRuleRepository.seedTemplateRules** | Reads from `DinnerRecurringTemplate.defaultRules(...)` — fine for a mock, but couples mock to a specific template. |
| **GroupsRepository** | `updateGovernance` accepts `GovernanceRules` value-types and serializes them; light mapping only — acceptable. |
| Others | Looked clean — methods are 1:1 with RPC/table calls plus row→model mapping. |

## 6. Views calling Supabase directly

- **0 violations** in `Packages/RuulFeatures/Sources/RuulFeatures/**`.
- `rg "import Supabase"` returns a single hit: `/Users/jj/code/tandas/ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Auth/SignInView.swift:4` — Auth uses the SDK directly for OTP. Acceptable per architecture (auth is the one place the SDK leaks).
- `rg "client\.from\(|client\.rpc\("` in Features: zero matches.

**Verdict: doctrine respected.**

## 7. Verdict per repo

- **REWRITE/SPLIT:** GroupsRepository (1105 LOC → 5 files).
- **SPLIT:** RuleTemplateRepository (extract catalog), RuleRepository (extract `InterceptingRuleRepository` → service).
- **MERGE:** CheckInRepository → RSVPRepository.
- **DELETE (candidates, verify no AppState binding):** RsvpActionRepository (0 consumers, overlap RSVP), MyActivityRepository (0 consumers).
- **KEEP:** all 34 others.

## 8. Beta blockers

None block Beta-1. Doctrine is well-enforced. Risks are maintenance, not shipping:

1. **`GroupsRepository` at 1105 LOC / 70 funcs is the only true hotspot.** Risk: merge conflicts, slow Swift compile, hard for new contributors. Split post-Beta.
2. **`InterceptingRuleRepository` mislabelled** — it's a domain coordinator masquerading as a repo. Will confuse anyone wiring DI; move to `Services/` post-Beta.
3. **`RuleTemplateRepository` catalog** — 19 `RuleBuilderTemplate` literals inside the repo file. If a designer iterates on templates, they touch transport code. Extract catalog file post-Beta.
4. **Dead repos (RsvpAction, MyActivity, possibly Right/Slot/Booking/Space*/AssetLifecycle with 0 Features consumers)** — confirm via AppState wiring before deleting.

Files referenced:
- `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupsRepository.swift`
- `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Repositories/RuleRepository.swift` (lines 482–667 = `InterceptingRuleRepository`)
- `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Repositories/RuleTemplateRepository.swift` (lines 125–553 = catalog)
- `/Users/jj/code/tandas/ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Auth/SignInView.swift` (only direct `import Supabase` in Features)
