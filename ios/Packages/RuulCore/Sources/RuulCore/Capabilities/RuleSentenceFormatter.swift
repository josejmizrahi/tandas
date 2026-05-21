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

    /// Templated preview for a `RuleBuilderTemplate` Gallery card —
    /// interpolates `naturalLanguagePreviewTemplate` (mig 00295) with
    /// the template's `defaultParams`, returning a sentence the user
    /// sees BEFORE picking the template ("Si un miembro llega más de
    /// 15 minutos tarde a este evento, se le cobra $200.").
    ///
    /// Falls back to `descriptionES` when the template was seeded before
    /// mig 00295 and has no preview template set. UniversalRuleTemplates.md
    /// §8.5 and §9.2 — "the sentence is source-of-truth UX".
    ///
    /// Pass `paramsOverride` when the caller has already collected user
    /// input (e.g. inside the param form); else `defaultParams` are used
    /// so the Gallery card shows the same sentence the user will see
    /// post-pick with no changes.
    public static func preview(
        forTemplate template: RuleBuilderTemplate,
        paramsOverride: [String: JSONConfig]? = nil
    ) -> String {
        guard let templateString = template.naturalLanguagePreviewTemplate else {
            return template.descriptionES
        }
        let params = paramsOverride ?? defaultParamsDict(template.defaultParams)
        return interpolate(templateString, params: params)
    }

    /// Substitutes `{{key}}` placeholders in a templated sentence with
    /// values from `params`. Unknown placeholders are left intact so the
    /// gap is visible (helps surface forgotten params in QA).
    ///
    /// `{{resource.name}}` is special-cased: when the caller can't supply
    /// a real resource reference (e.g. Gallery preview), it renders as a
    /// neutral "este recurso" so the sentence still reads.
    static func interpolate(_ template: String, params: [String: JSONConfig]) -> String {
        var result = template
        for (key, value) in params {
            let placeholder = "{{\(key)}}"
            result = result.replacingOccurrences(of: placeholder, with: stringValue(value))
        }
        // Common references the Gallery preview can't resolve from
        // params alone — softened defaults keep the sentence readable.
        result = result.replacingOccurrences(of: "{{resource.name}}",  with: "este recurso")
        result = result.replacingOccurrences(of: "{{threshold}}",      with: thresholdString(params: params))
        return result
    }

    private static func defaultParamsDict(_ params: JSONConfig) -> [String: JSONConfig] {
        if case .object(let dict) = params { return dict }
        return [:]
    }

    private static func stringValue(_ config: JSONConfig) -> String {
        switch config {
        case .int(let i):    return String(i)
        case .string(let s): return s
        case .bool(let b):   return b ? "sí" : "no"
        case .double(let d): return String(d)
        case .object, .array, .null: return ""
        }
    }

    /// `threshold_cents` (cents) → "$2,000" presentation. Falls back to
    /// the raw `threshold` int if it's already in display units.
    private static func thresholdString(params: [String: JSONConfig]) -> String {
        if case .int(let cents) = params["threshold_cents"] {
            return formatMxn(cents / 100)
        }
        if case .int(let amount) = params["threshold"] {
            return formatMxn(amount)
        }
        return "{{threshold}}"
    }

    private static func formatMxn(_ value: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.groupingSeparator = ","
        nf.locale = Locale(identifier: "es_MX")
        return nf.string(from: NSNumber(value: value)) ?? String(value)
    }

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
    ///
    /// When `draft.membershipFilter` is set, the sentence is prefixed
    /// with "Solo para <name>:" (§22.5 / mig 00250). The caller passes
    /// `memberNameProvider` so the formatter can resolve the UUID to a
    /// human name; when nil or the lookup misses, falls back to "este
    /// miembro" so the sentence still reads.
    public static func sentence(
        for draft: RuleDraft,
        registry: RuleShapeRegistry,
        singleLine: Bool = false,
        memberNameProvider: ((UUID) -> String?)? = nil
    ) -> String {
        let separator = singleLine ? " " : "\n"
        var clauses: [String] = []

        // Membership prefix (§22.5). Render before the trigger so the
        // sentence reads as a scoped statement: "Solo para Isaac: Cuando…".
        if let membershipId = draft.membershipFilter {
            let name = memberNameProvider?(membershipId) ?? "este miembro"
            clauses.append("Solo para \(name):")
        }

        // Trigger clause.
        if let trigger = draft.trigger {
            clauses.append("Cuando " + phrase(for: trigger, registry: registry))
        } else {
            clauses.append("Cuando (elige cuándo aplica)")
        }

        // Conditions clause. §22.4 (mig 00251): when the composer is
        // in Avanzado mode the draft carries a tree; render it via
        // the recursive prose builder so the user sees parens around
        // OR-inside-AND, NOT prefixes, etc. Simple mode falls through
        // to the flat join.
        if let tree = draft.conditionsTree, !tree.isFlatAnd {
            if let prose = draftConditionTreePhrase(tree, registry: registry, parent: .none) {
                clauses.append("si " + prose)
            }
        } else if !draft.conditions.isEmpty {
            let parts = draft.conditions.compactMap { phraseOrNil(for: $0, registry: registry) }
            if !parts.isEmpty {
                clauses.append("si " + joinWithY(parts))
            }
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
            clauses.append("entonces (agrega qué pasa)")
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

    /// Like `phrase(for:)` but returns nil for the `alwaysTrue` leaf
    /// so it disappears from the rendered sentence (mirrors the
    /// behavior of the tree leaf phraser). Used by the flat-list path
    /// when the conditions include an alwaysTrue placeholder.
    private static func phraseOrNil(
        for instance: ShapeInstance,
        registry: RuleShapeRegistry
    ) -> String? {
        if instance.shapeId == "alwaysTrue" { return nil }
        return phrase(for: instance, registry: registry)
    }

    /// §22.4 — recursive prose builder for an author-side ShapeNode
    /// tree (used by the live composer preview). Mirrors the
    /// engine-side `conditionPhrase(for: ConditionNode, registry:)`
    /// but reads `ShapeInstance` leaves and inlines their config
    /// values the way the flat path already does.
    private static func draftConditionTreePhrase(
        _ node: ShapeNode,
        registry: RuleShapeRegistry,
        parent: ParentOp
    ) -> String? {
        switch node {
        case .leaf(let instance):
            return phraseOrNil(for: instance, registry: registry)
        case .and(_, let children):
            let parts = children.compactMap {
                draftConditionTreePhrase($0, registry: registry, parent: .and)
            }
            if parts.isEmpty { return nil }
            if parts.count == 1 { return parts[0] }
            return joinWithParens(parts, sep: " y ", own: .and, parent: parent)
        case .or(_, let children):
            let parts = children.compactMap {
                draftConditionTreePhrase($0, registry: registry, parent: .or)
            }
            if parts.isEmpty { return nil }
            if parts.count == 1 { return parts[0] }
            return joinWithParens(parts, sep: " o ", own: .or, parent: parent)
        case .not(_, let child):
            guard let inner = draftConditionTreePhrase(child, registry: registry, parent: .not) else {
                return nil
            }
            let needsParens: Bool = {
                if case .leaf = child { return false }
                return true
            }()
            return needsParens ? "no (\(inner))" : "no \(inner)"
        }
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

    // MARK: - Condition tree (§22.4)

    /// Renders an AND/OR/NOT condition tree as Spanish prose. Returns
    /// nil for the trivial empty AND (which is treated as "no extra
    /// clause"). Leaves with `alwaysTrue` shape collapse to nil so they
    /// don't pollute the sentence (`Si X y siempre → Y` reads worse
    /// than `Si X → Y`).
    ///
    /// Parenthesization rule: only when a child's connector is weaker
    /// than its parent's. AND binds tighter than OR; NOT binds tighter
    /// than both. So `(A or B) and C` needs parens around the OR, but
    /// `A and B and C` does not. Single leaves never wrap.
    ///
    /// Example outputs:
    /// - `.and([A, B])` → `"a y b"`
    /// - `.and([A, .or([B, C])])` → `"a y (b o c)"`
    /// - `.not(.leaf(D))` → `"no d"`
    /// - `.not(.and([A, B]))` → `"no (a y b)"`
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
            // NOT always prefixes with "no". When the inner is a
            // composite (AND/OR), parenthesize so "no A y B" doesn't
            // read as "(no A) y B".
            let needsParens: Bool = {
                if case .leaf = child { return false }
                return true
            }()
            return needsParens ? "no (\(inner))" : "no \(inner)"
        }
    }

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
    /// Spanish label when available; falls back to the raw
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
