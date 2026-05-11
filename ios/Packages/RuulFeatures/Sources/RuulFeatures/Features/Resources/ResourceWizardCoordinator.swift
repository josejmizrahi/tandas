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

    public private(set) var step: ResourceWizardStep = .typePicker
    public private(set) var selectedBuilder: (any ResourceBuilder)?
    public var basicFields: [String: JSONConfig] = [:]
    public var enabledCapabilities: Set<String> = []
    /// Suggested rules the user has toggled ON in step 4. Keyed by the
    /// composite "blockId.slug" so the same rule slug declared by two
    /// different capabilities can coexist independently.
    public var selectedSuggestedRules: Set<String> = []
    /// Recurrence pattern when "recurrence" capability is enabled.
    /// Shape: { frequency: "weekly"|"biweekly"|"monthly", dayOfWeek: int,
    /// hour: int, minute: int }. Empty when recurrence is off.
    public var recurrenceFrequency: String = "weekly"
    public var recurrenceDayOfWeek: Int = 4  // Thursday default for cenas
    public var recurrenceHour: Int = 20
    public var recurrenceMinute: Int = 0

    public private(set) var isCreating: Bool = false
    public private(set) var error: String?
    public private(set) var createdResourceId: UUID?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.wizard")
    private let resolver: CapabilityResolver

    public init(
        group: Group,
        registry: ResourceBuilderRegistry,
        catalog: CapabilityCatalog = .v1,
        resolver: CapabilityResolver = CapabilityResolver()
    ) {
        self.group = group
        self.registry = registry
        self.catalog = catalog
        self.resolver = resolver
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

    public func goBack() {
        switch step {
        case .typePicker: return
        case .fields:     step = .typePicker; selectedBuilder = nil
        case .options:    step = .fields
        case .rules:      step = .options
        case .review:     step = hasAnySuggestedRules ? .rules : .options
        }
    }

    public func advanceFromFields() {
        guard validateRequiredFields() else { return }
        step = .options
    }

    public func advanceFromOptions() {
        // Skip step 4 when no enabled capability advertises any
        // suggested rules — there's nothing to pick. Drops the user
        // straight to review.
        step = hasAnySuggestedRules ? .rules : .review
    }

    public func advanceFromRules() {
        step = .review
    }

    public var canAdvanceFromFields: Bool {
        validateRequiredFields()
    }

    /// Capability blocks the picker should show in step 3 — filtered by:
    /// (1) the selected builder declares them, AND
    /// (2) the resolver says they're available on this group.
    public var availableCapabilityBlocks: [any CapabilityBlock] {
        guard let builder = selectedBuilder else { return [] }
        let groupAvailable = Set(resolver.availableCapabilities(
            for: builder.resourceType, in: group, catalog: catalog
        ))
        return builder.optionalCapabilities
            .filter { groupAvailable.contains($0) }
            .compactMap { catalog[$0] }
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
            }
        }
    }

    public func isCapabilityEnabled(_ blockId: String) -> Bool {
        enabledCapabilities.contains(blockId)
    }

    // MARK: - Suggested rules (Step 4)

    /// Suggested rules from every enabled capability. Used by step 4 to
    /// render the toggle list and by submit to materialize the user's
    /// picks into `RuleDraft` rows.
    public var availableSuggestedRules: [(block: any CapabilityBlock, template: RuleTemplate)] {
        availableCapabilityBlocks
            .filter { enabledCapabilities.contains($0.id) }
            .flatMap { block in
                block.suggestedRules.map { (block: block, template: $0) }
            }
    }

    public var hasAnySuggestedRules: Bool {
        !availableSuggestedRules.isEmpty
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

    // MARK: - Submit

    public var canSubmit: Bool {
        selectedBuilder != nil && validateRequiredFields() && !isCreating
    }

    public func submit() async -> Bool {
        guard let builder = selectedBuilder, canSubmit else { return false }
        isCreating = true
        error = nil
        defer { isCreating = false }

        // Build seriesPattern when "recurrence" capability is enabled.
        // The builder reads this and creates a ResourceSeries first,
        // linking the event/slot to it via series_id.
        let seriesPattern: JSONConfig? = enabledCapabilities.contains("recurrence")
            ? .object([
                "frequency": .string(recurrenceFrequency),
                "dayOfWeek": .int(recurrenceDayOfWeek),
                "hour":      .int(recurrenceHour),
                "minute":    .int(recurrenceMinute)
            ])
            : nil

        // Materialize selected suggested rules into RuleDraft rows so the
        // builder can hand them to the rule repo at create time. The
        // template's `defaultConfig` flows into the trigger's config jsonb
        // so server-side evaluators see the right thresholds.
        let initialRules: [RuleDraft] = availableSuggestedRules.compactMap { pair in
            guard isSuggestedRuleSelected(blockId: pair.block.id, slug: pair.template.slug) else {
                return nil
            }
            return RuleDraft(
                slug: pair.template.slug,
                name: pair.template.displayName,
                description: pair.template.summary,
                isActive: true,
                trigger: defaultTrigger(for: pair.template),
                conditions: [RuleCondition(type: .alwaysTrue, config: .object([:]))],
                consequences: defaultConsequences(for: pair.template)
            )
        }

        let draft = ResourceDraft(
            groupId: group.id,
            resourceType: builder.resourceType,
            basicFields: basicFields,
            enabledCapabilities: Array(enabledCapabilities),
            capabilityConfigs: [:],
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
            self.error = "No pudimos crear el recurso: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Helpers

    private func validateRequiredFields() -> Bool {
        guard let builder = selectedBuilder else { return false }
        for field in builder.requiredFields {
            if let value = basicFields[field.key] {
                if case let .string(s) = value, s.trimmingCharacters(in: .whitespaces).isEmpty {
                    return false
                }
            } else {
                return false
            }
        }
        return true
    }

    private func defaultCapabilitiesFor(_ builder: any ResourceBuilder) -> Set<String> {
        // Founder framing 2026-05-11: capability auto-on defaults come
        // from the group's template/preset, NEVER from a hardcoded
        // per-resource_type rule. A "simple junta" should open with
        // nothing pre-ticked; a structured "tanda" preset can opt every
        // member into RSVP + check-in + rotation explicitly.
        //
        // Phase 1: always empty. Phase 2 reads
        // `group.template.defaultCapabilities[builder.resourceType.rawValue]`
        // when the templates table gains that column.
        return []
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
    private func defaultTrigger(for template: RuleTemplate) -> RuleTrigger {
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
    private func defaultConsequences(for template: RuleTemplate) -> [RuleConsequence] {
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
