# Resource Detail UI Audit

## 1. Architecture status: hybrid (catalog-driven core + 3 residual type checks)

The structural rewrite **did land**: there is now a single `UniversalResourceDetailView`, 4 universal tabs (`overview/activity/rules/connections`), `CapabilitySectionCatalog` with ~30 registered sections gated by `isEnabledFor(caps)` and (optionally) `isVisibleFor(ctx)`, an `INFORMACIÓN` card driven by `ResourceInfoRegistry` providers, and the four legacy capability-chrome files (`GovernanceTabView`, `ManageCapabilitiesSheet`, `AdvancedCapabilitiesView`, `EditCapabilityConfigSheet`) have been deleted **with zero remaining references** (rg confirms).

But three residues remain:
- **Dead orphan helpers** (`stubCapabilitySections`, `catalogSections(idIn:)`, `dynamicSectionIds`, `stubSectionIds`) at lines 494-561 of `UniversalResourceDetailView` — referenced only from inside the file, and the actual `tabContent` switch now uses `sectionsForTab(_:)` exclusively. Dead code.
- **Two leftover `resourceType ==` branches in the view body** (lines 521-522, 690).
- **Within-section type checks** (e.g. `ScheduleSectionView` line 31 hides itself for `.event`; `CapacityProgressSectionView` line 31 hides for `.event`; `RotationSectionView` early-returns for non-event at line 246; `MoneySectionView` line 281 fund-only lock). Doctrine allows these inside the section body when the section owns its own visibility, but several should migrate to `isVisibleFor` so the catalog filter is the single source of truth.

## 2. Concrete violations

- **`UniversalResourceDetailView.swift:494-561`** — DEAD CODE / REWRITE. `stubCapabilitySections`, `catalogSections(idIn:)`, `dynamicSectionIds`, `stubSectionIds` are unused now that `tabContent` uses only `sectionsForTab(_:)`. The huge `Static let stubSectionIds` doc comment ("must NOT appear in this set or the page renders twice") is now misleading.
- **`UniversalResourceDetailView.swift:690`** — DOCTRINAL DRIFT. `if context.resource.resourceType == .right { showEditRight = true } else { context.onPresentEditResource() }` is the last in-view per-type branch. Should be resolved through `SecondaryAction.kind` (e.g. `.editRight` vs `.editResource`) so the view is type-blind.
- **`UniversalResourceDetailView.swift:14`** — STALE DOC. The header docblock still describes a 7-section linear layout (`"6. Asset sections — Custody / Ownership / Maintenance / Bookings (only when resourceType == .asset)"`) that doesn't match the actual 4-tab segmented layout the file ships.
- **`UniversalResourceDetailView.swift:696-700`** — DEAD CASE. `.enableCapability` switch case explicitly notes "the resolver no longer emits this kind, so the case stays only for switch exhaustiveness". Confirm resolver no longer declares the case and drop it from `SecondaryAction.Kind`.
- **`ResourceSummaryView.swift` (Zones/)** — ORPHAN FILE. Defined publicly but never instantiated; `UniversalResourceDetailView` uses a different inline `hero` block. Delete or wire.
- **`Stubs/WorkflowSections.swift:84-112` (`ApprovalSectionView`)** — JARGON. Subtitle `"Flujo de aprobación todavía no wired al backend."` exposes implementation slang to the user.
- **`Stubs/GovernanceSections.swift:54-105` (`ConsequenceSectionView`)** — JARGON. The section id, label `"CONSECUENCIAS"`, and copy use rule-engine vocabulary directly. Violates `feedback_rules_ux_human`.
- **`ResourceSummaryView.swift:266-311` `capabilityChips`** — DOCTRINAL VIOLATION. Even though orphan, it directly enumerates capability names as user-visible chrome (`"rules", "Acuerdos", "ledger", "Ledger", "checkin", "Check-in"`). Confirms why it was dropped from the active view; should be deleted not retained.
- **`Stubs/AssignmentSections.swift:43-65` (`BookingSectionView`)** — INCOHERENT EMPTY STATE. Renders the stub "Para assets, las reservas viven en la sección CUPOS de abajo" but the view-level filter (lines 504-507 of `UniversalResourceDetailView`) suppresses it for assets/spaces. Result: the stub only ever shows for fund/right/slot/event/unknown — and the text contradicts itself there.
- **`ResourceDetailTab.swift:11-13`** — Doctrine doc is correct ("there is no Gobierno/capabilities tab") but the **Rules tab** + the empty-state copy "Sin reglas propias. Las reglas del grupo aplican aquí por defecto." is essentially the governance surface as primary chrome. Doctrinal grey area: rules-as-tab is acceptable if user-facing "if X then Y" copy, but `RulesSectionView` defers to `ResourceRulesBody` and that surface is where the jargon risk lives (not audited here).

## 3. Duplicated section logic

- **`ActivitySectionView.swift` (id `activity`, tab `activity`, priority 900)** vs **`Stubs/StateSections.swift` `HistorySectionView` (id `history`, tab `overview`, priority 950)** — both read `system_events` filtered by `groupId + resourceId` and render a vertical list. `history` is gated on the `history` capability so it only lights up when that cap is enabled; nothing currently seeds that cap, but as soon as it is, the user sees the same data under two cards. REWRITE: kill `HistorySectionView`, or convert `history` cap into an alias for `activity`.
- **Asset `AssetBookingsSection` (id `asset.bookings`, priority 163)** vs **Space `SpaceBookingsSection` (id `space.bookings`, priority 166)** — both implement "list bookings + create CTA" with near-identical card layouts. Same backend shape, two renderers. REFACTOR: a single `BookingsSection` parameterized by repo would collapse them.
- **`Asset/AssetSections.swift` `AssetCustodySection`** vs **`Space/SpaceSections.swift` `SpaceOccupancySection`** — same shape ("who's here / who has it now + action"). Different verbs, same UI primitive.
- **Hairline-card chrome** is reinvented per section: `cardBackground()` (defined in `ScheduleSectionView` of all places), `CapabilityStubCard`, `RuulInfoCard`. Three card primitives for the same job.

## 4. Section catalog single source of truth

`CapabilitySectionCatalog.shared` is now the single registry (great), but the source-of-truth invariant leaks:
- `UniversalResourceDetailView` still keeps `dynamicSectionIds` and `stubSectionIds` literal sets — orphaned after the tab refactor but still in the file.
- Three sections (`schedule`, `capacity_progress`, `rotation`) gate themselves inline on `resourceType` instead of via `isVisibleFor`, so a developer reading the catalog can't tell from the registration alone where the section will appear.
- Stub sections register with the catalog but always render in the `.overview` tab (default `tabId`). Once the `history` stub goes live it lands in overview, not activity — inconsistent with `ActivitySectionView`'s `tabId: "activity"`.

## 5. Orphan references to deleted files

None. `rg` for `GovernanceTabView|ManageCapabilitiesSheet|AdvancedCapabilitiesView|EditCapabilityConfigSheet` across the iOS tree returns zero hits. Deletion is clean.

## 6. Verdict per file (Detail/ tree)

- `UniversalResourceDetailView.swift` — KEEP, TRIM (drop dead `stubCapabilitySections`/`catalogSections`/two id-sets + the `.right` editor branch + stale header doc).
- `ResourceDetailTab.swift` — KEEP.
- `ResourceInfoRegistry.swift` — KEEP, clean.
- `CapabilitySection.swift` — KEEP, clean.
- `ResourceDetailContext.swift` — KEEP, clean.
- `Sections/Asset/AssetSections.swift` — KEEP. Properly registered via `isVisibleFor`.
- `Sections/Space/SpaceSections.swift` — KEEP, but consider unifying `SpaceBookingsSection` + `AssetBookingsSection`.
- `Sections/FundBalanceSection.swift` + `RightInfoProvider.swift` — KEEP, clean.
- `Sections/RulesSectionView.swift` — KEEP. Capability-gated and tab-routed correctly.
- `Sections/ResourcesUsedSectionView.swift` — KEEP, well-gated (event-only via `isVisibleFor` + tab `connections`).
- `Sections/ActivitySectionView.swift` — KEEP, canonical activity surface.
- `Sections/RSVPSectionView.swift`, `CheckInSectionView.swift`, `HostActionsSectionView.swift`, `MoneySectionView.swift`, `RotationSectionView.swift`, `ScheduleSectionView.swift`, `LocationSectionView.swift`, `DescriptionSectionView.swift`, `CapacityProgressSectionView.swift` — KEEP, mostly clean. `RotationSectionView` and `ScheduleSectionView` should push their inline type guards into `isVisibleFor`.
- `Sections/Stubs/StateSections.swift` — DELETE `HistorySectionView` (dup); KEEP `StatusSectionView`.
- `Sections/Stubs/GovernanceSections.swift` — REWRITE. `ConsequenceSectionView` is jargon; `VotingSectionView` is acceptable.
- `Sections/Stubs/WorkflowSections.swift` — REWRITE copy in `ApprovalSectionView` ("wired al backend"); rest are placeholder-honest.
- `Sections/Stubs/AssignmentSections.swift` — KEEP `AssignmentSectionView`; DELETE `BookingSectionView` (filtered out for asset/space, contradictory copy elsewhere).
- `Sections/Stubs/AssetMetaSections.swift` — KEEP (declarative metadata renderers).
- `Sections/Stubs/TimingSections.swift` — KEEP.
- `Sections/Stubs/CapabilityStubCard.swift` — KEEP, but consider merging with `RuulInfoCard`.
- `Sections/RightInfoProvider.swift`, `Sections/EditRightSheet.swift`, `Sections/RightActionSheet.swift`, `Sections/ContributeToFundSheet.swift`, `Sections/RecordExpenseFromFundSheet.swift`, `Sections/SettlementSheet.swift` — KEEP (sheet primitives).
- `Zones/DetailAttentionView.swift` — KEEP.
- `Zones/ResourceSummaryView.swift` — DELETE. Orphan: no caller, contains the capability-chip primary-chrome doctrinal violation.
- `Adapters/*` — out of scope, event-detail bootstrap glue.
- `Sheets/AttendeesListSheet.swift`, `Sheets/LinkResourcePickerSheet.swift` — KEEP.
- `Subviews/RSVPAvatarStrip.swift` — KEEP.

## 7. Beta blockers for resource detail UI

1. **Delete `Zones/ResourceSummaryView.swift`** — orphan + raw capability-chip chrome.
2. **Trim `UniversalResourceDetailView.swift`** — remove `stubCapabilitySections`, `catalogSections(idIn:)`, `dynamicSectionIds`, `stubSectionIds`, the `.enableCapability` dead case, and the stale header comment; replace the `.right`-vs-other edit branch with a resolver kind.
3. **Resolve the activity/history duplication** — drop `HistorySectionView` or alias the `history` cap onto activity.
4. **Rewrite jargon copy** in `ConsequenceSectionView` and `ApprovalSectionView`.
5. **Delete `BookingSectionView` stub** — filtered out for the only relevant types and self-contradictory elsewhere.
6. **Push `RotationSectionView` / `ScheduleSectionView` / `CapacityProgressSectionView` type guards into `isVisibleFor`** so the catalog stays the single source of truth.
7. **Audit `ResourceRulesBody` (consumed by `RulesSectionView`)** — not in this file tree but it's where the WHEN/IF/THEN jargon risk really lives; flag for a follow-up audit.

Nothing is a hard blocker (no broken builds, no orphan imports), but items 1-5 are quick wins that materially close the gap between the current code and the "ONE polymorphic page, capabilities never as primary chrome" doctrine.
