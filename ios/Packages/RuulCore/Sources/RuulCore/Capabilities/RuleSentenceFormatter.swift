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

    /// Composer-flavored sentence for a `RuleDraft` (multi-condition,
    /// multi-consequence). Reads inline config from each ShapeInstance,
    /// so threshold/amount values appear within the natural phrase
    /// ("multa de $200", "más de 15 minutos tarde", …).
    ///
    /// Shape: "Cuando <trigger>[, si <cond1> y <cond2>], entonces
    /// <cons1>[, también <cons2>]." Renders nicely with line breaks
    /// for long lists by inserting `\n` between clauses; the caller
    /// can replace with `, ` if they want a single line.
    public static func sentence(
        for draft: RuleDraft,
        registry: RuleShapeRegistry,
        singleLine: Bool = false
    ) -> String {
        let separator = singleLine ? " " : "\n"
        var clauses: [String] = []

        // Trigger clause.
        if let trigger = draft.trigger {
            clauses.append("Cuando " + phrase(for: trigger, registry: registry))
        } else {
            clauses.append("Cuando (elige un disparador)")
        }

        // Conditions clause.
        if !draft.conditions.isEmpty {
            let parts = draft.conditions.map { phrase(for: $0, registry: registry) }
            clauses.append("si " + joinWithY(parts))
        }

        // Exceptions clause (mig 00248 / §22.2 Governance.md). Halajic
        // "regla y excepción" — listed BEFORE the consequence so the
        // sentence reads as "…, excepto si Z, entonces W." which is
        // the natural Spanish ordering.
        if !draft.exceptions.isEmpty {
            let parts = draft.exceptions.map { phrase(for: $0, registry: registry) }
            clauses.append("excepto si " + joinWithY(parts))
        }

        // Consequences clause. Each consequence may carry an optional
        // target selector (§22.3 / mig 00249); render as "<verb> <target>"
        // when present so the sentence reads naturally — e.g. "multa
        // al anfitrión", "notifica al rol tesorero".
        if draft.consequences.isEmpty {
            clauses.append("entonces (agrega al menos una consecuencia)")
        } else if draft.consequences.count == 1 {
            clauses.append("entonces " + phraseWithTarget(for: draft.consequences[0], registry: registry))
        } else {
            let parts = draft.consequences.map { phraseWithTarget(for: $0, registry: registry) }
            clauses.append("entonces " + joinWithY(parts))
        }

        return clauses.joined(separator: singleLine ? ", " : separator).appending(".")
    }

    /// Joins a list of phrases with natural Spanish conjunctions:
    /// ["a"] → "a"; ["a","b"] → "a y b"; ["a","b","c"] → "a, b y c".
    private static func joinWithY(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) y \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head) y \(items.last ?? "")"
        }
    }

    /// Like `phrase(for:)` but appends a target clause for consequences
    /// that re-route via `instance.target` selector (§22.3 / mig 00249).
    /// Examples:
    ///   nil / "$trigger.actor" → "multa de $200"
    ///   "$resource.host"       → "multa al anfitrión de $200"
    ///   "$role.treasurer"      → "multa al rol treasurer de $200"
    private static func phraseWithTarget(
        for instance: ShapeInstance,
        registry: RuleShapeRegistry
    ) -> String {
        let base = phrase(for: instance, registry: registry)
        guard let selector = instance.target, selector != "$trigger.actor" else { return base }
        let targetClause = targetClause(for: selector)
        // Insert the target between the shape label and the config
        // parentheses if present, else just append.
        if let parenStart = base.range(of: " (") {
            return base.replacingCharacters(in: parenStart.lowerBound..<parenStart.lowerBound, with: " \(targetClause)")
        }
        return "\(base) \(targetClause)"
    }

    private static func targetClause(for selector: String) -> String {
        if selector == "$resource.host" { return "al anfitrión" }
        if selector.hasPrefix("$role.") {
            let roleId = String(selector.dropFirst("$role.".count))
            return "al rol \(roleId)"
        }
        return selector
    }

    /// Natural-language phrase for a single shape instance. Uses the
    /// shape's labelES as the base and inlines any config values that
    /// resolve to a renderable type (int / currency / string).
    private static func phrase(
        for instance: ShapeInstance,
        registry: RuleShapeRegistry
    ) -> String {
        guard let shape = registry.shape(id: instance.shapeId) else {
            return instance.shapeId
        }
        let label = shape.labelES.lowercased()
        let configPairs = inlineInstanceConfig(shape: shape, config: instance.config)
        if configPairs.isEmpty { return label }
        return "\(label) (\(configPairs))"
    }

    /// Build "key: value · key2: value2" from a ShapeInstance.config.
    /// Skips fields the config doesn't carry; skips values that don't
    /// match the field's declared kind.
    private static func inlineInstanceConfig(
        shape: RuleShape,
        config: JSONConfig
    ) -> String {
        var pieces: [String] = []
        for field in shape.configFields {
            guard let value = config[field.key] else { continue }
            if let str = renderValue(value, kind: field.kind) {
                pieces.append("\(field.labelES.lowercased()): \(str)")
            }
        }
        return pieces.joined(separator: " · ")
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
