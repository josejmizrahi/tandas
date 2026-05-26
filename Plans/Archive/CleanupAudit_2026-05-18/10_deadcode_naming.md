# Ruul Dead-Code & Naming Audit (read-only)

## 1. Dead Swift files (candidate list)

| File | Refs outside self | Confidence |
|---|---|---|
| `ios/Packages/RuulUI/Sources/RuulUI/Primitives/RuulFlowChips.swift` | 0 | HIGH |
| `ios/Packages/RuulUI/Sources/RuulUI/Primitives/RuulSubTabBar.swift` | 0 | HIGH |
| `ios/Packages/RuulUI/Sources/RuulUI/Patterns/FineCardStub.swift` | only Showcase | MEDIUM (showcase-only stub) |
| `ios/Packages/RuulUI/Sources/RuulUI/Patterns/MemberRowStub.swift` | only Showcase | MEDIUM |
| `ios/Packages/RuulUI/Sources/RuulUI/Patterns/RuleCardStub.swift` | only Showcase | MEDIUM |
| `ios/Packages/RuulUI/Sources/RuulUI/Patterns/EventCardStub.swift` | only Showcase | MEDIUM |
| `ios/Packages/RuulUI/Sources/RuulUI/Templates/MainAppScreenTemplate.swift` | only Showcase | MEDIUM (template never adopted) |
| `ios/Packages/RuulUI/Sources/RuulUI/Templates/DetailScreenTemplate.swift` | only Showcase | MEDIUM |
| `ios/Packages/RuulUI/Sources/RuulUI/Templates/ResourceTabBar.swift` | only Showcase | MEDIUM |

## 2. Dead public APIs

- `RuulCore/Capabilities/SecondaryAction.swift:33` — `case enableCapability` is documented dead (no emitter post-Pass-1) yet `UniversalResourceDetailView.swift:722-726` still pattern-matches it to satisfy exhaustiveness. **HIGH** confidence safe to drop both the case and the matching arm.
- `RuulCore/PlatformModels/ResourceType.swift:80` — `capabilitiesAreUserManaged: Bool` — has zero callers (already documented as dead in code comment). **HIGH**.
- `RuulUI/Patterns/RuulStatePatterns+Aliases.swift` — `RuulEmptyState`, `RuulErrorState`, `RuulAvatarView` typealiases have **0 external refs** (only `RuulAvatarView` is mentioned inside `RuulPersonAvatar.swift` comments). **HIGH** to drop typealiases (verify with build).

## 3. Dead edge functions

> **CORRECTION 2026-05-18 post-execution** — re-verified against
> `list_edge_functions`, `cron.job`, and each function's docstring:
>
> - **`finalize-votes` is NOT dead.** It had no cron pre-mig-00327 but as of
>   commit `94592e1` it runs every 15 min as `finalize-votes-every-15min`.
> - **`generate-wallet-pass` is NOT dead.** Intentional 503 stub for iOS
>   `WalletPassService.isAvailable` contract. Docstring is the wiring guide
>   for when wallet creds are configured.
> - **`send-fine-reminders` is NOT dead.** Production-quality, awaiting
>   scheduling decision (suggested `0 12 * * *`).
>
> See `11_post_execution_corrections.md` §1-2. **No truly dead edge
> functions found.**

| Function | Cron registered | Swift caller | Real verdict |
|---|---|---|---|
| `finalize-votes/` | YES (`finalize-votes-every-15min`, mig 00327) | RPC via cron | KEEP |
| `generate-wallet-pass/` | NO | iOS checks reachability via 503 | KEEP (intentional stub) |
| `send-fine-reminders/` | NO | RPC-callable | KEEP (awaiting scheduling decision) |

## 4. Dead RPCs

The full delta needs trigger lookups (256 RPCs defined vs 158 directly `.rpc()`-called). High-confidence orphans found via spot-checks (each appears only in its own definition migration + rollback):

- `advise_stuck_fines` (mig 00240)
- `fines_resource_id_parity_check` (mig 00041)
- `events_resources_parity_check` (migs 00039/00040/00152) — appears to be a one-time parity check
- `cast_ballot` (migs 00006/00020 only — superseded by `cast_vote`)
- `emit_fine_issued_atom` (migs 00148/00150 — likely trigger; verify before removing)
- `emit_identity_atom` (mig 00174 — likely trigger)

Confidence MEDIUM until trigger wiring is confirmed.

## 5. TODO/FIXME inventory

Only **5 TODOs in app source** (impressive). All quick-wins:
| File:line | Type | Class |
|---|---|---|
| `Features/Onboarding/Founder/Views/InviteMembersView.swift:54` | TODO mention in comment | quick |
| `Features/Resources/ResourceWizardCoordinator.swift:452` | "Beta 1 W4 F-4.5 TODO: emit `error_shown` here" | quick |
| `Features/Group/Subscreens/GroupTimezonePickerView.swift:29` | "see TODO note in TimezonePickerView" | quick |
| `Features/Fines/Coordinator/ReviewProposedFinesCoordinator.swift:78` | "Beta 1 W4 F-4.5 TODO: emit `error_shown`" | quick |
| `RuulCore/Utilities/PhoneFormatter.swift:36` | "XXX XXX XXXX" — that's a digit-mask, not a TODO marker | non-actionable |

Only **1 fatalError** in app code: `RuulCore/Supabase/SupabaseClient.swift:18` (boot-time configuration error — reasonable).

## 6. Naming inconsistency table

| Pair | A (Swift) | B (Swift) | Canonical | Blast radius |
|---|---|---|---|---|
| activity / history | 39 / 57 | 33 / 28 | **activity** (UI = "Actividad" tab + folder; "history" usage skews to internal/comments) | Medium — `HistoryItemPresentation`, `routeFromHistoryEvent` would rename |
| money / ledger | 84 / 97 | 35 / 64 | **ledger** (already canonical in `LedgerRepository`, `MyLedgerCoordinator`, `ResourceLedgerCoordinator`, `openLedger` action) | Low — rename "money" residuals (`Features/Resources/Money/` folder, `RuulMoneyView`) |
| rules / governance | 320 / 168 | 660 / 251 | **rules** for behavioral, **governance** for meta (per `project_group_governance_rules` memory). Keep both. | None |
| access / access_control | 24 / 0 | 42 / 4 | **access** | None (4 SQL hits are vestigial) |
| ownership / right | 16 / 207 | 15 / 315 | **right** is the resource; **ownership** = derived projection (`asset_ownership_view`) | None |
| booking / reservation | 79 / 0 | 101 / 1 | **booking** (canonical; "reservation" essentially absent) | None |
| slot / booking | 204 / 79 | 225 / 101 | distinct concepts — slot = resource, booking = action verb. Keep both. | None |
| event / occurrence | 880 / 15 | 920 / 62 | **event** = resource type, **occurrence** = single instance of a series. Keep both. | None |
| resource / object | 579 / 158 | 484 / 59 | **resource** (per ontology constitution) | Low — most "object" hits are Swift `[String: Any]`, not the doctrine concept |
| role / permission | 230 / 96 | 365 / 183 | distinct — keep both | None |
| holder / owner | 53 / 10 | 121 / 27 | **holder** (right_holder is canonical) | Low — 10/27 "owner" residuals likely safe to rename |

## 7. Orphan references to recently-deleted files

Zero in app/SQL/edge code. Only refs are in spec docs:
- `/Users/jj/code/tandas/docs/superpowers/specs/2026-05-18-resource-detail-intent-refactor-design.md` (multiple lines) — references `ManageCapabilitiesSheet`, `GovernanceTabView`, `AdvancedCapabilitiesView`, `EditCapabilityConfigSheet`, `SettingsSectionView`. The spec is a *plan* that was partially implemented then walked back; safe but stale.
- `supabase/migrations/00223_resource_capabilities_enabled_by_default_auth_uid.sql:8` mentions `ManageCapabilitiesSheet` in a comment.

No live code orphans — the prior `enableCapability` cleanup was thorough.

## 8. Confidence levels for delete recommendations

| Item | Confidence | Status |
|---|---|---|
| `SecondaryAction.enableCapability` case + the `.enableCapability:` arm | HIGH | pending |
| `ResourceType.capabilitiesAreUserManaged` | HIGH | pending |
| ~~Edge fn `finalize-votes`~~ | **WRONG** | now scheduled, KEEP |
| ~~Edge fn `generate-wallet-pass`~~ | **WRONG** | intentional stub, KEEP |
| ~~Edge fn `send-fine-reminders`~~ | **WRONG** | production-ready, KEEP |
| `RuulFlowChips`, `RuulSubTabBar` | HIGH | ✅ deleted `bb89e35` |
| 4 `*CardStub` files + 3 templates (MainAppScreenTemplate / DetailScreenTemplate / ResourceTabBar) | MEDIUM (showcase-only — confirm Showcase still needed) | pending |
| `RuulStatePatterns+Aliases` typealiases | HIGH | ✅ deleted `bb89e35` |
| Orphan RPCs `advise_stuck_fines`, `fines_resource_id_parity_check`, `events_resources_parity_check`, `cast_ballot` | MEDIUM (verify no triggers/cron) | pending |

## 9. First 10 safe deletes (commit 1, low risk)

1. ✅ `ios/Packages/RuulUI/Sources/RuulUI/Primitives/RuulFlowChips.swift` — DONE `bb89e35`
2. ✅ `ios/Packages/RuulUI/Sources/RuulUI/Primitives/RuulSubTabBar.swift` — DONE `bb89e35`
3. ✅ `ios/Packages/RuulUI/Sources/RuulUI/Patterns/RuulStatePatterns+Aliases.swift` — DONE `bb89e35`
4. `SecondaryAction.enableCapability` case (RuulCore/Capabilities/SecondaryAction.swift:33) + matching arm in `UniversalResourceDetailView.swift:722-726`
5. `ResourceType.capabilitiesAreUserManaged` (RuulCore/PlatformModels/ResourceType.swift:74-86)
6. ~~`supabase/functions/generate-wallet-pass/`~~ — KEEP (intentional stub, see §3 correction)
7. ~~`supabase/functions/finalize-votes/`~~ — KEEP (now scheduled via mig 00327)
8. ~~`supabase/functions/send-fine-reminders/`~~ — KEEP (production-ready)
9. Stale spec doc cleanup: `docs/superpowers/specs/2026-05-18-resource-detail-intent-refactor-design.md` — annotate as superseded, OR move to `docs/superpowers/specs/_archive/`
10. Rename folder `Features/Resources/Money/` → `Features/Resources/Ledger/` to match canonical naming (and rename `MoneyView` related helpers)

Replacement candidates (items moved out of #6-8):
6'. Restore source for `finalize-appeal-votes`, `evaluate-event-rules`, `export-user-data` (deployed-not-in-repo). Task #18.
7'. Add cron schedule for `send-fine-reminders` (product decision pending). 
8'. Migration to formalize remaining dashboard-only crons in version control (10+ jobs predating mig 00030 pattern).

## 10. Beta blockers

None found. The audit surface is clean: no live orphan references to recently-deleted views, no unreachable Shell/Routing entries, and only 5 TODOs in app code. The biggest doctrinal nit is the *Money vs Ledger* split — code is mostly already on "ledger" but `RuulMoneyView` and `Features/Resources/Money/` linger.

Notes:
- The 256 RPC vs 158 caller gap likely includes ~80 trigger functions wired via `CREATE TRIGGER` (e.g. `atom_no_mutation_guard`, `bump_*_version`, `data_deletion_log_atom_guard`) — these are NOT dead, they're just not `.rpc()`-called. A proper RPC death audit needs to subtract the trigger set.
- `EventDetailCoordinator.generateWalletPass()` (line 397) returns `nil` without invoking anything — this UI affordance (`SecondaryAction.generateWalletPass`, surfaced by capability resolver) is silently a no-op. Either implement or remove the action.
