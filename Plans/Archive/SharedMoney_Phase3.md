# SharedMoney — Phase 3 (Group Money UI)

**Status:** IN PROGRESS — bricks 1-5 implemented (brick 1 in `838e76c`; card + coordinator + GroupSpaceView wiring + sheets + list filter on this branch). Pending: Xcode build/test verification + simulator smoke (no Swift toolchain in the authoring env).
**Depends on:** Phase 1 (data model — committed `c3bb8e14`), Phase 2 (wrappers — committed `2a4425a1` + `9f67578d`).
**Doctrines:**
- `doctrine_shared_money.md` — Shared Money is default; resources contextualize.
- `doctrine_fund_per_event_deprecation.md` — Phase 3 removes UI affordance; backend stays alive.
- `feedback_dont_touch_ruului_base.md` — compose at feature layer, NO new RuulUI primitives.

---

## 0. Phase 3 goals & non-goals

### In scope
- Add a **"Dinero compartido" section** to `GroupSpaceView` showing the shared pool's balance + activity + two CTAs.
- Two new sheets: `RecordSharedExpenseSheet` + `ContributeToSharedMoneySheet` (group-scoped, no `fundId` knowledge required).
- `GroupHomeCoordinator` extended with `sharedPoolSummary` field, populated from `group_money_summary_view`.
- `GroupFundsListView` adjusted to **hide** the shared pool row (it has its own surface up top); the tile/list rename "Fondos" → "Otros fondos".
- Vocab introduction: "Dinero compartido", "Gastos", "Aportaciones". No mass rename of existing "Fondo" surfaces yet — gradual per the deprecation doctrine.

### Out of scope (later phases)
- "Pendientes" / "Obligaciones" CTAs in the SharedMoneyCard (those primitives don't exist yet — Phase 5).
- "Ver pendientes" / "Settle up" button (Phase 5).
- Resource Money Block on Event/Asset/Space detail (Phase 4).
- Killing the legacy `RecordExpenseFromFundSheet` / `ContributeToFundSheet` (Phase 6 — Protected Funds advanced surface still uses them).
- Mass vocab sweep across fund-specific surfaces (Phase 6).

---

## 1. Audit findings (from 2026-05-21 explore)

### Group landing surface
`GroupSpaceView.swift` is a `LazyVStack(spacing: .xl)` with five sections:
1. `GroupPresenceHeader` — hero (always shown)
2. `GroupComposeBar` — "Coordinar" chips (always shown)
3. `GroupPendingsBlock` — pending actions (**conditional**)
4. `GroupSpacesGrid` — 2×2 tiles (Eventos · Decisiones · Multas · Fondos) (always shown)
5. `GroupStreamBlock` — activity (**conditional**)

### Where funds appear today
- ONLY as a "Fondos" tile in `GroupSpacesGrid` → tap → `GroupFundsListView` (separate screen).
- No balance/CTA preview in the group home itself.

### Sheet call sites
- `ContributeToFundSheet` / `RecordExpenseFromFundSheet` are invoked exclusively from fund detail. Zero group-level CTAs today.

### AppState
- `GroupHomeCoordinator` already owns `fundRepo`; refresh() loads pendings + activity but NOT a money summary.
- No `SharedPoolSummary` model exists yet.

### Design system
- NO pre-composed `SummaryCard`/`BalanceCard` primitive in RuulUI.
- Composition pieces available: `.ruulCardSurface(.solid|.glass)`, `RuulMoneyView`, `RuulButton`, `.ruulGlass()`.
- Must compose at feature layer (RuulUI in DELETE mode per `feedback_dont_touch_ruului_base.md`).

### Vocab footprint
- 37 "fondo" + 24 "Fondos" across 20 files. All localized to fund-specific surfaces. Phase 3 sweep is minimal (touches `GroupSpaceView` tile label + `GroupFundsListView` title + the shared-pool exclusion logic).

### Tests
- No snapshot harness for `GroupSpaceView` today. Phase 3 introduces preview-based fixtures only — no XCTest snapshot.

---

## 2. UI layout (new GroupSpaceView order)

```
GroupPresenceHeader        (unchanged)
GroupComposeBar            (unchanged — "Coordinar" chips)
SharedMoneyCard            ← NEW (always shown, even with 0 balance)
GroupPendingsBlock         (unchanged, still conditional)
GroupSpacesGrid            (tile "Fondos" → "Otros fondos" label change)
GroupStreamBlock           (unchanged)
```

The card sits high (right under compose chips) because money is high-frequency interaction. It stays stable across pendings being empty/non-empty so the layout doesn't shift on every refresh.

### SharedMoneyCard shape
```
┌───────────────────────────────────────────────────────────┐
│  Dinero compartido                                          │
│                                                             │
│  $4,200 MXN                              [Aportar]          │
│  Saldo disponible                        [Registrar gasto]  │
│                                                             │
│  · Última actividad: hace 3 días                            │
└───────────────────────────────────────────────────────────┘
```

Composed from:
- Container: `.ruulCardSurface(.solid)` on a `VStack`.
- Title: SF Pro Text body weight semibold, primary color.
- Balance: `RuulMoneyView(.large, .neutral)`.
- CTAs: HStack of two `RuulButton(.secondary, .medium)`.
- Subtle footer: SF Caption secondary color with relative date.

Empty-state variants:
- `balance == 0 && entry_count == 0`: balance "$0", footer "Aún sin movimientos".
- `balance > 0`: as above.
- `balance < 0` (over-spent shared pool): balance in `.warning` tone, footer "El fondo está en saldo negativo".

---

## 3. Data path

### New projection model
Create `SharedPoolSummary` as a new Swift `Projection` mirroring `group_money_summary_view`. Place at:
`Packages/RuulCore/Sources/RuulCore/PlatformModels/SharedPoolSummary.swift`

Fields:
- `groupId: UUID`
- `currency: String`
- `sharedPoolId: UUID`
- `inCents: Int64`
- `outCents: Int64`
- `balanceCents: Int64`
- `entryCount: Int64`
- `lastActivityAt: Date?`

### Repository extension
Either:
- (a) extend `FundRepository` with `summaryForGroup(groupId: UUID) async throws -> SharedPoolSummary?`
- (b) add a new tiny `SharedMoneyRepository` actor

**Decision: (a)** — shipped in `838e76c`. Keeps the repo surface coherent (it already does fund-shaped reads). The shared pool IS a fund row. Signature is `summaryForGroup(_ groupId: UUID, preferredCurrency: String?) async throws -> SharedPoolSummary?`.

Live impl reads **all** currency rows then filters — NOT `.single()`. The view emits one row per `(group, currency)` (it groups by `le.currency`), so `.single()` would throw on a multi-currency group. Instead: `from("group_money_summary_view").select().eq("group_id", gid)` → decode `[SharedPoolSummary]` → return the row matching `preferredCurrency` (the group's currency), else `rows.first`. Multi-currency UI (V1.5+) can read all rows.

Mock impl: derive from the seeded `Fund` snapshot for the group (same `preferredCurrency` pick logic). Test fixtures seed one fund per group (the implicit shared pool); server-side resolution is authoritative.

### Coordinator wiring
Extend `GroupHomeCoordinator`:
- Add `var sharedPoolSummary: SharedPoolSummary?`
- In `refresh()`, kick off a `fundRepo.summaryForGroup(groupId, preferredCurrency: nil)` task in parallel with the other group-scoped loads (currency isn't known until `detail` resolves; for V1 single-currency the view emits exactly one row, so `preferredCurrency: nil` → `rows.first` is the group's currency. Multi-currency V1.5+ will pass the resolved currency).
- View binds to the coordinator's published `sharedPoolSummary`.

---

## 4. New sheets (group-scoped)

### `RecordSharedExpenseSheet`
Mirror of `RecordExpenseFromFundSheet` but:
- Takes `groupId: UUID` + `currency: String` + `members: [MemberWithProfile]` + optional `sourceResource: (id, name)` (for Phase 4 reuse).
- Submits via `fundRepo.recordSharedExpense(groupId:…)`.
- Drops the "fund name" header (uses "Registrar gasto" as the only title).
- Keeps the dual-picker pattern (Quién pagó / Reembolsar a) from Phase 1 work.
- Keeps the `clientId` idempotency pattern.

### `ContributeToSharedMoneySheet`
Mirror of `ContributeToFundSheet`:
- Takes `groupId` + `currency` + optional `sourceResource`.
- Submits via `fundRepo.contributeToSharedMoney(groupId:…)`.
- Title "Aportar al dinero compartido" (NOT "Aportar al fondo").

Both sheets live at `Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Sheets/`.

Old fund-shaped sheets stay alive untouched per `doctrine_fund_per_event_deprecation.md`.

---

## 5. Sheet routing from SharedMoneyCard

The two CTA buttons present sheets via `.sheet(item:)` driven by a small enum in `GroupSpaceView`:
```swift
enum SharedMoneySheet: Identifiable { case record, contribute }
@State private var sharedMoneySheet: SharedMoneySheet?
```

The `RuulSheet` doctrine memory `doctrine_ruul_sheet_on_sheet_doctrine.md` says quick-action → sheet + detents. Both sheets are quick-action shape — use `.presentationDetents([.medium, .large])` and standard `.ruulSheetToolbar`.

---

## 6. Legacy funds handling

3 active dev groups + 6 legacy fund rows. After mig 00359 every group also has 1 shared pool. Phase 3 UI posture:

- **`GroupSpaceView`** shows `SharedMoneyCard` (canonical).
- **`GroupSpacesGrid` "Fondos" tile** → relabel to **"Otros fondos"**. Hidden entirely when the group has no non-shared-pool funds (most groups eventually).
- **`GroupFundsListView`** → filter OUT the shared pool row by cross-referencing `Fund.fundId == sharedPoolSummary.sharedPoolId` (founder decision 9.1, option (c) — zero schema change, no new flag on `Fund`). The view already loads the summary, so the id is in hand.
- **Empty state in GroupFundsListView**: when nothing remains after filtering, show "No hay fondos separados. Todo el dinero del grupo está en Dinero compartido." with no "Crear fondo" CTA (Phase 6 will surface that under Advanced).

---

## 7. Vocab sweep scope (Phase 3 minimal)

Only TWO labels change in this phase:
- `GroupSpaceView` "Fondos" tile label → **"Otros fondos"** (and hide tile when count=0).
- `GroupFundsListView` title "Fondos" → **"Otros fondos"**.

NEW labels introduced (no rename involved):
- "Dinero compartido" — section header on the new card.
- "Saldo disponible" — balance caption.
- "Aportar" — CTA.
- "Registrar gasto" — CTA.
- "Aportar al dinero compartido" — sheet title.

Everything else ("Fondo", "Fondos" inside fund detail surfaces) stays UNTOUCHED. Phase 6 (Protected Funds) will revisit when the advanced surface lands.

---

## 8. Tests / preview fixtures

No snapshot framework exists for group surfaces today. Phase 3 adds:
- `#Preview` macros on `SharedMoneyCard` showing all three states (zero, positive, negative balance).
- `#Preview` on the rewired `GroupSpaceView` consuming `MockFundRepository` with seeded summary.
- Unit test for `MockFundRepository.summaryForGroup` returning the right aggregates.
- Unit test for `GroupFundsListView` filter logic excluding the shared pool.

Snapshot tests deferred — there's no harness today, introducing one is its own brick.

---

## 9. Founder decisions (locked 2026-05-21)

1. **Detecting shared pool from iOS.** ✅ Option (c): cross-reference `Fund.fundId == SharedPoolSummary.sharedPoolId`. Zero-schema-change. `GroupFundsListView` reads both views and filters.

2. **"Otros fondos" tile visibility.** ✅ Hide tile entirely when count=0.

3. **SharedMoneyCard empty state.** ✅ Both CTAs always enabled. Expense on an empty pool goes negative — valid IOU state.

4. **Sheet detent.** ✅ `.medium` default with `.large` available.

5. **Currency.** ✅ V1 reads the row matching `groups.currency`. Multi-currency UI deferred to V1.5+.

---

## 10. Phase 3 DoD

- [x] `SharedPoolSummary` model added to RuulCore. *(838e76c)*
- [x] `FundRepository.summaryForGroup(_:preferredCurrency:)` implemented in protocol + Mock + Live. *(838e76c)*
- [x] `GroupHomeCoordinator` loads + exposes `sharedPoolSummary` (+ `allMembers`, `otherFundsCount`).
- [x] `SharedMoneyCard` view component composed from existing RuulUI primitives.
- [x] `GroupSpaceView` renders the card between compose bar and pendings.
- [x] `RecordSharedExpenseSheet` + `ContributeToSharedMoneySheet` ship with `.medium`/`.large` detents.
- [x] `GroupFundsListView` filters out shared pool; tile relabeled to "Otros fondos"; hidden when count=0.
- [ ] Build green, no warnings. *(pending — no Swift toolchain in this env; needs Xcode verify)*
- [x] `#Preview` on SharedMoneyCard renders all three states.
- [x] Unit tests: `MockFundRepository.summaryForGroup` aggregates / over-spent / nil / preferredCurrency.
- [ ] Unit test for `GroupFundsListView` filter logic — deferred; filter is a one-line inline `.filter` in the view's `load()`, not worth extracting a testable seam for now.
- [ ] Functional smoke on simulator: tap "Aportar" → fill amount → submit → balance refreshes. *(pending — needs simulator)*

---

## 11. Phase 4 handoff

What Phase 4 needs from Phase 3:
- `RecordSharedExpenseSheet` accepts optional `sourceResource: (id, name)` so Phase 4's Event Money Block can present it pre-filled.
- `SharedPoolSummary` model exists and is consumed by the card → Phase 4's `resource_money_view` consumer follows the same pattern.

Phase 4 introduces:
- `ResourceMoneySummary` projection mirroring `resource_money_view`.
- `MoneyBlock` SwiftUI component on `EventDetailView` (then Asset, then Space).
- Reuses Phase 3 sheets with `sourceResource` pre-filled.

---

## 12. Risks

- **Refresh storm**: adding a parallel summary load to `GroupHomeCoordinator.refresh()` extends the loading critical path. Mitigation: load in parallel via `async let`, not sequentially.
- **Sheet duplication temptation**: future agents may want to "consolidate" the new + legacy sheets into one polymorphic view. Push back per `doctrine_fund_per_event_deprecation.md` — they serve different mental models for the next 2 phases.
- **Activity feed copy** for new entries: `HistoryItemPresentation.ledgerEntryCreated` still says "X registró un movimiento de dinero". Phase 3 doesn't change this; Phase 4 may refine to "X registró un gasto pagado por Y" when payload carries paid_by metadata.

---

**Next step:** founder confirms § 9 open questions; I start by adding `SharedPoolSummary` + `FundRepository.summaryForGroup(_:)` as the smallest PR. Then SharedMoneyCard composition. Then GroupSpaceView integration. Then sheets. Then filter on `GroupFundsListView`. Each as its own commit for granular rollback.
