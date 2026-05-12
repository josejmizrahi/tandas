import Foundation
import Observation
import OSLog
import RuulCore

// NOTE: file name still "EventRulesCoordinator.swift" for git history
// continuity; the type is the polymorphic `ResourceRulesCoordinator`
// that drives the rules surface for ANY Resource — events, assets,
// funds, slots. Founder framing 2026-05-10: rules apply to any
// Resource, not just events.

/// Coordinator backing the per-resource Rules surface. Loads rules with
/// `rules.resource_id = context.resourceId` (Taxonomy §29) and drives
/// the rule builder form.
///
/// Founder principle 2026-05-10: the rule builder is catalog-driven —
/// triggers/conditions/consequences come from `RuleShapeRegistry`, NOT
/// from hardcoded Swift enums. Adding a new shape is a server-side
/// INSERT into `public.rule_shapes` + an evaluator in ruleEngine.ts;
/// no iOS release needed.
///
/// Slice 2 (R1) shape: the form lets the user pick one trigger + one
/// consequence, both rendered from the registry. Conditions are filled
/// automatically with `alwaysTrue` for the MVP — the conditions picker
/// arrives in slice 3 once the catalog grows beyond two condition kinds.
@Observable @MainActor
public final class ResourceRulesCoordinator {
    public let context: ResourceRuleContext
    public var groupId: UUID    { context.groupId }
    public var resourceId: UUID { context.resourceId }
    public var canCreate: Bool  { context.canCreate }
    public let shapeRegistry: RuleShapeRegistry

    public private(set) var rules: [GroupRule] = []
    /// Bucketed by scope per Taxonomy §29: resource (event-specific),
    /// series (recurrence-wide), group (everything else). Each list is
    /// already ordered most-recent-first within its scope.
    public var resourceRules: [GroupRule] { rules.filter { $0.scope == .resource } }
    public var seriesRules:   [GroupRule] { rules.filter { $0.scope == .series   } }
    public var groupRules:    [GroupRule] { rules.filter { $0.scope == .group    } }

    public private(set) var isLoading: Bool = true
    public private(set) var isSubmitting: Bool = false
    public private(set) var error: String?
    public var addSheetPresented: Bool = false

    // Form state — catalog-driven.
    public var formName: String = ""
    /// Currently picked trigger shape id (e.g. "checkInRecorded"). The
    /// resolved shape is consulted via `shapeRegistry.shape(id:)`.
    public var formTriggerId: String?
    /// Currently picked consequence shape id (e.g. "fine"). Defaults to
    /// the first available consequence — typically `fine` in V1.
    public var formConsequenceId: String?
    /// Per-field values keyed by `shapeId + "." + fieldKey`. Stored as
    /// strings because the form uses text fields; converted to typed
    /// JSONConfig at submit time using the field's declared `kind`.
    public var formFieldValues: [String: String] = [:]

    private let ruleRepo: any RuleRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "event.rules")

    public init(
        context: ResourceRuleContext,
        ruleRepo: any RuleRepository,
        shapeRegistry: RuleShapeRegistry
    ) {
        self.context = context
        self.ruleRepo = ruleRepo
        self.shapeRegistry = shapeRegistry
    }

    // MARK: - Catalog-driven options

    /// Triggers applicable to a resource-scoped rule on `context.resourceType`.
    /// The registry filters by scope/resource_type; iOS just renders the
    /// surviving rows. Catalog rows that leave `valid_resource_types`
    /// empty count as universal and always pass.
    public var availableTriggers: [RuleShape] {
        shapeRegistry.shapes(
            kind: .trigger,
            scope: "resource",
            resourceType: context.resourceType
        )
    }

    public var availableConsequences: [RuleShape] {
        // Consequences are scope-agnostic — the catalog rows leave
        // `valid_scopes` empty so they all pass.
        shapeRegistry.shapes(of: .consequence)
    }

    public var selectedTrigger: RuleShape? {
        guard let id = formTriggerId else { return nil }
        return shapeRegistry.shape(id: id)
    }

    public var selectedConsequence: RuleShape? {
        guard let id = formConsequenceId else { return nil }
        return shapeRegistry.shape(id: id)
    }

    // MARK: - Loading

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            // R2: pull resource + series + group scope in one RPC so the
            // sheet can render "Heredada de…" badges without an extra
            // round-trip. The server splits the three buckets via UNION
            // ALL; iOS classifies each row by inspecting scope columns.
            rules = try await ruleRepo.listScopedForResource(resourceId)
        } catch {
            log.warning("load failed: \(error.localizedDescription)")
            self.error = "No pudimos cargar las reglas."
        }
    }

    // MARK: - Form lifecycle

    public func resetForm() {
        formName = ""
        // Default to the first available trigger so the form opens with
        // something selected — matches AddManualFineSheet's "preselect
        // first member" UX.
        formTriggerId = availableTriggers.first?.id
        formConsequenceId = availableConsequences.first?.id
        formFieldValues = [:]
        seedFieldDefaults(for: selectedTrigger)
        seedFieldDefaults(for: selectedConsequence)
        error = nil
    }

    /// Populate form field text values from the shape's declared defaults
    /// so the user opens the form with sensible numbers already filled in.
    private func seedFieldDefaults(for shape: RuleShape?) {
        guard let shape else { return }
        for field in shape.configFields {
            let key = "\(shape.id).\(field.key)"
            if formFieldValues[key] != nil { continue }
            if let defaultValue = field.defaultValue {
                formFieldValues[key] = render(defaultValue)
            }
        }
    }

    /// Called when the trigger picker changes — seeds defaults for any
    /// fields the new trigger declares.
    public func selectTrigger(_ shapeId: String) {
        formTriggerId = shapeId
        seedFieldDefaults(for: selectedTrigger)
    }

    public func selectConsequence(_ shapeId: String) {
        formConsequenceId = shapeId
        seedFieldDefaults(for: selectedConsequence)
    }

    public func fieldBindingKey(shape: RuleShape, field: RuleShapeField) -> String {
        "\(shape.id).\(field.key)"
    }

    // MARK: - Validation

    public var canSubmit: Bool {
        guard canCreate, !isSubmitting else { return false }
        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count >= 2 else { return false }
        guard let trigger = selectedTrigger,
              let consequence = selectedConsequence else { return false }
        // Every required field on both shapes must parse to a non-empty
        // value the server will accept.
        guard fieldsValid(for: trigger) else { return false }
        guard fieldsValid(for: consequence) else { return false }
        return true
    }

    private func fieldsValid(for shape: RuleShape) -> Bool {
        for field in shape.configFields {
            if field.optional { continue }
            let key = fieldBindingKey(shape: shape, field: field)
            guard let raw = formFieldValues[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return false
            }
            guard parse(raw, kind: field.kind, min: field.min, max: field.max) != nil else {
                return false
            }
        }
        return true
    }

    // MARK: - Submit

    @discardableResult
    public func submit() async -> GroupRule? {
        guard canSubmit,
              let triggerShape = selectedTrigger,
              let consequenceShape = selectedConsequence else { return nil }

        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = buildTrigger(shape: triggerShape)
        let conditions = [defaultCondition]
        let consequences = [buildConsequence(shape: consequenceShape)]

        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        do {
            let rule = try await ruleRepo.createResourceRule(
                groupId: groupId,
                resourceId: resourceId,
                name: trimmedName,
                trigger: trigger,
                conditions: conditions,
                consequences: consequences
            )
            rules.insert(rule, at: 0)
            resetForm()
            return rule
        } catch {
            self.error = humanize(error: error)
            log.warning("submit failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func buildTrigger(shape: RuleShape) -> RuleTrigger {
        // Map the catalog id back to the canonical SystemEventType.
        // unknown(...) cases survive forward-compat: a shape introduced
        // server-side without an iOS enum case still round-trips through
        // the engine because the rawString is preserved.
        let eventType = systemEventType(from: shape.id)
        return RuleTrigger(eventType: eventType, config: collectConfig(for: shape))
    }

    private func buildConsequence(shape: RuleShape) -> RuleConsequence {
        let type = consequenceType(from: shape.id)
        return RuleConsequence(type: type, config: collectConfig(for: shape))
    }

    private var defaultCondition: RuleCondition {
        RuleCondition(type: .alwaysTrue, config: .object([:]))
    }

    private func collectConfig(for shape: RuleShape) -> JSONConfig {
        var values: [String: JSONConfig] = [:]
        for field in shape.configFields {
            let key = fieldBindingKey(shape: shape, field: field)
            guard let raw = formFieldValues[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let parsed = parse(raw, kind: field.kind, min: field.min, max: field.max) else {
                continue
            }
            values[field.key] = parsed
        }
        return .object(values)
    }

    private func parse(_ raw: String, kind: RuleShapeField.Kind, min: Int?, max: Int?) -> JSONConfig? {
        switch kind {
        case .int, .currency:
            guard let n = Int(raw.filter(\.isNumber)) else { return nil }
            if let min, n < min { return nil }
            if let max, n > max { return nil }
            return .int(n)
        case .string:
            return .string(raw)
        }
    }

    private func render(_ value: JSONConfig) -> String {
        switch value {
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .bool(let b):   return String(b)
        case .null:          return ""
        case .array, .object: return ""
        }
    }

    /// Forward-compat: a shape id added server-side that doesn't have a
    /// matching SystemEventType case falls back to `.unknown(id)` so the
    /// rule still serializes correctly. The engine will skip it until the
    /// iOS enum gains the case in a future release.
    private func systemEventType(from id: String) -> SystemEventType {
        switch id {
        case "eventClosed":             return .eventClosed
        case "eventCreated":            return .eventCreated
        case "rsvpDeadlinePassed":      return .rsvpDeadlinePassed
        case "hoursBeforeEvent":        return .hoursBeforeEvent
        case "rsvpSubmitted":           return .rsvpSubmitted
        case "rsvpChangedSameDay":      return .rsvpChangedSameDay
        case "checkInRecorded":         return .checkInRecorded
        case "checkInMissed":           return .checkInMissed
        case "eventDescriptionMissing": return .eventDescriptionMissing
        default:                        return .unknown(id)
        }
    }

    private func consequenceType(from id: String) -> ConsequenceType {
        switch id {
        case "fine":                return .fine
        case "loseTurn":            return .loseTurn
        case "losePriority":        return .losePriority
        case "serviceCompensation": return .serviceCompensation
        case "blockTemporary":      return .blockTemporary
        case "reciprocity":         return .reciprocity
        case "logOnly":             return .logOnly
        case "sumPoints":           return .sumPoints
        case "subtractPoints":      return .subtractPoints
        case "sendNotification":    return .sendNotification
        case "startVote":           return .startVote
        case "createEvent":         return .createEvent
        case "assignSlot":          return .assignSlot
        case "transferRight":       return .transferRight
        case "callWebhook":         return .callWebhook
        default:                    return .unknown(id)
        }
    }

    private func humanize(error: Error) -> String {
        let raw = (error as NSError).localizedDescription.lowercased()
        if raw.contains("auth required") { return "Tu sesión expiró. Volvé a entrar." }
        // 00122 governance-routing error paths. Auto-promote to a vote
        // can't ship until a `rule_create` VoteType exists (today only
        // ruleChange / ruleRepeal cover modifying / removing existing
        // rules) — surface a clear message instead so the user knows
        // the action is gated rather than failing for an unclear reason.
        if raw.contains("governance requires vote") {
            return "Las reglas de este grupo requieren votación. (Próximamente: proponer la nueva regla.)"
        }
        if raw.contains("governance denied") {
            return "Este grupo no permite crear reglas nuevas."
        }
        // Pre-00122 wording + post-00122 fallback ("admin only" string).
        if raw.contains("only group admins or the event host") {
            return "Sólo el host del evento o un admin pueden crear reglas aquí."
        }
        if raw.contains("only group admins") {
            return "Sólo los admins del grupo pueden crear reglas para este recurso."
        }
        if raw.contains("admin only") {
            return "Sólo administradores pueden crear reglas aquí."
        }
        if raw.contains("resource does not belong") {
            return "Esta regla no pertenece a este evento."
        }
        if raw.contains("rule name must be") {
            return "El nombre debe tener al menos 2 caracteres."
        }
        return "No pudimos crear la regla. Intenta de nuevo."
    }
}
