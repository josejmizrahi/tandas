# Swift Architecture & Layer Audit

> Note: The dispatched agent stalled at 600s on a deep grep. This report was completed via focused queries on the same evidence. Findings cross-validated with the repository audit (report #04).

## 1. Architecture map (actual)

```
RuulCore
  └─ depends on: supabase-swift (only external dep)

RuulFeatures
  └─ depends on: RuulCore

RuulUI
  └─ depends on: RuulCore         ⚠ (see §3)

Tandas (host app)
  └─ depends on: RuulCore + RuulFeatures + RuulUI

TandasTests
  └─ depends on: all 3 packages + Tandas
```

`Package.swift` declarations are clean and match the intended direction. Critically:
- `rg "^import RuulFeatures|^import RuulUI" Packages/RuulCore/Sources` → **0 hits** ✅
- `rg "^import RuulFeatures" Packages/RuulUI/Sources` → **0 hits** ✅
- `rg "^import SwiftUI" Packages/RuulCore/Sources` → **0 hits** ✅ (no Views in Core)
- `rg "struct .*: View" Packages/RuulCore/Sources` → **0 hits** ✅

## 2. Layer violations (concrete)

| # | Path | Issue | Class |
|---|---|---|---|
| 1 | `RuulCore/AppState.swift` (672 LOC) | God-object: instantiates 40+ repos, holds session state, owns realtime services, exposes `@Observable` props consumed app-wide. Borderline by design (DI root) but file-size says it's also doing presentation-adjacent wiring. | **YELLOW** — KEEP role, SPLIT into `AppState+Repositories.swift` / `AppState+Realtime.swift` / `AppState+Session.swift`. |
| 2 | `RuulUI/Modifiers/Group+AmbientPalette.swift` | UI package **extends `RuulCore.Group`** (`extension RuulCore.Group { var ambientPalette … }`). UI is adding behaviour to a domain type. | **YELLOW** — DOCTRINAL DRIFT. Move helper into Features, or make `ambientPalette(for groupId: UUID)` a free function so UI never names a domain type. |
| 3 | `RuulCore/Sources/RuulCore/*.swift` (top-level loose files) | 16+ models live at the root (`Group.swift`, `Member.swift`, `Invite.swift`, `Profile.swift`, `MemberWithProfile.swift`, `OnboardingCompletion.swift`, `OnboardingProgress.swift`, `OnboardingRuleDraft.swift`, `GroupDraft.swift`, `GroupRule.swift`, `GroupRule+FineShape.swift`, `RotationMode.swift`, `FrequencyType.swift`, `JSONCoding.swift`, `GroupColorRamp.swift`, `AppState.swift`). Inconsistent with `PlatformModels/` convention. | **MOVE** — almost all of these belong in `PlatformModels/` (or new `PlatformModels/Identity/`). Only `AppState.swift` and `JSONCoding.swift` stay at root. |
| 4 | `RuulCore/Events/` (8 files: Event/EventDraft/EventError/EventStatus/RSVP/RSVPStatus/CheckInMethod/RecurrenceOption, 438 LOC) | Holds event-specific domain models in a folder named `Events/`, while every other resource type's models live in `PlatformModels/`. Inconsistent. | **MOVE** to `PlatformModels/Event/` (or to `Resources/Event/` if doctrine prefers grouping by resource_type). |
| 5 | `RuulCore/Coordinators/` (1 file: `LoadingCoordinator.swift`) | A folder with one file. Coordinators are otherwise a Features concept. | **MERGE** into `Loading/` (also Core, has the related `LoadPhase`/`AsyncContentView` types). |
| 6 | `RuulFeatures/.../Auth/SignInView.swift` | `import Supabase` — direct SDK use for OTP. | **KEEP & DOCUMENT** — Auth is the only acceptable place a Feature touches the SDK; should be annotated `// SDK-INTENTIONAL: see ADR-xxx` and the rule encoded in CI lint. |

**No** views in `RuulFeatures` call `client.from(`, `client.rpc(`, etc. — all data access goes through repos (per report #04).

## 3. UI ↔ Core coupling (RuulUI imports RuulCore in 13 files)

| File | Why it imports Core | Verdict |
|---|---|---|
| `Resources/ResourceAction.swift`, `Resources/ResourceActionsProvider.swift` | Defines the UI side of the Action contract; docs reference governance/permission keys but no domain types in the type signature | KEEP — well-shaped boundary |
| `Patterns/EventCardStub.swift` | Explicit comment: *"Patterns receive this struct rather than the product's Event model so the design system stays decoupled."* | KEEP — exemplary |
| `Patterns/RSVPStateView.swift` | Uses local `EventCardData.RSVP` (UI shape) + `RuulAvatarStack.Person` | KEEP |
| `Modifiers/Group+AmbientPalette.swift` | Extends `RuulCore.Group` directly | **MOVE** (see §2.2) |
| `Patterns/ErrorStateView+CoordinatorError.swift` | Maps `CoordinatorError` (Core type) → UI presentation | KEEP — adapter is the right place |
| `Patterns/AsyncContentView.swift`, `Patterns/RuulInlineProgress.swift` | Uses `LoadPhase` | KEEP — `LoadPhase` is a generic state machine, not a domain leak |
| `Primitives/RuulGroupAvatar.swift`, `Primitives/RuulGroupSwitcher.swift`, `Primitives/RuulGroupComponents+Group.swift`, `Primitives/RuulOriginTag.swift`, `Primitives/RuulDatePicker.swift` | Need group identifiers + Resource types for color/icon mapping | YELLOW — workable but the API surface should take a small UI-shaped DTO, not the full `Group`/`Resource`. |
| `Patterns/EventCardStub.swift` | (See above) | KEEP |

**Net**: the UI→Core coupling is mostly via narrow, well-named types (`LoadPhase`, `CoordinatorError`, `ResourceType`). Three primitive files (`RuulGroupAvatar`, `RuulGroupSwitcher`, `Group+AmbientPalette`) cross into domain identity. Acceptable for Beta-1, but ideal evolution = those three take UI-shaped DTOs (`GroupVisualID { id, name, colorIndex }`) so the design system is portable.

## 4. Giant files (>500 LOC)

(Counts cross-checked with report #04/#05 to avoid double-coverage)

| File | LOC | Verdict | Split proposal location |
|---|---|---|---|
| `RuulCore/Capabilities/CapabilityCatalog.swift` | 1321 | SPLIT | See report #05 §7 |
| `RuulFeatures/.../Resources/ResourceWizardSheet.swift` | 1127 | SPLIT (or delete most) | See report #03 §4 |
| `RuulFeatures/.../Shell/RootShellSheets.swift` | 1108 | **SPLIT (new)** | This file is the global sheet router. Split into `RootShellSheets+Resource.swift` / `RootShellSheets+Group.swift` / `RootShellSheets+Vote.swift` / `RootShellSheets+Fine.swift` by sheet category. |
| `RuulCore/Repositories/GroupsRepository.swift` | 1105 | REWRITE/SPLIT | See report #04 §3 |
| `RuulFeatures/.../Resources/Detail/UniversalResourceDetailView.swift` | 800 | KEEP, TRIM | See report #02 §2 |
| `RuulCore/Repositories/RuleTemplateRepository.swift` | 767 | SPLIT (catalog→data) | See report #04 §3 |
| `RuulFeatures/.../Rules/RuleComposerView.swift` | 716 | **AUDIT** | Not deep-audited; likely needs the same "extract steps" treatment as `ResourceWizardSheet`. Flag for Phase 4. |
| `RuulCore/Repositories/RuleRepository.swift` | 667 | SPLIT (extract Intercepting → service) | See report #04 §3 |
| `RuulFeatures/.../Resources/ResourceWizardCoordinator.swift` | 676 | DELETE post-redesign | See report #03 |
| `RuulCore/AppState.swift` | 672 | SPLIT (see §2.1) | This audit |
| `RuulFeatures/.../Resources/Detail/Sections/Asset/AssetSections.swift` | 634 | YELLOW — many sections in one file | Split per section file. |
| `RuulFeatures/.../Home/HomeView.swift` | 631 | YELLOW — contains hardcoded resource_type switches (per #05) | Address as part of HomeView capability-driven cleanup. |
| `RuulCore/PlatformModels/RuleDraft.swift` | 569 | YELLOW (per #05) | Extract pure helpers; rule draft validation is its own service. |
| `RuulCore/Capabilities/RuleSentenceFormatter.swift` | 567 | KEEP — single-responsibility "human language formatter". Worth a re-read but probably fine. |

## 5. Cycles & coupling inside RuulCore

No folder-level circular imports detected. The internal structure is mostly a clean fan-out from `PlatformModels` (data) → `Repositories` (transport) → `PlatformServices`/`Services` (workflows) → `AppState` (DI root). Suspicious coupling:

- `Capabilities/CapabilityResolver+*` calls into `Repositories/` indirectly through service singletons (not direct imports) — acceptable.
- `Templates/` references `PlatformModels/` and `Capabilities/` — acceptable, top-down only.

## 6. Folder-by-folder verdict

### RuulCore subdirectories

| Path | Purpose now | Verdict |
|---|---|---|
| `Capabilities/` | 4480 LOC — catalog + resolver + builders + chrome | **YELLOW** — CapabilityCatalog needs split (#05); CapabilityResolver+Primary/Secondary need the `switch resourceType` removed (#05 §3 #1-#2). |
| `Coordinators/` | 1 file (LoadingCoordinator) | **MERGE** into `Loading/`. |
| `Events/` | 8 event-domain models | **MOVE** to `PlatformModels/Event/`. |
| `Loading/` | LoadPhase + AsyncContentView types | **KEEP**. Cohesive. |
| `PlatformModels/` (root + Generated) | All domain DTOs + codegen output | **KEEP**. Healthy (see #05 §10). |
| `PlatformModules/` | ModuleRegistry + V1Modules | **KEEP**. Clean. |
| `PlatformServices/` | 338 LOC, governance + assorted services | KEEP. |
| `Repositories/` | 40 repos, 9624 LOC | **KEEP/SPLIT** (see #04). Doctrine OK, only `GroupsRepository` needs surgery. |
| `Resources/Variants/` | Declarative variant catalog | **KEEP**. Healthy. |
| `Resources/Intents/` | Universal intents + activator | **KEEP**. Healthy. |
| `Resources/` (root: ResourceRow + decoders) | KEEP, with one fix (`ResourceRow.swift:98` per #05). |
| `Services/Analytics/` | 450 LOC | KEEP. |
| `Services/Calendar/`, `Notifications/`, `OTP/`, `QR/`, `Realtime/`, `Wallet/`, `Lifecycle/`, `FeatureFlags/` | Each cohesive | KEEP. |
| `Services/Location/` | (audit not deep) | likely KEEP. |
| `Supabase/` | client + auth | KEEP. |
| `Templates/` | template registry + DinnerRecurringTemplate | KEEP; aliasing per SQL audit #07 §10. |
| `Utilities/` | 588 LOC | KEEP (mostly typed helpers). |
| **(loose top-level files)** | 16 files | **MOVE** to `PlatformModels/`. |

### RuulFeatures top-level Features subdirectories

| Path | LOC | Verdict |
|---|---|---|
| `Rules/` | 3826 | **YELLOW** — biggest Features folder; `RuleComposerView` (716) deserves a wizard-style split. |
| `Resources/` | 6100 across subdirs | **YELLOW** — wizard + sections doctrinal cleanup pending (#02, #03). |
| `Shell/` | 1891 (incl. RootShellSheets 1108) | **SPLIT** RootShellSheets. |
| `Members/Views/` | 1512 | KEEP (audit beyond scope). |
| `Group/Subscreens/` | 1499 | KEEP. |
| `Home/` | 934 | **YELLOW** — has hardcoded `resource_type` switches (per #05). |
| `Profile/Views/` + `Profile/Subscreens/` | 1938 | KEEP. |
| `Activity/Views/` | 972 | KEEP, but rename plan (activity vs history) per #10. |
| `Fines/Views/` + Sheets + Coordinator | 2034 | KEEP. |
| `Auth/` | 553 | KEEP — only Feature with direct `import Supabase`, intentional. |
| `Inbox/Views/` | 523 | KEEP. |
| `Onboarding/Shared/` + `Founder/` + `Invited/` | (audit not deep) | KEEP. |
| `Resources/Money/` | 373 | **RENAME** → `Resources/Ledger/` per #10 naming canonical. |
| `Resources/CheckIn/` | 316 | KEEP. |
| `Claims/` | 310 | KEEP (Beta-1 surface). |
| `Votes/Coordinator/` + `Sheets/` + `Detail/` | 1135 | KEEP, with `OpenVotesCoordinatorTests.sectioned` re-enable per #08. |
| `Feed/Views/` + `Subviews/` | (small) | KEEP. |

## 7. Top 5 beta blockers from this dimension

1. **RootShellSheets.swift (1108 LOC)** — single source of every modal in the app. Risk: anyone editing one sheet routing rebuilds the whole file; merge conflicts during Beta-1 polish are likely. **Split before demo week.**
2. **AppState.swift (672 LOC) god-object** — same risk. Splitting by concern (Repositories / Realtime / Session) is a 1-PR refactor with no behaviour change.
3. **HomeView resource_type switches** (per #05) — visible on the most-trafficked screen; one regression breaks the founder demo.
4. **Group+AmbientPalette in RuulUI** extends `RuulCore.Group` — small, but Beta-1 founder demo passes through this color path on every group screen; moving it before lockdown avoids surprise compile breaks if `Group` shape shifts.
5. **`Coordinators/` folder with one file + `Events/` folder + 16 loose top-level files** — make the codebase look organic-grown to a new contributor; cosmetic but reviewers will hit this on every Pull Request.
