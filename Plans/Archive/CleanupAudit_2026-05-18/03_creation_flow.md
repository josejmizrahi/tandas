# Resource Creation Flow Audit — Verdict: Redesign NOT shipped

## 1. Creation flow status

**Redesign infrastructure built, ZERO production wiring.** The new `ResourceVariantRegistry`, `ResourceIntentRegistry`, `LazyCapabilityActivator` exist as standalone files (1,237 LOC total across `Variants/` + `Intents/`) but nothing in `RuulFeatures/` imports them. The only consumers are unit tests in `TandasTests/Resources/`. AppState (`/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/AppState.swift`) does NOT instantiate them.

The "+" tab still routes to the **old 5-step wizard with capability toggles** (`RootShellSheets.swift:107` → `ResourceWizardSheet`).

## 2. Spec components present vs missing

| Spec component | Exists? | Path | Status |
|---|---|---|---|
| `ResourceVariant` data | Yes | `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Resources/Variants/ResourceVariant.swift` | Built, unused |
| `ResourceVariantRegistry` | Yes | `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Resources/Variants/ResourceVariantRegistry.swift` | Built, 18 variants (3 per type), unused |
| `ResourceIntent` data | Yes | `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Resources/Intents/ResourceIntent.swift` | Built, unused |
| `ResourceIntentRegistry` | Yes | `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Resources/Intents/ResourceIntentRegistry.swift` | Built, 18 intents, unused |
| `LazyCapabilityActivator` | Yes | `/Users/jj/code/tandas/ios/Packages/RuulCore/Sources/RuulCore/Resources/Intents/LazyCapabilityActivator.swift` | Built, only test references |
| `ResourceCreationCoordinator` | **MISSING** | — | Spec says it should orchestrate Type → Variant → Identity → Create → Intents |
| `MinimalIdentityForm` | **MISSING** | — | Step 3 identity-only form not implemented |
| `PostCreateIntentScreen` | **MISSING** | — | Post-create intent grid screen not implemented |
| `PostCreateIntentDispatcher` | **MISSING** | — | Referenced in `LazyCapabilityActivator.swift:6` docstring; doesn't exist in code |
| AppState wiring (`resourceVariants`, `resourceIntents`, `lazyActivator`) | **MISSING** | `AppState.swift` | No properties exposed |
| Old wizard gated to Advanced or removed | **NO** | `RootShellSheets.swift:107` | Old wizard is the primary and only path |

## 3. Concrete violations

- **Capability toggles still surface to users**: `ResourceWizardSheet.swift:371-426` (`capabilityRow`), explicit `Toggle` at line 383-388. Section header "¿Qué más quieres que pase?" at line 324. Step is labeled `.options` with title "Opciones" (line 779). The spec says capabilities are hidden.
- **Suggested rules toggle UI**: `ResourceWizardSheet.swift:574-600` (`suggestedRuleRow`) — users tick rules at create time, even though the redesign defers rules to a `add_rules` post-create intent.
- **Wizard writes capabilities directly via `ResourceDraft`**, NOT through `LazyCapabilityActivator`: `ResourceWizardCoordinator.swift:429-437` constructs `ResourceDraft(enabledCapabilities: Array(enabledCapabilities), capabilityConfigs: …)` and the builder writes them.
- **Hardcoded vertical switch in wizard**: `ResourceWizardSheet.swift:135-145` `coverFor(type:)` — though purely cosmetic (cover gradient), the resource-type switch is still vertical-shaped UX code in the wizard surface.
- **Recurrence special-case**: `ResourceWizardCoordinator.swift:363-392` (seriesPattern construction) and `:595-619` (`seedCapabilityConfigDefaults` Thursday/20:00 hardcode for `recurrence`) — capability-specific knowledge baked into the coordinator instead of declarative variant data.
- **Type→category mapping hardcoded by type**: `ResourceWizardSheet.swift:972-981` (`WizardCategory.types`) — vertical-shaped.

**Compliant**: `defaultCapabilitiesFor(_:)` in `ResourceWizardCoordinator.swift:522-553` correctly reads from `template.config.defaultCapabilities` and never hardcodes by resource_type. Monetary fines correctly stay off (`:252` only pre-selects `defaultEnabled` rules). This is in line with `feedback_create_flow_defaults`.

## 4. ResourceWizardSheet split proposal (1127 LOC)

Decompose the file into focused subviews + delete most of it once the redesign ships:

1. `WizardTypePicker` (lines 996-1127, ~130 LOC) — already isolated, keep as is.
2. `WizardFieldsStep` (lines 97-316, ~220 LOC) — extract `fieldsContent`, `fieldStack`, `timelineCard`, date binding helpers, `headerForBuilder`.
3. `WizardOptionsStep` (lines 320-436, ~120 LOC) — `optionsContent`, `capabilityRow`, `emptyCapabilitiesView`. **Targeted for deletion in redesign.**
4. `WizardRulesStep` (lines 440-600, ~160 LOC) — universals + per-capability rules. **Targeted for deletion in redesign** (rules become a post-create intent).
5. `WizardReviewStep` (lines 605-771, ~170 LOC) — `reviewContent`, `reviewHeader`, `reviewFields`, `reviewCapabilities`, `reviewRules`, `displayValue`. Becomes a small create-confirm card.
6. `WizardSubmitController` (lines 827-942, ~120 LOC) — `submit`, `publishSelectedUniversals`, `mergedParams`, `rebuildCoordinatorWithTemplate`. Migrate to `ResourceCreationCoordinator`.

Under the redesign, only chunks 1 + parts of 2 + 5 survive; the rest is replaced by `PostCreateIntentScreen`.

## 5. Verdict per file in Resources/ root

- **`ResourceWizardCoordinator.swift` (676 LOC)** — Pre-redesign coordinator. Will be replaced by `ResourceCreationCoordinator`. Keeps the old capability-pick model + suggested-rule picks + recurrence pattern building. Delete after migration.
- **`ResourceWizardSheet.swift` (1127 LOC)** — Pre-redesign 5-step sheet. Capability toggles + rule toggles. Must be either gone or gated to Advanced. Currently the primary creation surface. **Beta blocker.**
- **`Variants/` (6 catalog files + protocol + struct, 565 LOC)** — Cleanly declarative. 18 variants ship, hidden ones listed as comments. Universal vocabulary respected. **Good.**
- **`Intents/` (4 files, 592 LOC)** — Universal verbs (`invite_people`, `track_money`, `record_expense`, `allow_reservations`, `add_rules`, etc.), NOT per-resource-type. Resource-type set on each intent for filtering. `LazyCapabilityActivator` has 3 honest gates (catalog/stable/available), idempotent, sane outcome buckets. **Good.**
- **`Edit/ResourceEditCoordinator.swift`** — Edit path still uses `ResourceWizardCoordinator` (`rg` confirms import). Edit is out of redesign scope per spec, acceptable.

## 6. Beta blockers

1. **No `ResourceCreationCoordinator`** — the orchestrator that strings Type → Variant → Identity → Create → Intent does not exist.
2. **No `MinimalIdentityForm`** — Step 3 needs to render only the variant's `identityFields`, not all builder requiredFields.
3. **No `PostCreateIntentScreen`** — the entire post-create surface (intent grid, primer sheets, dispatcher) is unimplemented; the variant's `suggestedIntents` and `postCreateHeadline` have no rendering target.
4. **No `PostCreateIntentDispatcher`** — required to route from intent → `LazyCapabilityActivator.ensure(...)` → destination (referenced in docstring at `LazyCapabilityActivator.swift:6` but never coded).
5. **AppState not extended** — the `+` tab cannot present the new flow because AppState doesn't expose `resourceVariants` / `resourceIntents` / `lazyCapabilityActivator`.
6. **Old wizard still primary** — `RootShellSheets.swift:107` and `RootRouter.swift:45` (`createCover`) route to `ResourceWizardSheet`. Per `feedback_dont_strip_working_entries` you can't delete this until the new surface is wired, but it should at minimum be feature-flagged or behind an Advanced toggle once `ResourceCreationCoordinator` ships.
7. **Capability toggles + rule toggles still visible to users** — both violate the "capabilities are hidden / intent-driven" doctrine.

**Bottom line**: redesign is **maybe ~25% landed** — pure data (variants + intents catalogs) and one service actor (`LazyCapabilityActivator`) exist with passing unit tests, but the entire UI layer, the coordinator, the dispatcher, AppState wiring, and the cutover from the old wizard are missing. The flow the user actually sees today is unchanged from before 2026-05-18.
