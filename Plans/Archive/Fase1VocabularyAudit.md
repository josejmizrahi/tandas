# FASE 1 — Vocabulary Audit (Deliverable D / human-layer follow-up)

**Status**: Read-only audit, 2026-05-19.
**Scope**: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/` (209 archivos) + `ios/Packages/RuulUI/Sources/RuulUI/` (89 archivos) + `ios/Tandas/` (entry + Shell).
**Doctrine source**: `~/Library/.../memory/fase1_native_refactor_doctrine.md` § "Human-layer enforcement".
**Companion**: `Plans/Active/Fase1NativeAudit.md` §6 (lista parcial — esta sesión la completa).

## Banned vocabulary (ban-list)

EN: `capability`, `module`, `projection`, `atom`, `resource_type`, `trigger`, `consequence`, `rule shape`, `governance`, `governance hierarchy`, `ledger`.
ES: `capacidad`, `módulo`, `proyección`, `átomo`, `tipo de recurso`, `disparador`, `gobierno`, `gobernanza`, `libro mayor`.

Doctrine replacement set: `people, activity, money, rules, schedule, access, history, ownership, participation` (English shorthand). Each row in Tabla 1 maps to a contextual suggestion below.

---

## Tabla 1 — Direct violations (string user-facing rendered as copy)

Every row is a literal string the user reads on-screen. Sorted by feature folder.

| file:line | exact string | context | suggested replacement |
|---|---|---|---|
| `Activity/Views/ActivityView.swift:262` | `"Gobernanza"` | Filter-chip label in Activity feed (`ActivityChip.governance.label`) | `"Acuerdos"` (matches sibling chips `Dinero`, `Recursos`, `Miembros`) |
| `Activity/Views/HistoryItemPresentation.swift:206` | `"\(actor) actualizó la gobernanza"` | History row title for `.governanceUpdated` system event | `"\(actor) cambió las reglas del grupo"` |
| `Activity/Views/HistoryItemPresentation.swift:222` | `"\(actor) cambió una capacidad"` | History row title for `.capabilityToggled` event | `"\(actor) activó/desactivó una función"` — or even more concrete based on payload (`"…activó multas"`, `"…desactivó RSVP"`) |
| `Activity/Views/HistoryItemPresentation.swift:226` | `"\(actor) editó la configuración de una capacidad"` | History row title for `.capabilityConfigUpdated` event | `"\(actor) ajustó una función del grupo"` |
| `Group/Subscreens/GovernanceView.swift:53` | `.ruulSheetToolbar("Gobierno")` | Whole-screen sheet title for the governance editor | `"Decisiones del grupo"` or `"Acuerdos del grupo"` (open question — see below) |
| `Group/Subscreens/GovernanceView.swift:97` | `"¿Quién cambia este gobierno?"` | Card title for the `modifyGovernance` permission selector | `"¿Quién cambia estas decisiones?"` o `"¿Quién puede editar esta misma página?"` (the subtitle "Quién puede editar las preguntas de esta misma página." already carries the precise meaning, so the card title can shorten) |
| `Group/Subscreens/RulePresetsView.swift:82` | `.ruulSheetToolbar("Gobierno del grupo")` | Sheet title for the preset picker | `"Cómo decide este grupo"` (matches the heading already used at `RulePresetsView.swift:93`) |
| `Group/Views/GroupHomeView.swift:284` | `sectionContainer(title: "ACUERDOS Y GOBERNANZA")` | Section header on group home info screen | `"ACUERDOS Y DECISIONES"` or just `"REGLAS Y DECISIONES"` |
| `Group/Views/GroupHomeView.swift:287` | `label: "Módulos activos"` | Nav-row label on group home (count of active modules) | `"Funciones activas"` (consistent with `RulePresetsView.swift:52` "funciones nuevas") |
| `Group/Views/GroupHomeView.swift:300` | `navRow(... label: "Gobernanza", ...)` | Nav-row to `GovernanceView` | `"Decisiones"` (same target as new sheet title) |
| `Group/Views/GroupHomeView.swift:302` | `navRow(... label: "Estilo de gobernanza", ...)` | Nav-row to `RulePresetsView` | `"Estilo de decisiones"` or `"Política del grupo"` (open question) |
| `Group/Subscreens/ModulesPickerView.swift:40` | `.navigationTitle("Módulos")` | Picker screen title | `"Funciones"` |
| `Group/Subscreens/ModulesPickerView.swift:92` | `self.error = "No pudimos cambiar el módulo."` | Inline error inside ModulesPicker | `"No pudimos cambiar la función."` |
| `Groups/Settings/GroupRulesCoordinator.swift:38` | `self.error = "No pudimos cargar la gobernanza del grupo."` | Error state in group-rules screen | `"No pudimos cargar las reglas del grupo."` |
| `Onboarding/Founder/Coordinator/FounderOnboardingCoordinator.swift:388` | `summary: "Grupo sin reglas ni módulos. Tú decides qué agregar después."` | "Empezar de cero" preset summary in onboarding | `"Grupo sin reglas ni funciones preseteadas. Tú decides qué agregar después."` |
| `Resources/ResourceWizardSheet.swift:967` | `case .governance: return "Gobernanza"` | Category Picker option inside `ResourceWizardSheet`'s resource-type grouping | `"Decisiones"` or `"Acuerdos"` |
| `Resources/ResourceWizardSheet.swift:1092` | `.accessibilityHint("Este tipo de recurso aún no se puede crear.")` | VoiceOver hint on disabled tile | `"Este tipo aún no se puede crear."` (drop "de recurso" — `humanLabel` from `ResourceType` already names the thing) |
| `Resources/ResourceWizardCoordinator.swift:170` | `error = "Este tipo de recurso aún no está disponible."` | Error from `selectType` fallback | `"Este tipo aún no está disponible."` (same rationale) |
| `Resources/ResourceWizardCoordinator.swift:667` | `return "Capacidad no soportada: \(id)"` | User-facing builder error string for `.unsupportedCapability` | `"Función no soportada: \(id)"` |
| `Resources/Detail/Sections/EditRightSheet.swift:93` | `TextField("Capability gobernada (opcional)", text: $targetCapability, prompt: Text("booking | voting | access | …"))` | Form field label inside right-edit sheet | **Two-word violation** (capability + gobernada). Open question: is this field surfaced to end-users? If yes: `"Permiso vinculado (opcional)"` con placeholder `"reservar · votar · entrar · …"`. If admin/advanced-only: remove the field from this sheet and move to a developer/debug surface. |
| `Resources/Sheets/HostActions/AddEventRuleSheet.swift:57` | `emptyShapeMessage("No hay disparadores disponibles todavía.")` | Empty state under `triggerSection` | `"No hay 'cuándos' disponibles todavía."` o `"Aún no hay condiciones para esta regla."` (matches the section header "CUÁNDO" used directly above on line 53) |
| `Resources/Sheets/HostActions/AddEventRuleSheet.swift:107` | `emptyShapeMessage("No hay consecuencias disponibles todavía.")` | Empty state under `consequenceSection` | `"No hay efectos disponibles todavía."` (matches section pattern; "ENTONCES" is the existing header) |
| `Resources/Sheets/HostActions/EventRulesSheet.swift:256` | `case .module: return "Heredada · módulo"` | Badge label for module-scoped rules in the EventRulesSheet inheritance chip | `"Heredada · función"` o just `"Heredada"` (the parent scope is clear from siblings `Heredada · serie` / `Heredada · grupo`) |
| `Rules/EditRuleSheet.swift:82` | `Text("Disparador, condiciones y consecuencias. Crea una nueva versión preservando el historial.")` | Caption under "Editar composición completa" CTA | `"Cuándo, condiciones y qué pasa. Crea una nueva versión preservando el historial."` |
| `Rules/EditRulesCoordinator.swift:282` | `return "La gobernanza del grupo cambió. Tirá pull-to-refresh para ver los permisos actuales."` | Generic error mapper when policy/42501 returns | `"Las reglas del grupo cambiaron. Tirá pull-to-refresh para ver los permisos actuales."` |
| `Rules/RuleComposerCoordinator.swift:474` | `return "Agrega al menos una consecuencia."` | Validation error | `"Agrega al menos un efecto."` o `"Agrega al menos un 'qué pasa'."` (mirror RuleComposerView §QUÉ PASA convention — see open question) |
| `Rules/RuleComposerCoordinator.swift:477` | `return "El disparador elegido no aplica a este nivel (grupo / serie / instancia)."` | Validation error | `"El 'cuándo' elegido no aplica a este nivel (grupo / serie / instancia)."` |
| `Rules/RuleComposerCoordinator.swift:480` | `return "El disparador elegido no aplica a este tipo de recurso."` | Validation error after server `does not support resource_type` | `"El 'cuándo' elegido no aplica a este tipo."` (drop "de recurso") |
| `Rules/RuleComposerView.swift:116` | `progressChip(label: "Disparador", ...)` | First chip in the composer guided-progress strip | `"Cuándo"` (single-token chip; consistent with section header style) |
| `Rules/RuleComposerView.swift:118` | `progressChip(label: "Consecuencia", ...)` | Third chip in the composer guided-progress strip | `"Efecto"` o `"Qué pasa"` |
| `Rules/RuleComposerView.swift:431` | `sectionLabel("Consecuencias")` | Section header in composer body | `"EFECTOS"` o `"QUÉ PASA"` (matches `RuleDetailView.swift:124` "QUÉ HACE") |
| `Rules/RuleComposerView.swift:455` | `pickerLabel(text: "Agregar consecuencia", systemImage: "plus.circle")` | "Add another consequence" menu trigger | `"Agregar efecto"` |
| `Rules/RuleDetailView.swift:126` | `Text("Sin consecuencias configuradas.")` | Empty state inside `consequencesSection` | `"Sin efectos configurados."` |
| `Rules/RuleDetailView.swift:216` | `case .module: return rule.moduleKey.map { "Módulo · \($0)" } ?? "Módulo"` | Scope label for module-scoped rules in rule detail | `"Función · \($0)"` o just `"Función del grupo"` (sin `\($0)`, since the moduleKey is a slug `basic_fines` that bleeds tech-noun) |
| `Rules/RulesView.swift:395` | `let label = rule.moduleKey.map { "Módulo · \($0)" } ?? "Módulo"` | Scope badge in the rules list, module variant | Same as above — `"Función"` o `"Función · \(humanLabel)"` (require a `module → humanLabel` mapper before exposing the slug) |

**Soft-replacement strings already in place** (no action needed):
- `Group/Subscreens/RulePresetsView.swift:51-52` — comment notes the Beta-1 swap `"capabilities" → "funciones nuevas"`; the rendered question uses `"¿Quién puede activar funciones nuevas?"`.
- `Profile/Views/MyLedgerView.swift:51` — `.navigationTitle("Mis movimientos")`. **OK** (avoids "ledger" in copy even though file/coordinator names retain it — see Tabla 2).
- `Resources/Detail/Builders/FundBlockBuilder.swift:73` — `footerVerb: "Ver libro"`. Borderline ("libro" is close to "ledger" semantically). Founder may prefer `"Ver movimientos"` — open question.
- `Resources/ResourceWizardSheet.swift:822` — `"Crear con \(coordinator.enabledCapabilities.count) opciones · \(rules) reglas"` already renders "opciones", not "capabilities". **OK.**
- `Resources/ResourceWizardSheet.swift:914` — `changeReason: "Activado al crear el recurso (desde capacidad)"` is server-bound metadata, surfaces in history; flag for Tabla 1 if/when history copy renders it. Today it's an audit string — borderline.

---

## Tabla 2 — Indirect violations (filenames, types, deeplinks, navigation IDs)

Strings the user does not read as body copy, but that show up in any of: nav destinations, deeplink URLs, debug menus, crash reports, accessibility identifiers, or future analytics events.

| file or symbol | banned token | exposure | suggested replacement |
|---|---|---|---|
| `Features/Group/Subscreens/GovernanceView.swift` (file + `public struct GovernanceView`) | `Governance` | Renders as sheet title `"Gobierno"` (Tabla 1) + carries through nav stack | Rename type → `DecisionsEditorView` o `GroupRulesPolicyView`; file follows |
| `Features/Group/Subscreens/ModulesPickerView.swift` (file + `public struct ModulesPickerView`) | `Modules` | Renders as nav title `"Módulos"` (Tabla 1) | Rename type → `GroupFeaturesPickerView` |
| `Features/Profile/MyLedgerCoordinator.swift` (file + `@MainActor public final class MyLedgerCoordinator`) | `Ledger` | Class name; surfaces in debug, in `Logger(category: "my.ledger")` | Rename → `MyMoneyCoordinator` o `MyMovementsCoordinator` |
| `Features/Profile/Views/MyLedgerView.swift` (file + `MyLedgerView`) | `Ledger` | View struct name; the title `"Mis movimientos"` is fine, but type identity persists | Rename → `MyMovementsView` |
| `Features/Resources/Ledger/` (folder) + `ResourceLedgerCoordinator.swift` + struct | `Ledger` | Folder/class name; `Logger(category: "resource.ledger")` | Rename folder → `Money/` (already exists as a sibling for sheets!), rename class → `ResourceMoneyCoordinator` |
| `Features/Resources/Sheets/Money/AddLedgerEntrySheet.swift` + struct | `Ledger` | Sheet view struct | `AddMovementSheet` (verify the rendered title carries no banned vocab — TBD audit) |
| `Features/Resources/Sheets/Money/EventLedgerSheet.swift` + struct | `Ledger` | Sheet view struct; likely opened from event detail's money tab | `EventMovementsSheet` (verify the rendered title) |
| `Features/Resources/Detail/Blocks/CapabilityBlockView.swift` (file + `CapabilityBlockView` struct) | `Capability` | Block renderer; user reads `block.title` (set elsewhere), but the type name persists in stack traces | Rename → `FeatureBlockView` o `ActionBlockView` |
| `Features/Resources/Detail/Builders/FundBlockBuilder.swift:74` | deeplink string `"fund.ledger"` | Stored as `openDestinationId`; routed inside `ResourceDetailSheet.swift:351`. Not directly rendered but appears in analytics + URL deep-links if ever exposed | Rename to `"fund.movements"` or `"fund.history"`; update both sites + the equivalent in `LinkAdapter` if present |
| `Features/Resources/ResourceWizardSheet.swift` + struct + `Features/Resources/ResourceWizardCoordinator.swift` + struct | `Resource` as user-facing noun (per `Fase1NativeAudit.md` §6 #7) | Type name surfaces in dev/debug; legacy 5-step "Crear recurso" wizard. Title pending audit. | Beyond vocab scope — see Fase1NativeAudit §8 PR 15. Track here as cross-reference. |
| `Features/Resources/Detail/Sections/EditRightSheet.swift:62-63, 199-201` | property `targetCapability`, jsonb keys `"targetCapability"` / `"target_capability"` | Variable is bound to the `TextField` value in Tabla 1 row #93 | If we keep the field: rename the local prop to `linkedPermissionId`. The jsonb keys are server-bound — leave (see Tabla 3). |
| `Features/Onboarding/Founder/Coordinator/FounderOnboardingCoordinator.swift:132` | `"governance"` legacy step-id mapped to `.invite` | Internal routing key, not rendered. Already a forward-compat alias. | Leave as legacy alias; flag for delete-when-old-routes-drop. |
| `Features/Activity/Views/ActivityView.swift:248-265` | enum case name `case governance` (`ActivityChip`) | Type-internal; the only user-facing surface is the `label` getter (Tabla 1 row #ActivityView:262) | Rename enum case → `case decisions` (keep `rawValue` "governance" if it persists as analytics tag) |
| `Features/Resources/Detail/Builders/EventBlockBuilder.swift:204-237`, `:254-266`, `FineBlockBuilder.swift:96-117`, `VoteBlockBuilder.swift:103` | `openDestinationId` strings (`rotation.participants`, `appeal.vote`, `vote.detail`, `location.editor`, `rsvp.manager`) | Internal routing keys, no banned tokens. Listed for completeness. | OK — no action |

**Out-of-audit-surface but renders as user-facing copy** (RuulCore reaches RuulFeatures rendering):
- `Packages/RuulCore/Sources/RuulCore/Resources/Intents/ResourceIntent.swift:153` — `case .governance: return "GOBIERNO"` (section header in resource overflow menu).
- `Packages/RuulCore/Sources/RuulCore/Resources/Intents/DefaultIntents.swift:247-253` — intent `change_control` copy: `"Cambiar reglas del grupo"`, body `"Vas a entrar al editor de gobernanza. Los cambios pueden necesitar aprobación del grupo."`.
- `Packages/RuulCore/Sources/RuulCore/PlatformModels/Permission+Display.swift:9` — `"Cambiar gobierno"` (permission label in member roles picker).
- `Packages/RuulCore/Sources/RuulCore/PlatformModels/Permission+Display.swift:21` — `"Activar módulos"` (permission label).
- `Packages/RuulCore/Sources/RuulCore/PlatformModels/Permission+Display.swift:48` — hint `"Editar quién decide qué."` (OK — no banned word, listed for context).
- `Packages/RuulCore/Sources/RuulCore/PlatformModels/Permission+Display.swift:60` — `"Activar o desactivar módulos del grupo (multas, votos, cupos…)."`.
- `Packages/RuulCore/Sources/RuulCore/PlatformModels/Permission+Display.swift:111` — category title `"Gobierno y miembros"` (renders as section header in role editor).
- `Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEventType+Extensions.swift:110` — `"Gobernanza actualizada"` (system-event human label, used in `Activity/Views/HistoryItemPresentation.swift`).

These flow into Tabla 1 surfaces (Activity feed, MemberRolesPicker, RoleEditor, resource detail overflow menu). Per user scope they sit in RuulCore. **Open question: include in the same renaming sweep or split as a follow-up "RuulCore copy audit"?** Recommendation: include — the strings render in user surfaces, and the scope boundary is incidental to the doctrine.

---

## Tabla 3 — Safe usage (banned word OK because internal)

Each row is an instance of a banned word inside the audit surface that does **not** become user-facing copy. Listed so the eventual sweep PR knows what to skip.

### A. Log subsystem categories
- `GovernanceView.swift:32` — `Logger(category: "groups.governance")`
- `RulesCoordinator.swift:85` — `log.warning("governance check failed: ...")`
- `MyLedgerCoordinator.swift:42` — `Logger(category: "my.ledger")`
- `MyLedgerCoordinator.swift:83` — `log.warning("ledger refresh failed for ...")`
- `ResourceLedgerCoordinator.swift:114` — `Logger(category: "resource.ledger")`

### B. jsonb / metadata keys parsed from server payloads
- `Resources/Detail/Sections/EditRightSheet.swift:62-63, 199-201` — `metadata["targetCapability"]`, `metadata["target_capability"]`
- `Resources/Detail/Sections/RotationParticipantsSheet.swift:264` — `root["capability_configs"]`
- `Resources/Detail/Builders/EventDetailSnapshot.swift:42` — `root["capability_configs"]`
- `Activity/Views/HistoryItemPresentation.swift:109-117` — `event.payload["vote_type"]` matched against `"ledger_review"`

### C. Server error parsing (string-match against raw error text, then translated to user copy)
- `Rules/ResourceRulesCoordinator.swift:334, 337` — `raw.contains("governance requires vote")`, `raw.contains("governance denied")` (input only; user copy is built downstream)
- `Rules/RuleComposerCoordinator.swift:473` — `raw.contains("at least one consequence")` (input only; output is `"Agrega al menos una consecuencia."` — see Tabla 1)
- `Rules/RuleComposerCoordinator.swift:479` — `raw.contains("does not support resource_type")` (input only)
- `Resources/Ledger/ResourceLedgerCoordinator.swift:357` — `raw.contains("invalid ledger entry type")` → user copy `"Tipo de movimiento no soportado."` (output is clean)

### D. Code comments referencing the doctrine vocabulary
- `Group/Subscreens/RulePresetsView.swift:51` — "Beta 1 W2-C1: 'capabilities' → 'funciones nuevas'."
- `Resources/Create/Steps/ResourceTypePicker.swift:13` — "no doctrine vocabulary ('capability', 'atom', 'module') appears in copy"
- `Resources/Detail/Sections/RotationParticipantsSheet.swift:24` — "Founder voice: no 'capability', no 'atom', no 'rotation engine'."
- `Resources/Detail/Builders/EventDetailSnapshot.swift` (general doc strings)
- `Profile/Views/MyProfileView.swift:386` — "Demote ResourceWizardSheet to Governance → Advanced" (internal navigation note; rendered nav row is `"Mis movimientos"` so OK)
- `Group/Views/GroupHomeView.swift:18, 277-282` — internal doc comments listing the section structure ("ACUERDOS Y GOBERNANZA (módulos + reglas vigentes + gobernanza + estilo)")
- `Resources/Detail/Blocks/CapabilityBlockView.swift:5-8` — internal doc on "Renders ONE CapabilityBlock by switching on its layoutKind..."

### E. Public Swift identifiers (types, properties, methods) never rendered
- `RuulCore` re-exports: `GovernanceRules`, `GovernanceAction`, `GovernanceService`, `RuleGovernanceCoordinator`, `Permission.modifyGovernance`, `Group.effectiveGovernance`, `whoCanModifyGovernance`
- `RuulFeatures`: `coordinator.enabledCapabilities`, `coordinator.selectedCapabilityUniversalPublishes`, `availableTriggers`, `availableConsequences`, `availableConditions`, `RuleShape`, `triggerSection`, `consequenceSection`, `consequenceTargetPicker`
- `Tandas/TandasApp.swift:47-85, 126-164` — `MockResourceCapabilityRepository`, `LiveResourceCapabilityRepository`, `MockLedgerRepository`, `LiveLedgerRepository`, `resourceCapabilityRepo`, `ledgerRepo`
- `RuulCore`: `ModuleRegistry`, `setModule`, `GroupModule`

These are internal Swift symbols. Renaming is optional doctrine-hygiene; not blocking.

### F. Dev-only / showcase
- `Tandas/DesignSystem/Showcase/Sections/PrimitivesShowcaseView.swift:81` — `RuulButton("Trigger error", ...)` inside design-system showcase (not shipped to end users; dev-only sandbox)
- `Tandas/DesignSystem/Showcase/Sections/TokensShowcaseView.swift:214` — `RuulButton("Trigger", ...)` in haptic-trigger demo
- `Packages/RuulUI/Sources/RuulUI/Primitives/RuulOTPInput.swift:142` — preview-only `RuulButton("Trigger error", ...)` (inside `#Preview`)

### G. Routing / template kind strings (internal, never rendered)
- `RuulCore/Templates/RuleTemplateCatalog.swift:131-373` — `templateKind: "governance"` on 12 rule templates (server taxonomy)
- `RuulCore/PlatformModels/Generated/SystemEventType+Codable.swift:154, 260, 358` — encoder/decoder strings for `governanceUpdated` enum case (codable contract)
- `RuulCore/PlatformModels/Generated/Permission+Codable.swift:37, 77, 109` — `"modifyGovernance"` codable string
- `FounderOnboardingCoordinator.swift:132` — `"governance"` legacy step-id alias
- `Resources/Detail/Builders/FundBlockBuilder.swift:74` — `openDestinationId: "fund.ledger"` (also flagged in Tabla 2 for analytics-visibility — rename even though not directly rendered)

### H. RuulUI internal comments
- `Packages/RuulUI/Sources/RuulUI/Resources/ResourceAction.swift:20` — internal doc string `'La gobernanza cambió, refrescá'` referring to a hypothetical fallback message (not currently rendered).

---

## Glosario consolidado: banned → allowed (Ruul context)

Each banned word maps to 2–3 contextual replacements. Use the example column when picking the right one — context matters more than the word itself.

| Banned (EN / ES) | Allowed | When to use | Codebase example |
|---|---|---|---|
| **capability / capacidad** | `función` | The thing a member or resource can do (`basic_fines`, `voting`, etc.) | "Función no soportada: \(id)" replaces ResourceWizardCoordinator:667 |
| | `opción` | When listing config options the user picks during creation | Already in `ResourceWizardSheet:822` — "Crear con N opciones · M reglas" |
| | `permiso` | When the capability is gated to a specific member (role-bound) | "Permiso vinculado (opcional)" replaces EditRightSheet:93 |
| **module / módulo** | `función` | Same surface as capability — V1 funders shouldn't see two abstractions | "Funciones activas" replaces GroupHomeView:287 |
| | `función del grupo` | When disambiguating from a member capability | "Activar o desactivar funciones del grupo" replaces Permission+Display:60 (RuulCore) |
| | (inline) | Often the cleanest fix is to inline the concrete feature name | "Heredada" or "Heredada del grupo" replaces EventRulesSheet:256 "Heredada · módulo" |
| **governance / gobierno / gobernanza** | `decisiones` | Whole concept of "how the group decides" | "Decisiones del grupo" replaces GovernanceView:53 "Gobierno"; "Decisiones" replaces GroupHomeView:300 nav-row |
| | `acuerdos` | When the user thinks of it as "what the group has agreed to" | "ACUERDOS Y DECISIONES" replaces GroupHomeView:284 "ACUERDOS Y GOBERNANZA" |
| | `reglas` | When the action is changing the rules (modifyGovernance) | "Cambiar las reglas del grupo" replaces Permission+Display:9 "Cambiar gobierno"; "\(actor) cambió las reglas" replaces HistoryItemPresentation:206 |
| | (drop) | When the banned word is purely decorative | EditRulesCoordinator:282 "La gobernanza del grupo cambió." → "Las reglas del grupo cambiaron." |
| **ledger** | `movimientos` | Default for the money log surface | Already used in MyLedgerView title; rename folder/class to match |
| | `historial de dinero` | When the parent surface is broader than money (e.g., a tab) | Tab in Resource detail (per doctrine "Money / Activity" split) |
| | `libro` | Borderline (close to "ledger" semantically) — currently in `"Ver libro"` footer | Founder may prefer `"Ver movimientos"` — open question |
| **trigger / disparador** | `cuándo` | First piece of a WHEN/IF/THEN rule — single-token | "Cuándo" replaces RuleComposerView:116 progress chip "Disparador" |
| | `condición de inicio` | When the user is reading prose copy and "cuándo" feels too terse | "El 'cuándo' elegido no aplica a este nivel..." replaces RuleComposerCoordinator:477 — quoted form keeps it tactile |
| **consequence / consecuencia** | `efecto` | Default — short, neutral, no value judgment | "Efecto" replaces RuleComposerView:118 progress chip |
| | `qué pasa` | When prose copy needs to feel concrete and active | "Qué pasa" replaces RuleComposerView:431 section header "Consecuencias" (matches RuleDetailView:124 "QUÉ HACE" pattern) |
| **resource_type / tipo de recurso** | `tipo` | When the context already implies "of resource" (after a humanLabel) | "Este tipo aún no está disponible." replaces ResourceWizardCoordinator:170 |
| | `clase de cosa` | When the user has no antecedent in the sentence | Avoid — almost always you can drop "de recurso" entirely |
| **rule shape** | (no user-facing hits) | Internal — keep as `RuleShape` Swift type | If a label ever surfaces: `tipo de regla` or `plantilla de regla` |
| **atom / átomo** | (no user-facing hits) | Internal architectural term | Reserve `pieza` / `bloque` if ever surfaced |
| **projection / proyección** | (no user-facing hits) | Internal architectural term | Reserve `vista` / `resumen` / `panel` if ever surfaced |
| **governance hierarchy** | (no user-facing hits) | Doctrine ban applies to the compound | Reserve `escala de decisiones` if ever needed |

---

## Open questions (founder review)

1. **GovernanceView sheet title** — `"Decisiones del grupo"` vs `"Acuerdos del grupo"` vs `"Reglas del grupo"`. The first reads cleanest, but "Reglas" already names a sibling tab — collision risk.
2. **"Estilo de gobernanza"** (`GroupHomeView:302`) — rename to `"Estilo de decisiones"`, `"Política del grupo"`, `"Preset del grupo"`, or just `"Estilo"`? Today this nav-row opens `RulePresetsView` which itself titles "Cómo decide este grupo" — the nav-row label should hint at the same destination.
3. **`"Disparador"` / `"Consecuencia"` in RuleComposerView** — the audit's glossary recommends `"Cuándo"` / `"Efecto"` but the founder voice may prefer keeping `"Disparador"` if testing shows users understand it. Confirm before sweep.
4. **`"Capability gobernada (opcional)"` field** (`EditRightSheet:93`) — is this exposed to end-users at all? If V1 admins only, the cleanest fix is to **delete the field** rather than rename. If it surfaces, propose `"Permiso vinculado (opcional)"`.
5. **`"Ver libro"`** (`FundBlockBuilder:73`) — keep "libro" or move to `"Ver movimientos"`? "Libro" reads as Spanish vernacular but echoes "ledger".
6. **`"Activar módulos"` permission label** (RuulCore Permission+Display:21) — replace with `"Activar funciones"` or drop the permission from the role-editor surface entirely (still grant in code, just don't expose as a tickable checkbox)?
7. **"Heredada · módulo"** badge — collapse to `"Heredada"` (loses scope-specificity but cleaner) or relabel `"Heredada · función"`? The user has to scan a list of badges; ambiguity here may hurt orientation.
8. **`"fund.ledger"` deeplink** — rename to `"fund.movements"` or `"fund.history"`? If we ever expose share URLs / analytics events with these IDs, the string is user-visible-adjacent.
9. **RuulCore strings** (Permission+Display, ResourceIntent, DefaultIntents, SystemEventType+Extensions) — same sweep PR or a separate follow-up audit? They sit outside the scoped surface but render as user-facing copy via RuulFeatures.
10. **`changeReason: "Activado al crear el recurso (desde capacidad)"`** (`ResourceWizardSheet:914`) — server-bound audit string. If/when surfaced in history feeds (currently it's stored on `rule_versions.change_reason`), it becomes user-facing.

---

## DoD self-check

- ✅ Tabla 1 with every confirmed user-facing match in the audit surface (~33 rows).
- ✅ Tabla 2 enumerates filenames/types/deeplinks that carry banned vocab in identifier form.
- ✅ Tabla 3 enumerates safe internal uses (logs, jsonb keys, error-parse inputs, comments, Swift symbols, dev showcase, codable contracts).
- ✅ Glosario maps each banned word to 2-3 context-specific replacements with codebase example.
- ✅ Open questions flagged where founder judgment is required.
- ✅ Out-of-audit-scope RuulCore strings noted because they render via in-scope features.
