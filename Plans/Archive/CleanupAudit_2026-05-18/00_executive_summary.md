# Ruul Codebase Cleanup Audit — 2026-05-18

> **Read-only audit.** No code modified. 10 parallel agents covered architecture, resource detail UI, creation flow, repositories, models, edge functions, SQL/RPCs, tests, roles/permissions, and dead code/naming. Each agent's full report is in the sibling files (`01_…` through `10_…`).
>
> **Post-execution corrections** are tracked in **`11_post_execution_corrections.md`**. Several audit claims turned out to be wrong when cross-checked against the live Supabase project. Most notably: 3 edge functions flagged as "dead" were NOT dead (one was an intentional 503 stub, another was awaiting scheduling, a third had its cron simply named oddly). `myAtom` was never in the seed table. 7 of 9 "missing" SystemEventType cases were already explicitly allowlisted as deferred backlog. Audit done in parallel by source-only grepping; reality requires checking deployed state too.

---

## 1. Executive Summary

**Verdict: codebase is doctrinally sound, structurally sprawling.** The Talmudic ontology (Resource × Capability × Rule + Atoms × Projections) is enforced consistently at the data layer (Supabase migrations 00001..00326, atom guards on 7 append-only tables, RLS resolves through `has_permission`) and at the iOS repository layer (40 repos, all with protocol + Live + Mock, zero Views calling Supabase). The 2026-05-17 Roles Remediation closed all 14 sprint rows; 2026-05-18 Resource Creation Redesign data layer (variants + intents + activator) shipped.

**What is unfinished, in priority order:**

1. **Resource Creation redesign is 25% landed** — `ResourceVariantRegistry`, `ResourceIntentRegistry`, `LazyCapabilityActivator` exist as standalone data + actor. `ResourceCreationCoordinator`, `MinimalIdentityForm`, `PostCreateIntentScreen`, `PostCreateIntentDispatcher`, AppState wiring — **none exist**. The "+" tab still routes to the old wizard with capability + rule toggles. (Report #03)
2. **`process-system-events` has a silent bug** — `markProcessed` writes `payload = { results }` alongside `processed_at`; mig 00162 atom guard rejects this UPDATE; the error is swallowed; events re-process forever (or the guard isn't deployed; either way doctrine and code disagree). Also, no DB cron schedule found for the function in any migration. If true, the rule engine is dormant. (Report #06 §8.1-2)
3. **`SystemEventType` Swift enum is missing 9 server-side atoms** (`assetBookings(Un)locked`, `groupRolesChanged`, `identityPromoted`, `memberCapabilityOverrideDeactivated`, `rightMetadataUpdated`, `slotCreated`, `slotReleased`, plus a literal `myAtom` example value seeded into `known_event_types`). iOS templates can't match these triggers. (Report #07 §5)
4. **CapabilityResolver still switches on `resource.resourceType`** in `+PrimaryAction.swift:32-57` and `+SecondaryActions.swift:27-47`. Largest single doctrinal violation in iOS code today: the resolver is supposed to be capability-driven; instead it dispatches to `eventPrimaryAction`/`fundPrimaryAction`/`rightPrimaryAction`. (Report #05 §3)
5. **100+ raw capability id strings sprayed across the codebase.** The catalog centralizes structure but exposes no typed constants — one typo silently disables a section. (Report #05 §4)

**Beta-1 risk score (this audit):** **LOW.** None of the above are hard blockers. #2 is the most dangerous because it's invisible; the others are user-visible-or-not depending on whether someone leans on the missing surface during the demo.

---

## 2. Architecture Map (actual)

```
                      ┌──────────────┐
                      │ supabase-swift │
                      └───────┬──────┘
                              ▼
┌─────────────┐       ┌──────────────┐
│   RuulCore  │◀──────│   RuulUI     │   (13 files import Core — see §3 of report #01)
│             │       └──────────────┘
│ • PlatformModels (5.9k LOC)             ┌──────────────────────┐
│ • Capabilities (4.5k LOC)         ◀─────│    RuulFeatures      │
│ • Repositories (9.6k LOC, 40 repos)     │ • Features/Rules     │
│ • Resources/Variants + Intents          │ • Features/Resources │
│ • Services + Templates + Supabase       │ • Features/Shell …   │
│ • PlatformModules (5 modules)           └────────┬─────────────┘
│ • Events/ (8 files — should move)                │
│ • 16 loose top-level files (should move)         ▼
└─────────────────────────────────────────┬───────────────┐
                                          │  Tandas app   │
                                          └───────────────┘
                                                  │
                                                  ▼
                                          ┌──────────────┐
                                          │ TandasTests  │
                                          └──────────────┘

Supabase backend (326 migrations, 256 RPCs, 21 edge functions)
  ├─ Atoms (append-only, 7 guarded tables)
  ├─ Projections (~26 views, 12 unused by iOS)
  ├─ Rule engine (_shared/ruleEngine.ts, server-only)
  └─ Cron (mig 00030/00069/00131/00214/00270 — only 5 schedules found)
```

**Layer doctrine status:** Package.swift declares clean fan-out (Features→Core, UI→Core, Core→Supabase only). No `import RuulFeatures` in Core. No SwiftUI `View` types in Core. Only one Feature imports `Supabase` directly (Auth/SignInView, intentional for OTP).

---

## 3. Folder-by-folder audit

See **`01_architecture.md`** for the full per-folder verdict tables. Highlights:

### RuulCore — biggest housekeeping items
- `Capabilities/CapabilityCatalog.swift` (1321 LOC) — SPLIT into Catalog/Blocks/{Event,Money,Governance,Rotation,Asset,Space,Status}
- `Coordinators/` (1 file: LoadingCoordinator) — MERGE into `Loading/`
- `Events/` (8 event-domain models) — MOVE to `PlatformModels/Event/`
- **16 loose top-level files** (`Group.swift`, `Member.swift`, `Profile.swift`, `Invite.swift`, `OnboardingX`, `GroupDraft`, `GroupRule`, `RotationMode`, etc.) — MOVE to `PlatformModels/` (or new `PlatformModels/Identity/`)
- `AppState.swift` (672 LOC god-object) — SPLIT into `+Repositories`/`+Realtime`/`+Session`
- `Repositories/GroupsRepository.swift` (1105 LOC, 70 funcs) — SPLIT into 5 files
- `Repositories/RuleTemplateRepository.swift` (767 LOC) — extract catalog to `Templates/RuleTemplateCatalog.swift`
- `Repositories/RuleRepository.swift` (667 LOC) — extract `InterceptingRuleRepository` to `Services/RuleGovernanceCoordinator.swift`

### RuulFeatures — biggest housekeeping items
- `Shell/RootShellSheets.swift` (1108 LOC) — SPLIT by sheet category
- `Resources/ResourceWizardSheet.swift` (1127 LOC) — most of file targeted for deletion when creation redesign ships
- `Resources/Detail/UniversalResourceDetailView.swift` (800 LOC) — TRIM dead `stubCapabilitySections`/`catalogSections`/`dynamicSectionIds`/`stubSectionIds`/`.enableCapability` case
- `Home/HomeView.swift` (631 LOC) — has hardcoded `resource_type` switches
- `Rules/RuleComposerView.swift` (716 LOC) — flagged for follow-up audit
- `Resources/Money/` — RENAME to `Resources/Ledger/` (naming canonical)

### RuulUI
- Healthy. Only doctrinal drift: `Modifiers/Group+AmbientPalette.swift` extends `RuulCore.Group` from the UI package.

---

## 4. Dead code list

### iOS (HIGH confidence)
| File / API | Why dead |
|---|---|
| `RuulUI/Primitives/RuulFlowChips.swift` | 0 external refs |
| `RuulUI/Primitives/RuulSubTabBar.swift` | 0 external refs |
| `RuulUI/Patterns/RuulStatePatterns+Aliases.swift` | typealiases never used |
| `RuulCore/Capabilities/SecondaryAction.swift:33` `.enableCapability` case | no emitter post-Pass-1 |
| `RuulCore/PlatformModels/ResourceType.swift:80` `capabilitiesAreUserManaged` | no callers (in-code dead-doc comment) |
| `RuulFeatures/.../Resources/Detail/Zones/ResourceSummaryView.swift` | orphan + raw capability-chip chrome |
| `RuulFeatures/.../Resources/Detail/Sections/Stubs/StateSections.swift::HistorySectionView` | duplicate of `ActivitySectionView` |
| `RuulFeatures/.../Resources/Detail/Sections/Stubs/AssignmentSections.swift::BookingSectionView` | filtered out for asset/space, self-contradictory elsewhere |

### Edge functions (HIGH confidence)
| Folder | Why dead |
|---|---|
| `supabase/functions/generate-wallet-pass/` | Stub returning 503; no Swift caller (`EventDetailCoordinator.generateWalletPass` returns nil) |
| `supabase/functions/finalize-votes/` | No cron schedule; only e2e tests call it |
| `supabase/functions/send-fine-reminders/` | No cron, no caller |

### RPCs (MEDIUM confidence, verify trigger wiring first)
- `advise_stuck_fines` (mig 00240)
- `fines_resource_id_parity_check` (mig 00041)
- `events_resources_parity_check` (mig 00039/40/152)
- `cast_ballot` (mig 00006/00020 — superseded by `cast_vote`)
- Legacy event RPCs (`create_event`, `create_event_v`, `check_in_attendee`, `close_pot`, `create_expense_with_shares`, `resolve_fine_pending_action`, `resolve_fine_proposal_review`) — ~12 names that no Swift or edge fn calls

### Tests (deleted/disabled)
- `TandasUITests/HappyPathTests.swift` — entire target permanently `XCTSkipIf(true)`
- `TandasTests/Votes/OpenVotesCoordinatorTests.sectioned` — `.disabled("Pre-existing stale test")`

### Stale docs (preserve as superseded, don't auto-delete)
- `docs/superpowers/specs/2026-05-18-resource-detail-intent-refactor-design.md` — references 5 deleted view types

---

## 5. Duplicate logic list

| # | Locations | Verdict |
|---|---|---|
| 1 | `ActivitySectionView` ↔ `HistorySectionView` (both read `system_events` per resource) | DELETE `HistorySectionView` or alias `history` cap onto `activity` |
| 2 | `AssetBookingsSection` ↔ `SpaceBookingsSection` (near-identical card layout) | EXTRACT shared `BookingsSection(repo:)` |
| 3 | `AssetCustodySection` ↔ `SpaceOccupancySection` (same shape, different verbs) | EXTRACT shared "who's here" primitive |
| 4 | Three card chrome primitives — `cardBackground()` (in ScheduleSectionView), `CapabilityStubCard`, `RuulInfoCard` | CONVERGE on `RuulInfoCard` |
| 5 | `RSVPRepository` ↔ `RsvpActionRepository` ↔ `CheckInRepository` (all touch RSVP table) | DELETE `RsvpActionRepository`; MERGE `CheckInRepository` into `RSVPRepository` |
| 6 | `process-system-events`/`auto-close-events`/`emit-*` (5+ functions repeat the candidate→dedup→batch shape) | EXTRACT `_shared/atomEmitter.ts` |
| 7 | Two iOS permission resolvers in parallel: `GovernanceService.hasPermission` (RPC) AND local catalog walker duplicated in `GroupHomeCoordinator` / `MembersCoordinator` / `MoneySectionView` / `ResourceDetailSheet` | UNIFY on `GovernanceService` |
| 8 | `MockGroupsRepository` shipped but `AddManualFineCoordinatorTests` reimplements `StubGroupsRepository` (107 LOC, 22 fatalErrors) | DELETE inline stub, use Mock |
| 9 | CapabilityResolver test surface split across 5 files; `Platform/CapabilityResolverTests.swift` is the oldest, partially supplanted | MERGE/DELETE the Platform-tier file |
| 10 | `failure()` helper duplicated between `_shared/ruleEngine.ts` and `_shared/ruleEngineConsequences.ts` (acknowledged import-cycle workaround) | KEEP for now, flag |

---

## 6. Doctrinal violations list

| # | Where | Violation | Class |
|---|---|---|---|
| 1 | `Capabilities/CapabilityResolver+PrimaryAction.swift:32-57` + `+SecondaryActions.swift:27-47` | `switch resource.resourceType` dispatches to vertical-specific methods. Should be capability-driven. | **BETA BLOCKER-soft** |
| 2 | `RuulFeatures/.../Resources/ResourceWizardSheet.swift:371-426` | Capability toggles still surface to users (`capabilityRow`, "¿Qué más quieres que pase?") | **BETA BLOCKER-soft** |
| 3 | `RuulFeatures/.../Resources/ResourceWizardSheet.swift:574-600` | Suggested rules pre-tick UI at create time | **BETA BLOCKER-soft** |
| 4 | `supabase/functions/process-system-events/index.ts:117-121` | `markProcessed` writes `payload` alongside `processed_at` — atom guard rejects, error swallowed | **BETA BLOCKER-hard** |
| 5 | `supabase/functions/emit-slot-system-events/index.ts:121` | Direct `.from("resources").update({ status: "expired" })` splits atom from truth | **BETA BLOCKER-soft** |
| 6 | `supabase/functions/finalize-fine-reviews/index.ts:100-117` | Direct `INSERT INTO ledger_entries` bypasses `record_ledger_entry` RPC | DOCTRINAL VIOLATION |
| 7 | `supabase/functions/send-fine-reminders/index.ts:94-97` | Direct `UPDATE fines SET details = ...` mutates a projection column | DOCTRINAL VIOLATION |
| 8 | `RuulFeatures/.../Resources/Detail/UniversalResourceDetailView.swift:690` | `if resourceType == .right { showEditRight } else { onPresentEditResource }` last in-view per-type branch | REWRITE |
| 9 | `RuulFeatures/.../Home/HomeView.swift:248-262, 384-413` | `switch resource_type` for subtitle/icon/empty-state. Most-trafficked screen. | **BETA BLOCKER-soft** |
| 10 | `RuulFeatures/.../Resources/Detail/Sections/Stubs/GovernanceSections.swift::ConsequenceSectionView` | Uses rule-engine jargon ("CONSECUENCIAS") in user-facing copy | DOCTRINAL VIOLATION (feedback_rules_ux_human) |
| 11 | `RuulFeatures/.../Resources/Detail/Sections/Stubs/WorkflowSections.swift::ApprovalSectionView` | Subtitle says "wired al backend" — implementation jargon | DOCTRINAL VIOLATION |
| 12 | `RuulFeatures/.../Fines/Sheets/AddManualFineSheet.swift:73-77` | Labels founders as "ADMIN" in the UI — founder/admin confusion | DOCTRINAL VIOLATION |
| 13 | `RuulCore/PlatformModules/V1Modules.swift`, `RuulFeatures/.../UniversalResourceDetailView.swift:545-586`, `RuulFeatures/.../Home/HomeView.swift:421-427`, plus 80+ other sites | Raw capability id string literals everywhere; no typed `CapabilityID` namespace | DOCTRINAL VIOLATION |
| 14 | `supabase/migrations/00293_known_event_types_as_table.sql` seed contains literal example `myAtom` | Doctrinal smell — example value leaked into production seed | LOW |
| 15 | `RuulUI/Modifiers/Group+AmbientPalette.swift` | UI package extends `RuulCore.Group` directly | DRIFT |
| 16 | 5 duplicate-numbered migration pairs (00285/00286/00287/00288/00295) | Parallel-branch merges with undefined ordering | PROCESS RISK |
| 17 | `iOS SystemEventType` enum drift (9 atoms in DB, missing in Swift) | Rule engine emits these but iOS templates can't match | **BETA BLOCKER-soft** |

---

## 7. Naming inconsistencies (full table in **`10_deadcode_naming.md` §6**)

| Pair | Canonical | Blast |
|---|---|---|
| activity / history | **activity** | Medium |
| money / ledger | **ledger** | Low (Folder `Resources/Money/` + `RuulMoneyView` still linger) |
| booking / reservation | **booking** | None |
| ownership / right | **right** + ownership=projection | None |
| holder / owner | **holder** | Low |
| resource / object | **resource** | Low |
| event vs occurrence, slot vs booking, rules vs governance, role vs permission | distinct concepts — keep both | None |

Edge function naming: `emit-*-atoms` vs `emit-*-events` mixed, `auto-*` vs `finalize-*` overlap. Cosmetic; not blocking.

---

## 8. Repository audit

See **`04_repositories.md`** for the full 40-repo inventory.

**Headline:** Doctrine fully respected (every repo has protocol + Live + Mock; 0 Views call Supabase). Only true hotspots:
- `GroupsRepository` (1105 LOC, 70 funcs) — split into 5
- `RuleTemplateRepository` (767 LOC, catalog inside transport) — extract `RuleTemplateCatalog.swift`
- `RuleRepository` (667 LOC) — extract `InterceptingRuleRepository` to `Services/RuleGovernanceCoordinator.swift`
- `CheckInRepository` → MERGE into `RSVPRepository`
- `RsvpActionRepository`, `MyActivityRepository` → DELETE (0 consumers, verify AppState)

---

## 9. SQL / RPC audit

See **`07_sql_rpcs.md`** for the full 326-migration audit.

**Headline:** Schema is doctrine-clean (atom guards on 7 tables, RLS routes through `has_permission`, no `groups.fund_balance` writes anywhere, mig 00188 enforces type-aware `resources.metadata` shape). Risks:
- Swift `SystemEventType` drift (9 missing cases) — **must catch up before any rule template uses those triggers**
- 5 duplicate-numbered migration pairs — process risk
- 12-mig numeric gap 00303→00315 — process noise
- Placeholder-merge RPC fixed 5× in 2 days (00315/00317/00323/00324/00326) — still settling
- `otp_codes`, `member_capability_overrides`, `system_event_payload_schemas` have no RLS policy attached — verify default-deny
- `fund_balance_view` unused by iOS — investigate

---

## 10. Edge function audit

See **`06_edge_functions.md`** for the full 21-function audit.

**Headline:** 19 of 21 functions are doctrinally sound and idempotent. The bad news:
- **`process-system-events` may be silently dormant** — no cron found in any migration; `markProcessed` writes to `payload` violating mig 00162 guard, error swallowed
- **`emit-slot-system-events` mutates `resources.status` directly** — splits atom from truth
- **`finalize-fine-reviews` inserts into `ledger_entries` directly** — bypasses `record_ledger_entry`
- **`generate-wallet-pass`, `finalize-votes`, `send-fine-reminders`** are dead (no cron, no caller)
- Rule engine `_shared/ruleEngine.ts` is well-built (precedence, scope hierarchy, idempotency contract) but legacy-rule fallback fails open (returns `true` on audit-insert error); `startVote` has no payload-level dedup for the legacy-fallback path

---

## 11. Test coverage map

See **`08_tests.md`** for the full coverage map.

**Headline:** ~502 tests, ~14k LOC across iOS (host-app target only, no SwiftPM-level tests) + edge functions. Doctrinal coverage:

| Domain | Status |
|---|---|
| Creation flow (Variant/Intent/LazyActivator) | ✅ |
| Atoms append-only | ✅ (edge DB) |
| `rule_evaluations` idempotency | ✅ (edge DB) |
| Role/permission resolver | ✅ (iOS + DB) |
| Right state / Fund lock / Projections recomputable | ⚠ partial |
| Resource detail capability hiding | ⚠ one assertion only |
| **Resource links** | ❌ ZERO tests |
| **Booking↔waitlist consent** | ❌ no consent-gate test |
| TandasUITests | ❌ permanently skipped |

---

## 12. Proposed target structure

```
ios/Packages/
├── RuulCore/Sources/RuulCore/
│   ├── AppState/                              ← split AppState.swift
│   │   ├── AppState.swift                     (orchestration only, <200 LOC)
│   │   ├── AppState+Repositories.swift
│   │   ├── AppState+Realtime.swift
│   │   └── AppState+Session.swift
│   ├── PlatformModels/
│   │   ├── Generated/                         (codegen, unchanged)
│   │   ├── Identity/                          ← MOVE from root (Group, Member, Profile, Invite, OnboardingX, ...)
│   │   ├── Event/                             ← MOVE from Events/
│   │   ├── Governance/                        (Permission, GroupPolicy, RoleDefinition, GovernanceRules, MemberRole, RuleScope new enum)
│   │   ├── Rules/                             (Rule, RuleShape, RuleTemplate, RuleDraft split, ShapeNode, ConditionNode, …)
│   │   └── Resources/                         (Resource, ResourceRow, Fund, Slot, Space, Booking, ResourceLink)
│   ├── Capabilities/
│   │   ├── CapabilityCatalog.swift            (~100 LOC wrapper)
│   │   ├── Blocks/
│   │   │   ├── Event/
│   │   │   ├── Money/
│   │   │   ├── Governance/
│   │   │   ├── Rotation/
│   │   │   ├── Asset/
│   │   │   ├── Space/
│   │   │   └── Status/
│   │   ├── CapabilityID.swift                 ← NEW typed namespace
│   │   ├── CapabilityResolver.swift           (capability-driven, no resourceType switch)
│   │   ├── CapabilityResolver+PrimaryAction.swift
│   │   ├── CapabilityResolver+SecondaryActions.swift
│   │   ├── ResourceTypeChrome.swift           (display lookup; can stay)
│   │   └── ResourceBuilderRegistry.swift
│   ├── PlatformModules/
│   ├── PlatformServices/
│   ├── Repositories/
│   │   ├── Protocols/                         (optional — currently colocated, OK)
│   │   ├── Groups/                            ← split GroupsRepository
│   │   │   ├── GroupsRepository.swift         (CRUD)
│   │   │   ├── GroupMembersRepository.swift
│   │   │   ├── GroupRolesRepository.swift
│   │   │   ├── GroupAvatarRepository.swift
│   │   │   └── GroupModuleRepository.swift
│   │   ├── Rules/
│   │   │   └── RuleRepository.swift           (transport only; Intercepting moved to Services)
│   │   └── … (other repos as-is)
│   ├── Resources/
│   │   ├── Variants/                          (unchanged)
│   │   └── Intents/                           (unchanged)
│   ├── Services/
│   │   ├── Analytics/
│   │   ├── Calendar/
│   │   ├── Realtime/
│   │   ├── Notifications/
│   │   ├── OTP/
│   │   ├── QR/
│   │   ├── Wallet/
│   │   ├── Lifecycle/
│   │   ├── FeatureFlags/
│   │   ├── Location/
│   │   ├── Governance/                        ← NEW (RuleGovernanceCoordinator extracted from RuleRepository)
│   │   └── Permissions/                       ← maybe? GovernanceService lives here today as PlatformServices
│   ├── Templates/
│   │   ├── TemplateRegistry.swift
│   │   ├── RuleTemplateCatalog.swift          ← NEW (extracted from RuleTemplateRepository)
│   │   └── DinnerRecurringTemplate.swift
│   ├── Supabase/
│   ├── Loading/                               ← absorb Coordinators/
│   └── Utilities/
├── RuulFeatures/Sources/RuulFeatures/Features/
│   ├── Auth/                                  (only Supabase-direct import, documented)
│   ├── Onboarding/
│   ├── Home/                                  (rewrite to remove resource_type switches)
│   ├── Groups/  Group/  Members/
│   ├── Resources/
│   │   ├── Create/                            ← NEW
│   │   │   ├── ResourceCreationCoordinator.swift
│   │   │   ├── TypePickerStep.swift
│   │   │   ├── VariantPickerStep.swift
│   │   │   ├── MinimalIdentityForm.swift
│   │   │   ├── ConfirmCreateStep.swift
│   │   │   └── PostCreateIntentScreen.swift
│   │   ├── Advanced/                          ← NEW (where ResourceWizardSheet retreats to if needed)
│   │   ├── Detail/
│   │   │   ├── UniversalResourceDetailView.swift (trimmed)
│   │   │   ├── Sections/                      (per-capability sections, all gated via isVisibleFor)
│   │   │   ├── Sheets/
│   │   │   ├── Adapters/
│   │   │   └── Zones/                         (delete ResourceSummaryView)
│   │   ├── Links/
│   │   ├── Rules/                             (resource-scope rules entry)
│   │   ├── Ledger/                            ← RENAME from Money/
│   │   ├── CheckIn/
│   │   └── Past/
│   ├── Rules/                                 (RuleComposer family)
│   ├── Fines/  Votes/  Inbox/  Profile/  Activity/  Feed/  Claims/
│   └── Shell/                                 (RootShellSheets split by category)
└── RuulUI/Sources/RuulUI/                     (unchanged structure; move Group+AmbientPalette away from extending RuulCore.Group)

supabase/
├── migrations/                                (chronological — keep)
└── functions/
    ├── _shared/
    │   ├── ruleEngine.ts
    │   ├── ruleEngineConsequences.ts
    │   ├── ruleEngineConditions.ts
    │   ├── atomEmitter.ts                     ← NEW (extract emit-* duplication)
    │   ├── recordSystemEventsBatch.ts         ← NEW (centralize RPC literal)
    │   └── …
    ├── _tests/
    ├── process-system-events/                 (fix markProcessed bug)
    ├── dispatch-notifications/
    ├── emit-event-started/                    ← rename from -atoms
    ├── emit-event-reminder/                   ← rename from -events
    ├── emit-rsvp-deadline-passed/             ← rename from emit-deadline-events
    ├── emit-space-no-check-in/                ← rename
    ├── emit-slot-expired/                     ← rename + convert direct UPDATE to RPC
    ├── emit-asset-overdue/
    ├── auto-close-events/  auto-generate-events/
    ├── finalize-votes/  finalize-fine-reviews/  (finalize-fine-reviews → use record_ledger_entry)
    ├── send-event-notification/  send-otp/  verify-otp/  send-whatsapp-invite/  create-placeholder-member/
    └── (delete) generate-wallet-pass/  send-fine-reminders/  finalize-votes/  ← only if confirmed unused

Plans/
├── Active/                                    (existing doctrine docs)
├── Active/CleanupAudit_2026-05-18/            ← THIS audit
└── Doctrine/                                  ← optional consolidated doctrine refs (Vision, Governance, Ontology)
```

---

## 13. Migration / refactor plan

Decisions per finding, grouped by blast radius:

**No blast radius (delete/move only):**
- Delete 3 dead UI files, 3 dead edge functions, 1 dead `.enableCapability` case, 1 dead `capabilitiesAreUserManaged` prop
- Move 16 loose Core top-level files → `PlatformModels/Identity/`
- Move `Events/` → `PlatformModels/Event/`
- Merge `Coordinators/` → `Loading/`
- Rename `Features/Resources/Money/` → `Features/Resources/Ledger/`

**Single-file rewrites (low risk, big win):**
- Trim `UniversalResourceDetailView.swift` (remove stub helpers + `.right` branch + `.enableCapability` arm)
- Fix `process-system-events markProcessed` (drop `payload` write)
- Fix `emit-slot-system-events` (RPC instead of direct UPDATE)
- Fix `finalize-fine-reviews` (use `record_ledger_entry`)
- Fix `AddManualFineSheet.swift:73-77` (don't label founders as "ADMIN")
- Add 9 missing `SystemEventType` Swift cases + sanitize `myAtom` from DB seed
- Push `RotationSectionView`/`ScheduleSectionView`/`CapacityProgressSectionView` type guards into `isVisibleFor`
- Add `CapabilityID` typed namespace (mechanical replacement of 100+ strings)
- Add `RuleScope` enum (~25 sites)

**Multi-file refactors (commit per slice):**
- Split `GroupsRepository` (5 files)
- Split `CapabilityCatalog` (1 → 8 files)
- Extract `RuleTemplateCatalog` from `RuleTemplateRepository`
- Extract `RuleGovernanceCoordinator` from `RuleRepository`
- Split `RootShellSheets.swift`
- Split `AppState.swift`
- Extract `_shared/atomEmitter.ts` from 5 emit-* functions

**Surface rewrites (touch user-facing copy):**
- Rewrite `ConsequenceSectionView` + `ApprovalSectionView` jargon copy
- Resolve activity/history duplication (delete one)
- Delete `Zones/ResourceSummaryView.swift`
- Replace `BookingSectionView` stub

**Larger rebuilds (separate spec):**
- Ship `ResourceCreationCoordinator` + `MinimalIdentityForm` + `PostCreateIntentScreen` + `PostCreateIntentDispatcher` + AppState wiring
- Make `CapabilityResolver` capability-driven (drop `switch resourceType` from `+PrimaryAction` and `+SecondaryActions`)
- Unify iOS local permission resolver onto `GovernanceService.hasPermission`

---

## 14. Phase-by-phase execution plan

### Phase 0 — Inventory (DONE — this audit)

### Phase 1 — Delete obvious dead code (commits: 1 per item, all reversible)
- 3 dead edge functions (`generate-wallet-pass`, `finalize-votes`, `send-fine-reminders` — only after confirming `finalize-votes` isn't dashboard-cron-scheduled)
- 2 dead UI primitives (`RuulFlowChips`, `RuulSubTabBar`) + `RuulStatePatterns+Aliases`
- `.enableCapability` case + matching exhaustive arm
- `capabilitiesAreUserManaged` prop
- `Zones/ResourceSummaryView.swift` + `Stubs/BookingSectionView` + `Stubs/HistorySectionView`
- Trim `UniversalResourceDetailView.swift` (stub helpers + stale doc + `.right` branch)
- Annotate stale spec doc `2026-05-18-resource-detail-intent-refactor-design.md` as superseded

### Phase 2 — Move files (no behavior change)
- 16 loose Core top-level files → `PlatformModels/Identity/`
- `Events/` → `PlatformModels/Event/`
- `Coordinators/` → `Loading/`
- Rename `Features/Resources/Money/` → `Features/Resources/Ledger/`

### Phase 3 — Rename canonical naming
- "money" → "ledger" in helper types
- "history" → "activity" in `HistoryItemPresentation`/`routeFromHistoryEvent`
- Edge function renames (deferred — touches cron migrations)

### Phase 4 — Split giant files
- `GroupsRepository` (1105 LOC) into 5 files
- `RuleTemplateRepository` extract `RuleTemplateCatalog`
- `RuleRepository` extract `InterceptingRuleRepository` → `Services/RuleGovernanceCoordinator`
- `CapabilityCatalog` (1321 LOC) into Blocks/ tree
- `RootShellSheets.swift` (1108 LOC) by sheet category
- `AppState.swift` (672 LOC) into +Repositories/+Realtime/+Session
- `RuleComposerView` (716 LOC) — audit + split per step

### Phase 5 — Repository consistency
- DELETE `RsvpActionRepository`, `MyActivityRepository` (after grep + AppState verify)
- MERGE `CheckInRepository` into `RSVPRepository`
- AssetLifecycle/SpaceLifecycle/SlotLifecycle/Booking/Right/Space etc. with 0 Features consumers — KEEP (Beta-2 surfaces depend on them); document

### Phase 6 — UI surface cleanup
- `ResourceCreationCoordinator` + `MinimalIdentityForm` + `PostCreateIntentScreen` + dispatcher + AppState wiring (Beta-1 blocker)
- Old wizard → Advanced-only or feature-flagged off; delete capability toggles + rule pre-tick
- Rewrite `ConsequenceSectionView`/`ApprovalSectionView` copy
- Push `RotationSectionView`/`ScheduleSectionView`/`CapacityProgressSectionView` type guards into `isVisibleFor`
- Replace `Home/HomeView.swift` resource_type switches with chrome lookup

### Phase 7 — Doctrine fixes (parallel to 6 if Beta-blocking)
- **Edge:** fix `process-system-events markProcessed` (HARD BLOCKER)
- **Edge:** fix `emit-slot-system-events` direct UPDATE (atom truth)
- **Edge:** fix `finalize-fine-reviews` ledger insert
- **Edge:** confirm/add cron schedule for `process-system-events`
- **iOS:** add 9 missing `SystemEventType` cases + drop `myAtom` from DB seed
- **iOS:** add `CapabilityID` typed namespace + `RuleScope` enum (mechanical sweeps)
- **iOS:** make `CapabilityResolver+PrimaryAction/+SecondaryActions` capability-driven
- **iOS:** unify permission checks onto `GovernanceService.hasPermission`
- **iOS:** fix `AddManualFineSheet` "ADMIN" label

### Phase 8 — Tests
- Add `ResourceLinkRepositoryTests`
- Add `_tests/db/consistency_resource_links.test.ts`
- Add capability-hiding doctrinal guard test
- Add `FundRepository.testLockTwiceEmitsOneAtom`
- Add `SpaceProjectionRepositoryTests.testRecomputeFromAtomsMatchesLive`
- Add booking↔waitlist consent test
- Replace `AddManualFineCoordinatorTests` inline `StubGroupsRepository` with `MockGroupsRepository`
- Merge `Platform/CapabilityResolverTests.swift` into the `Capabilities/` suite
- Re-enable `OpenVotesCoordinatorTests.sectioned`
- Migrate `Platform/GovernanceServiceTests.swift` XCTest → Swift Testing
- Optional: smoke `HappyPathTests` against TestPlan instead of UI

---

## 15. Risk matrix

| Item | Likelihood | Impact | Priority |
|---|---|---|---|
| `process-system-events markProcessed` rejected by atom guard | HIGH | HIGH (rule engine silently dormant) | **P0** |
| No cron for `process-system-events` | UNKNOWN (dashboard-only?) | HIGH | **P0** verify |
| 9 `SystemEventType` Swift cases missing | LOW (only matters when a template uses one) | MED | **P1** |
| Capability id raw strings | HIGH (typo any commit) | MED (section silently disappears) | **P1** |
| `CapabilityResolver+PrimaryAction/+SecondaryActions` switch on resourceType | MED | MED | **P1** |
| Resource creation old wizard still primary | HIGH | MED (founder demo) | **P1** |
| `AddManualFineSheet` "ADMIN" label | HIGH (visible bug) | LOW-MED | **P2** |
| RootShellSheets / AppState / CapabilityCatalog giant files | LOW (compiles fine today) | MED (merge conflicts) | **P2** |
| Local resolver duplication (4 sites) | MED (drift if server semantics shift) | LOW | **P2** |
| `emit-slot-system-events` direct UPDATE | LOW (status flip is idempotent) | LOW-MED | **P2** |
| `finalize-fine-reviews` direct ledger insert | LOW | MED | **P2** |
| 5 duplicate-numbered migration pairs | DONE-RISK | LOW (already landed) | **P3** retro |
| iOS test gaps (resource links, booking consent, UI smoke) | MED | MED (no canary if behavior regresses) | **P2** |
| RuulUI extends `RuulCore.Group` | LOW | LOW | **P3** |
| `generate-wallet-pass` / `finalize-votes` / `send-fine-reminders` dead | DONE | LOW | **P3** delete |
| `otp_codes` / `member_capability_overrides` / `system_event_payload_schemas` RLS missing | UNKNOWN — verify default-deny | HIGH if open | **P1** verify |
| `fund_balance_view` unused by iOS | UNKNOWN | MED | **P2** investigate |
| Universal-template alias closure not complete | LOW | LOW | **P3** |

---

## 16. First 10 commits (recommended, in order)

**Status as of 2026-05-18 end-of-day** — 7 of the original 10 have shipped (or been redirected); the rest are unchanged.

| # | Original | Status |
|---|---|---|
| 1 | `fix(engine): drop payload write from process-system-events markProcessed` | ✅ `bc5a806` |
| 2 | `chore(ops): verify cron schedule for process-system-events` | ✅ verified live via `cron.job` — no migration needed; full inventory documented in `11_post_execution_corrections.md` §6. Also fixed an unrelated cron 404 (mig 00327→00328, commits `8b1ba97` + `94592e1`). |
| 3 | `chore(cleanup): delete dead edge functions generate-wallet-pass + send-fine-reminders` | ❌ SKIPPED — audit was wrong; neither is dead. See `11_post_execution_corrections.md` §1-2. |
| 4 | `chore(cleanup): delete dead UI primitives RuulFlowChips + RuulSubTabBar + RuulStatePatterns+Aliases` | ✅ `bb89e35` (-234 LOC) |
| 5 | `chore(cleanup): drop SecondaryAction.enableCapability case + matching arm + ResourceType.capabilitiesAreUserManaged` | ⏳ pending |
| 6 | `refactor(detail): trim UniversalResourceDetailView` | ⏳ pending (collides with user's in-flight working tree changes) |
| 7 | `fix(ui): stop labeling founders as "ADMIN" in AddManualFineSheet` | ✅ `acf7959` (label is now "FUNDADOR") |
| 8 | `chore(codegen): add missing SystemEventType cases (9) + drop myAtom` | ✅ `d36cdbc` — redirected: 7 of 9 were already allowlisted; only `eventReopened` needed promotion; `myAtom` was never in the seed. Allowlisted 4 truly-missing atoms with provenance. |
| 9 | `refactor(core): introduce CapabilityID typed namespace` | ⏳ pending |
| 10 | `refactor(core): move 16 loose RuulCore top-level files into PlatformModels/Identity/` | ✅ `9f15d7e` (14 moved, 2 kept at root — AppState + JSONCoding) |

**Out of the first 10**, the next priority slate (commits 11-20) is:
- Capability-driven `CapabilityResolver+PrimaryAction`/`+SecondaryActions`
- `RuleScope` enum + mechanical sweep
- `RootShellSheets` split by category
- `AppState` split into 4 files
- `GroupsRepository` split into 5 files
- Fix `emit-slot-system-events` direct UPDATE
- Fix `finalize-fine-reviews` direct ledger insert
- Unify permission checks onto `GovernanceService.hasPermission` (4 sites)
- Land `ResourceCreationCoordinator` MVP + `MinimalIdentityForm`
- Add `ResourceLinkRepositoryTests` + booking-consent test
- Restore source for 3 deployed-not-in-repo edge functions (`finalize-appeal-votes`, `evaluate-event-rules`, `export-user-data`)
