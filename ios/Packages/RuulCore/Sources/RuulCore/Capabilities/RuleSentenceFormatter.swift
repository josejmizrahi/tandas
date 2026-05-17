import Foundation

/// Renders a `GroupRule` (or a draft trigger+consequence pair from the
/// rule builder) as a single "Si X → Y" sentence in Spanish.
///
/// Founder principle 2026-05-10: rules surface to users only as plain-
/// language sentences — never as trigger / condition / consequence
/// columns. This formatter is the canonical sentence engine; views
/// should never stitch their own.
///
/// Labels come from the `RuleShapeRegistry` so adding a new shape
/// server-side automatically renders the right copy here. When a shape
/// is missing from the registry (forward-compat: server added it but
/// iOS hasn't refreshed yet), the formatter falls back to a softened
/// version of the raw `eventType.rawString` / `consequenceType.rawString`.
public enum RuleSentenceFormatter {

    /// Compact "Si X → Y" sentence for a persisted rule. Used in rule
    /// list rows and per-event Rules sections.
    public static func sentence(
        for rule: GroupRule,
        registry: RuleShapeRegistry
    ) -> String {
        let triggerPhrase = triggerPhrase(for: rule.trigger, registry: registry)
        if let consequencePhrase = consequencePhrase(for: rule.consequences.first, registry: registry) {
            return "Si \(triggerPhrase) → \(consequencePhrase)"
        }
        return "Si \(triggerPhrase)"
    }

    /// Same shape but for the rule builder's live preview, where the user
    /// hasn't submitted yet. Reads the picked shape ids + field values
    /// (raw strings, same dictionary the form binds to).
    public static func draftSentence(
        triggerShapeId: String?,
        consequenceShapeId: String?,
        fieldValues: [String: String],
        registry: RuleShapeRegistry
    ) -> String? {
        guard let triggerShapeId,
              let triggerShape = registry.shape(id: triggerShapeId) else {
            return nil
        }
        let triggerPhrase = triggerShape.labelES.lowercased()

        guard let consequenceShapeId,
              let consequenceShape = registry.shape(id: consequenceShapeId) else {
            return "Si \(triggerPhrase)"
        }

        let consequencePhrase = draftConsequencePhrase(
            shape: consequenceShape,
            fieldValues: fieldValues
        )
        return "Si \(triggerPhrase) → \(consequencePhrase)"
    }

    // MARK: - Trigger

    private static func triggerPhrase(
        for trigger: RuleTrigger,
        registry: RuleShapeRegistry
    ) -> String {
        let id = trigger.eventType.rawString
        if let shape = registry.shape(id: id) {
            // For triggers with config (e.g. hoursBeforeEvent), inline the
            // value at the end so the sentence reads naturally.
            if let inline = inlineTriggerConfig(shape: shape, config: trigger.config) {
                return "\(shape.labelES.lowercased()) (\(inline))"
            }
            return shape.labelES.lowercased()
        }
        return fallbackTriggerPhrase(eventType: trigger.eventType, config: trigger.config)
    }

    private static func inlineTriggerConfig(
        shape: RuleShape,
        config: JSONConfig
    ) -> String? {
        var pieces: [String] = []
        for field in shape.configFields {
            guard let value = config[field.key] else { continue }
            if let str = renderValue(value, kind: field.kind) {
                pieces.append("\(field.labelES.lowercased()): \(str)")
            }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    /// Pre-catalog fallback for triggers the registry doesn't know about.
    /// Mirrors the hand-rolled strings the legacy `RuleSummaryFormatter`
    /// shipped — kept here so a brand-new install with a stale registry
    /// still renders something usable.
    private static func fallbackTriggerPhrase(
        eventType: SystemEventType,
        config: JSONConfig
    ) -> String {
        switch eventType {
        case .eventClosed:             return "se cierra el evento"
        case .checkInRecorded:         return "alguien hace check-in tarde"
        case .rsvpChangedSameDay:      return "alguien cancela el mismo día"
        case .hoursBeforeEvent:
            if let h = config["hours"]?.intValue {
                return "\(h) horas antes del evento"
            }
            return "faltan horas para el evento"
        case .rsvpSubmitted:           return "alguien responde RSVP"
        case .rsvpDeadlinePassed:      return "vence la fecha límite de RSVP"
        case .eventDescriptionMissing: return "falta la descripción del evento"
        default:                       return eventType.rawString
        }
    }

    // MARK: - Consequence

    private static func consequencePhrase(
        for envelope: GroupRule.ConsequenceEnvelope?,
        registry: RuleShapeRegistry
    ) -> String? {
        guard let envelope, let typeString = envelope.type else { return nil }
        let shape = registry.shape(id: typeString)
        switch typeString {
        case "fine":
            if let amount = envelope.config?.amount {
                return "cobrar $\(amount)"
            }
            if let amount = envelope.config?.baseAmount {
                return "cobrar $\(amount) (escalonada)"
            }
            return shape?.labelES.lowercased() ?? "cobrar una multa"
        default:
            return shape?.labelES.lowercased() ?? typeString
        }
    }

    private static func draftConsequencePhrase(
        shape: RuleShape,
        fieldValues: [String: String]
    ) -> String {
        switch shape.id {
        case "fine":
            let amountKey = "\(shape.id).amount"
            if let raw = fieldValues[amountKey],
               let amount = Int(raw.filter(\.isNumber)),
               amount > 0 {
                return "cobrar $\(amount)"
            }
            return shape.labelES.lowercased()
        default:
            return shape.labelES.lowercased()
        }
    }

    // MARK: - Condition tree (§22.4)

    /// Renders a condition tree as Spanish prose. Returns nil for
    /// the trivial empty AND (which is treated as "no extra clause").
    /// Leaves with `alwaysTrue` shape collapse to nil so they don't
    /// pollute the sentence (`Si X y siempre → Y` reads worse than
    /// `Si X → Y`).
    ///
    /// Parenthesization rule: only when a child's connector is weaker
    /// than its parent's. AND binds tighter than OR; NOT binds
    /// tighter than both. So `(A or B) and C` needs parens around the
    /// OR, but `A and B and C` does not. Single leaves never wrap.
    public static func conditionPhrase(
        for node: ConditionNode,
        registry: RuleShapeRegistry
    ) -> String? {
        render(node, registry: registry, parent: .none)
    }

    private enum ParentOp { case none, and, or, not }

    private static func render(
        _ node: ConditionNode,
        registry: RuleShapeRegistry,
        parent: ParentOp
    ) -> String? {
        switch node {
        case .leaf(let cond):
            return leafPhrase(condition: cond, registry: registry)

        case .and(let children):
            let rendered = children.compactMap {
                render($0, registry: registry, parent: .and)
            }
            if rendered.isEmpty { return nil }
            if rendered.count == 1 { return rendered[0] }
            return joinWithParens(rendered, sep: " y ", own: .and, parent: parent)

        case .or(let children):
            let rendered = children.compactMap {
                render($0, registry: registry, parent: .or)
            }
            if rendered.isEmpty { return nil }
            if rendered.count == 1 { return rendered[0] }
            return joinWithParens(rendered, sep: " o ", own: .or, parent: parent)

        case .not(let child):
            guard let inner = render(child, registry: registry, parent: .not) else {
                return nil
            }
            // NOT always wraps with "no" prefix. If the inner is a
            // composite (AND/OR), parenthesize for readability.
            let needsParens: Bool = {
                if case .leaf = child { return false }
                return true
            }()
            return needsParens ? "no (\(inner))" : "no \(inner)"
        }
    }

    /// Builds the joined phrase + parens-if-weaker-than-parent.
    private static func joinWithParens(
        _ parts: [String],
        sep: String,
        own: ParentOp,
        parent: ParentOp
    ) -> String {
        let joined = parts.joined(separator: sep)
        if needsParens(own: own, parent: parent) {
            return "(\(joined))"
        }
        return joined
    }

    private static func needsParens(own: ParentOp, parent: ParentOp) -> Bool {
        switch (own, parent) {
        case (.or, .and), (.or, .not):
            // OR inside AND or NOT needs parens (OR is weaker).
            return true
        case (.and, .not):
            // AND inside NOT — bind clearly so "no (A y B)" doesn't
            // read as "no A y B".
            return true
        default:
            return false
        }
    }

    /// Per-leaf natural-language phrase. Uses the shape registry's
    /// Spanish label when available; falls back to softened raw
    /// `ConditionType` rawString. `alwaysTrue` returns nil so it
    /// disappears from the rendered tree.
    private static func leafPhrase(
        condition: RuleCondition,
        registry: RuleShapeRegistry
    ) -> String? {
        if condition.type == .alwaysTrue { return nil }
        if let shape = registry.shape(id: condition.type.rawString) {
            return shape.labelES.lowercased()
        }
        return condition.type.rawString
    }

    // MARK: - Value rendering helpers

    private static func renderValue(_ value: JSONConfig, kind: RuleShapeField.Kind) -> String? {
        switch (kind, value) {
        case (.int, .int(let i)):       return String(i)
        case (.currency, .int(let i)):  return "$\(i)"
        case (.string, .string(let s)): return s
        default: break
        }
        // Generic fallbacks
        switch value {
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .bool(let b):   return String(b)
        default:             return nil
        }
    }
}
