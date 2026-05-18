import Foundation
import OSLog
import RuulCore

/// Universal ResourceWizard coordinator. Drives the multi-step flow:
///
///   1. typePicker — choose what to create (Event, Asset, Fund, …)
///   2. fields     — fill the builder's requiredFields
///   3. options    — toggle capability blocks (filtered by resource type)
///   4. rules      — pick suggested rules grouped by enabled capability
///   5. review     — read-only summary before commit
///
/// Founder framing 2026-05-10: resources are created from composable
/// capabilities + rules, not hardcoded vertical flows. The step order
/// mirrors the user's mental model — "what is this? / fill details /
/// add options / set agreements / confirm".
///
/// Persists step state so back/forward navigation feels natural.
public enum ResourceWizardStep: Int, Sendable, CaseIterable {
    case typePicker
    case fields
    case options
    case rules
    case review
}

@Observable @MainActor
public final class ResourceWizardCoordinator {
    public let group: Group
    public let registry: ResourceBuilderRegistry
    public let catalog: CapabilityCatalog
    /// Capability auto-on defaults per resource type, sourced from the
    /// group's template (`templates.config.defaultCapabilities`). Empty
    /// dict means "no auto-on" — the wizard opens with nothing toggled.
    /// Founder framing 2026-05-11: this map is THE source of truth for
    /// pre-toggling caps; the coordinator never hardcodes per
    /// resource_type.
    public let defaultCapabilitiesByType: [String: [String]]

    public private(set) var step: ResourceWizardStep = .typePicker
    public private(set) var selectedBuilder: (any ResourceBuilder)?
    public var basicFields: [String: JSONConfig] = [:]
    public var enabledCapabilities: Set<String> = []
    /// Suggested rules the user has toggled ON in step 4. Keyed by the
    /// composite "blockId.slug" so the same rule slug declared by two
    /// different capabilities can coexist independently.
    public var selectedSuggestedRules: Set<String> = []

    /// Universal Rule Templates (`public.rule_templates`, Beta-1 catalog)
    /// shown ABOVE the legacy capability-suggested rules in step 4.
    /// Filtered at coordinator construction by `triggerShape.validResourceTypes
    /// contains selectedBuilder.resourceType`. Empty when the caller
    /// didn't pass `app.ruleTemplatesForGallery` or when none are
    /// compatible with the chosen resource type.
    /// Per UniversalRuleTemplates.md §14 Fase 2 — bridges the wizard
    /// surface to the universal catalog without rewiring the legacy
    /// `createInitialRules` pipeline yet.
    public let universalTemplates: [RuleBuilderTemplate]

    /// User's universal-template picks. The sheet publishes each one
    /// scoped to the freshly-created resource AFTER the resource itself
    /// lands (via `ruleTemplateRepo.publishRuleVersion`). Failures are
    /// surfaced as warnings — the resource is still created.
    public var selectedUniversalTemplateIds: Set<String> = []
    /// Per-capability config values, keyed by `block.id` then field key.
    /// Recurrence's frequency / dayOfWeek / time / etc. live here.
    /// Replaces the four dedicated recurrence* properties this struct
    /// used to carry. Founder framing 2026-05-11: capability sub-config
    /// is declarative — the renderer writes here via BuilderFieldRenderer.
    public var capabilityConfigs: [String: [String: JSONConfig]] = [:]

    public private(set) var isCreating: Bool = false
    public private(set) var error: String?
    public private(set) var createdResourceId: UUID?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.wizard")
    private let resolver: CapabilityResolver

    public init(
        group: Group,
        registry: ResourceBuilderRegistry,
        catalog: CapabilityCatalog = .v1,
        resolver: CapabilityResolver = CapabilityResolver(),
        defaultCapabilitiesByType: [String: [String]] = [:],
        universalTemplates: [RuleBuilderTemplate] = []
    ) {
        self.group = group
        self.registry = registry
        self.catalog = catalog
        self.resolver = resolver
        self.defaultCapabilitiesByType = defaultCapabilitiesByType
        self.universalTemplates = universalTemplates
    }

    /// Universal templates whose trigger shape supports the currently
    /// selected builder's resource type. Falls back to all universals
    /// when no resource type is set (typePicker step).
    public func compatibleUniversalTemplates(shapeRegistry: RuleShapeRegistry) -> [RuleBuilderTemplate] {
        guard let resourceType = selectedBuilder?.resourceType.rawString else {
            return universalTemplates
        }
        return universalTemplates.filter { template in
            guard let shape = shapeRegistry.shape(id: template.composition.triggerShapeId) else {
                return false
            }
            if shape.validResourceTypes.isEmpty { return true }
            return shape.validResourceTypes.contains(resourceType)
        }
    }

    public func isUniversalSelected(_ id: String) -> Bool {
        selectedUniversalTemplateIds.contains(id)
    }

    public func toggleUniversal(_ id: String) {
        if selectedUniversalTemplateIds.contains(id) {
            selectedUniversalTemplateIds.remove(id)
        } else {
            selectedUniversalTemplateIds.insert(id)
        }
    }

    // MARK: - Step navigation

    public func selectBuilder(_ builder: any ResourceBuilder) {
        selectedBuilder = builder
        basicFields = [:]
        // Pre-fill defaults for non-text fields so validateRequiredFields
        // passes immediately. Without this, the date binding in
        // BuilderFieldRenderer only fires its `set` on user interaction —
        // so a user who just types a title (without tapping the date
        // picker) hits a silently-disabled CTA.
        let iso = ISO8601DateFormatter()
        let defaultDate = Date.now.addingTimeInterval(86_400)
        for field in builder.requiredFields {
            switch field.kind {
            case .date, .time, .dateTime, .duration:
                basicFields[field.key] = .string(iso.string(from: defaultDate))
            case .boolean:
                basicFields[field.key] = .bool(false)
            case .integer, .decimal, .currency, .money:
                basicFields[field.key] = .int(0)
            default:
                break  // text/picker/resource — wait for user input
            }
        }
        enabledCapabilities = defaultCapabilitiesFor(builder)
        // Pre-select every suggested rule from the auto-enabled
        // capabilities so step 4 opens with sensible defaults — the user
        // sees "RSVP closes 24h before" already ticked, can toggle off if
        // they don't want it.
        selectedSuggestedRules = defaultSelectedRules()
        step = .fields
    }

    /// Select a resource type by value. Looks up the registered builder for
    /// the type and forwards to `selectBuilder`. When no builder exists yet
    /// (e.g. `.space`, `.right` in Pass 2), sets `error` so the caller can
    /// surface a friendly message rather than silently doing nothing.
    ///
    /// Callers that already hold a builder reference should prefer
    /// `selectBuilder(_:)` directly to avoid the redundant registry lookup.
    public func selectType(_ type: ResourceType) {
        if let builder = registry.builder(for: type) {
            selectBuilder(builder)
        } else {
            // Builder not yet registered — type is "Próximamente". The
            // TypePicker normally prevents tapping these tiles (disabled),
            // but guard here as a safety net.
            error = "Este tipo de recurso aún no está disponible."
        }
    }

    public func goBack() {
        switch step {
        case .typePicker: return
        case .fields:     step = .typePicker; selectedBuilder = nil
        case .options:    step = .fields
        case .rules:      step = .options
        case .review:     step = hasAnyRulesStepContent ? .rules : .options
        }
    }

    public func advanceFromFields() {
        guard validateRequiredFields() else { return }
        step = .options
    }

    public func advanceFromOptions() {
        // Skip step 4 only when neither legacy capability rules NOR
        // universal templates apply — otherwise the user needs to see
        // the universals section before reviewing.
        step = hasAnyRulesStepContent ? .rules : .review
    }

    public func advanceFromRules() {
        step = .review
    }

    public var canAdvanceFromFields: Bool {
        validateRequiredFields()
    }

    /// Capability blocks the picker should show in step 3 — filtered by:
    /// (1) the selected builder declares them, AND
    /// (2) the resolver says they're available on this group, AND
    /// (3) Tier 0 truth gate (2026-05-12): `block.status` is `.stable`.
    ///     Incomplete blocks are hidden until UI config + backend save +
    ///     runtime support are all real. Founder framing: "no toggles
    ///     decorativos." See CapabilityStatus on each block for reason.
    public var availableCapabilityBlocks: [any CapabilityBlock] {
        guard let builder = selectedBuilder else { return [] }
        let groupAvailable = Set(resolver.availableCapabilities(
            for: builder.resourceType, in: group, catalog: catalog
        ))
        return builder.optionalCapabilities
            .filter { groupAvailable.contains($0) }
            .compactMap { catalog[$0] }
            .filter { $0.status.isStable }
    }

    public func toggleCapability(_ blockId: String) {
        if enabledCapabilities.contains(blockId) {
            enabledCapabilities.remove(blockId)
            // Drop dependents whose deps just disappeared.
            for block in availableCapabilityBlocks where enabledCapabilities.contains(block.id) {
                if block.dependencies.contains(blockId) {
                    enabledCapabilities.remove(block.id)
                }
            }
            // Drop the just-disabled block's suggested rule picks so
            // they don't haunt the review/submit if the user re-enables
            // a different capability with the same slug.
            if let block = availableCapabilityBlocks.first(where: { $0.id == blockId }) {
                for template in block.suggestedRules {
                    selectedSuggestedRules.remove(
                        suggestedRuleKey(blockId: blockId, slug: template.slug)
                    )
                }
            }
        } else {
            enabledCapabilities.insert(blockId)
            // Pull in transitive deps.
            if let block = availableCapabilityBlocks.first(where: { $0.id == blockId }) {
                for dep in block.dependencies {
                    enabledCapabilities.insert(dep)
                }
                // Pre-select this block's suggested rules — but only
                // the ones flagged `defaultEnabled` (reminders,
                // approvals, social norms). Monetary fines stay OFF
                // until the user opts in on step 4.
                for template in block.suggestedRules where template.defaultEnabled {
                    selectedSuggestedRules.insert(
                        suggestedRuleKey(blockId: blockId, slug: template.slug)
                    )
                }
                // Seed sub-config defaults for this block's required
                // fields so step 3 renders sensible initial values
                // (e.g. recurrence opens with weekly / Thursday / 20:00).
                seedCapabilityConfigDefaults(for: block)
            }
        }
    }

    public func isCapabilityEnabled(_ blockId: String) -> Bool {
        enabledCapabilities.contains(blockId)
    }

    // MARK: - Suggested rules (Step 4)

    /// Suggested rules from every enabled capability. Used by step 4 to
    /// render the toggle list and by submit to materialize the user's
    /// picks into `OnboardingRuleDraft` rows.
    public var availableSuggestedRules: [(block: any CapabilityBlock, template: CapabilityRuleOption)] {
        availableCapabilityBlocks
            .filter { enabledCapabilities.contains($0.id) }
            .flatMap { block in
                block.suggestedRules.map { (block: block, template: $0) }
            }
    }

    public var hasAnySuggestedRules: Bool {
        !availableSuggestedRules.isEmpty
    }

    /// True iff step 4 has content to show — either legacy
    /// capability-suggested rules OR universal templates compatible
    /// with the current resource type. Used to gate the skip behavior
    /// (`advanceFromOptions` / `goBack`) so universals alone keep the
    /// step visible. When `universalTemplates` is non-empty we keep the
    /// step regardless of resource-type compatibility — the universal
    /// section's own render-time filter handles the "no compatible"
    /// case by collapsing to nothing.
    public var hasAnyRulesStepContent: Bool {
        hasAnySuggestedRules || !universalTemplates.isEmpty
    }

    public func suggestedRuleKey(blockId: String, slug: String) -> String {
        "\(blockId).\(slug)"
    }

    public func isSuggestedRuleSelected(blockId: String, slug: String) -> Bool {
        selectedSuggestedRules.contains(suggestedRuleKey(blockId: blockId, slug: slug))
    }

    public func toggleSuggestedRule(blockId: String, slug: String) {
        let key = suggestedRuleKey(blockId: blockId, slug: slug)
        if selectedSuggestedRules.contains(key) {
            selectedSuggestedRules.remove(key)
        } else {
            selectedSuggestedRules.insert(key)
        }
    }

    /// Selected capability options that map to a universal template.
    /// Returns `(universalTemplateId, defaultConfig)` so the sheet can
    /// publish each via `publishRuleVersion` with per-option params
    /// merged on top of the universal's catalog defaults.
    /// Per UniversalRuleTemplates.md §14 Fase 2 pipeline unification.
    public var selectedCapabilityUniversalPublishes: [(universalTemplateId: String, defaultConfig: [String: String])] {
        availableSuggestedRules.compactMap { pair in
            guard isSuggestedRuleSelected(blockId: pair.block.id, slug: pair.template.slug),
                  let uid = pair.template.universalTemplateId
            else { return nil }
            return (uid, pair.template.defaultConfig)
        }
    }

    // MARK: - Submit

    public var canSubmit: Bool {
        selectedBuilder != nil && validateRequiredFields() && !isCreating
    }

    public func submit() async -> Bool {
        guard let builder = selectedBuilder, canSubmit else { return false }
        isCreating = true
        error = nil
        defer { isCreating = false }

        // Build seriesPattern from the recurrence capability's
        // declarative config. Tier 1.2 (2026-05-12): emits the full
        // pattern shape `_shared/recurrence.ts` validates against
        // (frequency, dayOfWeek, hour, minute, startDate, endCondition,
        // count|untilDate, timezone). Each field's presence depends on
        // what the user filled — count and untilDate are conditional
        // via BuilderField.dependsOn, so we only emit the one matching
        // the chosen endCondition.
        let seriesPattern: JSONConfig? = {
            guard enabledCapabilities.contains("recurrence"),
                  let cfg = capabilityConfigs["recurrence"] else { return nil }
            var pattern: [String: JSONConfig] = [:]
            if case let .string(f) = cfg["frequency"] { pattern["frequency"] = .string(f) }
            if case let .int(d)    = cfg["dayOfWeek"] { pattern["dayOfWeek"] = .int(d) }
            // Time field renders as `.time` and carries an ISO datetime;
            // extract hour+minute for the recurrence pattern shape.
            if case let .string(raw) = cfg["time"],
               let date = BuilderFieldRenderer.parseDateString(raw) {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                pattern["hour"]   = .int(comps.hour ?? 20)
                pattern["minute"] = .int(comps.minute ?? 0)
            }
            // startDate is `.date` kind → already YYYY-MM-DD via the
            // renderer's formatDate. Emit as-is.
            if case let .string(s) = cfg["startDate"] { pattern["startDate"] = .string(s) }
            if case let .string(ec) = cfg["endCondition"] {
                pattern["endCondition"] = .string(ec)
                switch ec {
                case "after_count":
                    if case let .int(c) = cfg["count"] { pattern["count"] = .int(c) }
                case "until_date":
                    if case let .string(ud) = cfg["untilDate"] { pattern["untilDate"] = .string(ud) }
                default: break  // 'never' needs neither
                }
            }
            if case let .string(tz) = cfg["timezone"] { pattern["timezone"] = .string(tz) }
            return .object(pattern)
        }()

        // Materialize selected suggested rules into OnboardingRuleDraft rows
        // so the builder can hand them to the rule repo at create time. The
        // template's `defaultConfig` flows into the trigger's config jsonb
        // so server-side evaluators see the right thresholds.
        //
        // SKIP options that map to a universal — those publish via
        // ResourceWizardSheet.publishSelectedCapabilityUniversals after
        // resource creation (canonical publishRuleVersion path).
        // UniversalRuleTemplates.md §14 Fase 2 pipeline unification.
        let initialRules: [OnboardingRuleDraft] = availableSuggestedRules.compactMap { pair in
            guard isSuggestedRuleSelected(blockId: pair.block.id, slug: pair.template.slug) else {
                return nil
            }
            // Universal-mapped options are published post-create via the
            // canonical pipeline. Don't double-write them through legacy.
            if pair.template.universalTemplateId != nil { return nil }
            return OnboardingRuleDraft(
                slug: pair.template.slug,
                name: pair.template.displayName,
                description: pair.template.summary,
                isActive: true,
                trigger: defaultTrigger(for: pair.template),
                conditions: [RuleCondition(type: .alwaysTrue, config: .object([:]))],
                consequences: defaultConsequences(for: pair.template)
            )
        }

        // Flatten the per-block config map into a single
        // [String: JSONConfig] keyed by `blockId` — each value is the
        // block's `.object(fieldKey: …)` payload. The draft schema
        // accepts arbitrary jsonb here so the server can use as much
        // detail as it wants per capability.
        let flatCapabilityConfigs: [String: JSONConfig] = capabilityConfigs
            .compactMapValues { dict in dict.isEmpty ? nil : JSONConfig.object(dict) }

        let draft = ResourceDraft(
            groupId: group.id,
            resourceType: builder.resourceType,
            basicFields: basicFields,
            enabledCapabilities: Array(enabledCapabilities),
            capabilityConfigs: flatCapabilityConfigs,
            seriesPattern: seriesPattern,
            initialRules: initialRules
        )

        do {
            let result = try await builder.build(draft)
            createdResourceId = result.resourceId
            log.debug("created \(builder.displayName) \(result.resourceId)")
            return true
        } catch let e as ResourceBuilderError {
            self.error = userFacing(error: e)
            return false
        } catch {
            // W2-C2: pass through RuulErrorTranslator so PostgREST /
            // network / auth errors land as friendly Spanish copy
            // instead of leaking the raw English message.
            self.error = "No pudimos crear el recurso. \(error.ruulUserMessage)"
            // Beta 1 W4 F-4.5 TODO: emit `error_shown` here once this
            // coordinator gains an injected AnalyticsService. The first
            // three high-traffic error paths (auth OTP send, Apple sign-in,
            // group settings save) already emit via BetaAnalytics; this
            // path covers ResourceWizard submit failures.
            return false
        }
    }

    // MARK: - Helpers

    /// True iff every required field across (a) the builder's own
    /// basicFields and (b) each currently-enabled capability's
    /// `requiredFields` (filtered by `dependsOn`) has a non-empty value
    /// in the appropriate config blob.
    ///
    /// Tier 0 (2026-05-12): active capability requires its required
    /// fields filled. Tier 1.1: `dependsOn` lets a field declare itself
    /// conditional ("count required when endCondition=after_count").
    /// The validator skips a conditional field whose dependency value
    /// doesn't match — that field isn't relevant to this submission.
    private func validateRequiredFields() -> Bool {
        guard let builder = selectedBuilder else { return false }
        // (a) Builder's own fields (title, startsAt, …). Builder fields
        //     don't use dependsOn today, but the helper handles it.
        //     Slice 15: skip fields flagged isOptional — they render
        //     but don't block the CTA (e.g. RightResourceBuilder's
        //     holderMemberId / transferable / delegable). Server-side
        //     defaults take over when the user leaves them empty.
        for field in builder.requiredFields
            where !field.isOptional && isFieldActive(field, in: basicFields) {
            if !isFieldFilled(field, in: basicFields) { return false }
        }
        // (b) Required fields of every active capability.
        for blockId in enabledCapabilities {
            guard let block = catalog[blockId] else { continue }
            let configForBlock = capabilityConfigs[blockId] ?? [:]
            for field in block.requiredFields
                where !field.isOptional && isFieldActive(field, in: configForBlock) {
                if !isFieldFilled(field, in: configForBlock) { return false }
            }
        }
        return true
    }

    /// Whether `field` should be considered required given its
    /// `dependsOn` predicate against `values`. Returns true when no
    /// dependency is declared, or when the dependent key holds the
    /// expected value. Founder framing 2026-05-12 Tier 1.1.
    private func isFieldActive(_ field: BuilderField, in values: [String: JSONConfig]) -> Bool {
        guard let dep = field.dependsOn else { return true }
        return values[dep.key] == dep.equalsValue
    }

    /// Whether `field` has a non-empty value in `values`. Strings are
    /// trimmed; non-string types (int/bool/double/object/array) count as
    /// present once the key exists. `.null` is treated as empty so an
    /// explicit null doesn't slip through as "filled."
    private func isFieldFilled(_ field: BuilderField, in values: [String: JSONConfig]) -> Bool {
        guard let value = values[field.key] else { return false }
        switch value {
        case .string(let s):
            return !s.trimmingCharacters(in: .whitespaces).isEmpty
        case .null:
            return false
        case .int, .double, .bool, .object, .array:
            return true
        }
    }

    private func defaultCapabilitiesFor(_ builder: any ResourceBuilder) -> Set<String> {
        // Founder framing 2026-05-11: capability auto-on defaults come
        // from the group's template/preset, NEVER from a hardcoded
        // per-resource_type rule. The wizard sheet looks up
        // `template.config.defaultCapabilities` and passes the resolved
        // map here on init. Templates that don't declare any default
        // (custom / placeholder) result in an empty set — user opts in
        // to every cap explicitly.
        //
        // Defensive: intersect with the group's actually-available
        // capability list so a template that suggests `rsvp` for a
        // group that doesn't have the rsvp module activated won't
        // pre-toggle a hidden cap.
        let suggested = Set(defaultCapabilitiesByType[builder.resourceType.rawString] ?? [])
        // (resourceType.rawString matches the templates jsonb key — e.g.
        // "event" → ["rsvp", "check_in", "rotation"].)
        guard !suggested.isEmpty else { return [] }
        let available = Set(resolver.availableCapabilities(
            for: builder.resourceType, in: group, catalog: catalog
        ))
        // Tier 0 truth gate (2026-05-12): never auto-enable an incomplete
        // capability via a template default. A template that pre-toggles
        // `rotation` for "recurring_dinner" used to silently activate an
        // unbuilt rotation cap row; the filter below makes the template
        // honest too. If a template wants behavior, the underlying cap
        // has to be `.stable`.
        let stable = Set(suggested.compactMap { id -> String? in
            guard let block = catalog[id] else { return nil }
            return block.status.isStable ? id : nil
        })
        return stable.intersection(available)
    }

    /// Seeds defaults for a block's required + optional fields when the
    /// block is enabled. Picker fields default to their first option;
    /// time fields default to a sensible weekly cadence (Thursday 20:00
    /// for events). Idempotent — won't overwrite values the user
    /// already touched.
    private func seedCapabilityConfigDefaults(for block: any CapabilityBlock) {
        var current = capabilityConfigs[block.id] ?? [:]
        for field in block.requiredFields {
            if current[field.key] != nil { continue }
            switch field.kind {
            case .picker, .multiPicker:
                if let first = field.options?.first {
                    current[field.key] = first.value
                }
            case .time:
                // 20:00 today as ISO timestamp — extract hour/minute at submit.
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                comps.hour = 20
                comps.minute = 0
                if let date = Calendar.current.date(from: comps) {
                    current[field.key] = .string(ISO8601DateFormatter().string(from: date))
                }
            case .date, .dateTime:
                // Use BuilderFieldRenderer.formatDate so the seed shape
                // matches what the renderer will write on user change.
                // For `.date`: YYYY-MM-DD; for `.dateTime`: full ISO8601.
                let date = Date.now.addingTimeInterval(86_400)
                current[field.key] = .string(BuilderFieldRenderer.formatDate(date, kind: field.kind))
            case .boolean:
                current[field.key] = .bool(false)
            case .integer, .decimal, .currency, .money:
                current[field.key] = .int(0)
            default:
                break  // text-shaped → wait for user input
            }
        }
        // Special-case: pre-pick Thursday for recurrence's dayOfWeek
        // so cenas opens with the dinner default founders expect. Any
        // group that wants a different default would re-pick — the
        // user's choice persists.
        if block.id == "recurrence", current["dayOfWeek"] == nil {
            current["dayOfWeek"] = .int(4)
        }
        // Tier 1.1 (2026-05-12) — recurrence pattern defaults:
        //   - startDate = first occurrence on/after tomorrow.
        //   - endCondition default 'never' (so wizard opens valid).
        //   - timezone = current TimeZone identifier (informative).
        // These run after the generic loop because they reference
        // each other (endCondition='never' implies count/untilDate
        // skipped) and need cap-specific knowledge.
        if block.id == "recurrence" {
            if current["startDate"] == nil {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withFullDate]
                current["startDate"] = .string(iso.string(from: tomorrow))
            }
            if current["endCondition"] == nil {
                current["endCondition"] = .string("never")
            }
            if current["timezone"] == nil {
                current["timezone"] = .string(TimeZone.current.identifier)
            }
        }
        capabilityConfigs[block.id] = current
    }

    /// Pre-selected suggested rules at builder-pick time. Honors every
    /// auto-enabled capability AND each template's `defaultEnabled`
    /// flag — reminder/social templates default to ON, monetary fines
    /// default to OFF so first-time users don't see a punitive default.
    private func defaultSelectedRules() -> Set<String> {
        var picks: Set<String> = []
        for block in availableCapabilityBlocks where enabledCapabilities.contains(block.id) {
            for template in block.suggestedRules where template.defaultEnabled {
                picks.insert(suggestedRuleKey(blockId: block.id, slug: template.slug))
            }
        }
        return picks
    }

    /// Builds the server-shaped trigger from the template's explicit
    /// `triggerEventType` (founder framing 2026-05-11 — never infer
    /// from slug). Trigger config jsonb is filled from
    /// `defaultConfig` keys that are NOT the consequence's `amount`.
    private func defaultTrigger(for template: CapabilityRuleOption) -> RuleTrigger {
        var configMap: [String: JSONConfig] = [:]
        for (k, v) in template.defaultConfig where k != "amount" {
            if let i = Int(v) { configMap[k] = .int(i) } else { configMap[k] = .string(v) }
        }
        return RuleTrigger(eventType: template.triggerEventType, config: .object(configMap))
    }

    /// Builds the consequence row from the template's
    /// `consequenceType` + `defaultConfig.amount` (for fine
    /// consequences). Non-fine consequences (sendNotification,
    /// loseTurn, …) receive an empty config object.
    private func defaultConsequences(for template: CapabilityRuleOption) -> [RuleConsequence] {
        var configMap: [String: JSONConfig] = [:]
        if template.consequenceType == .fine,
           let raw = template.defaultConfig["amount"],
           let amount = Int(raw) {
            configMap["amount"] = .int(amount)
        }
        return [RuleConsequence(type: template.consequenceType, config: .object(configMap))]
    }

    private func userFacing(error: ResourceBuilderError) -> String {
        switch error {
        case .missingRequiredField(let key):
            return "Falta el campo: \(key)"
        case .unsupportedCapability(let id):
            return "Capacidad no soportada: \(id)"
        case .capabilityConflict(let a, let b):
            return "\(a) no se puede activar con \(b)"
        case .rpcFailed(let message):
            return "Error del servidor: \(message)"
        case .underlying(let message):
            return message
        }
    }
}
