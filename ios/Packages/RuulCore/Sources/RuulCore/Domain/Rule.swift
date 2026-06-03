import Foundation

/// Fila de `rules`.
public struct Rule: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID
    public let title: String
    public let body: String?
    public let ruleType: String
    public let severity: Int
    public let status: String
    public let triggerEventType: String?
    public let conditionTree: JSONValue?
    public let consequences: JSONValue?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case title
        case body
        case ruleType = "rule_type"
        case severity
        case status
        case triggerEventType = "trigger_event_type"
        case conditionTree = "condition_tree"
        case consequences
        case createdAt = "created_at"
    }

    public init(
        id: UUID,
        contextActorId: UUID,
        title: String,
        body: String? = nil,
        ruleType: String = "automation",
        severity: Int = 1,
        status: String = "active",
        triggerEventType: String? = nil,
        conditionTree: JSONValue? = nil,
        consequences: JSONValue? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.title = title
        self.body = body
        self.ruleType = ruleType
        self.severity = severity
        self.status = status
        self.triggerEventType = triggerEventType
        self.conditionTree = conditionTree
        self.consequences = consequences
        self.createdAt = createdAt
    }

    public var isActive: Bool { status == "active" }

    /// Descripción legible de la condición (sin mostrar JSON crudo).
    public var conditionDescription: String {
        guard let tree = conditionTree, tree != .null else { return "Siempre aplica" }
        return Self.describe(condition: tree)
    }

    /// Descripción legible de las consecuencias.
    public var consequenceDescription: String {
        guard let array = consequences?.arrayValue, !array.isEmpty else { return "Sin consecuencia" }
        return array.map { consequence in
            let type = consequence["type"]?.stringValue ?? "?"
            let amount = consequence["amount"]?.numberValue
            let currency = consequence["currency"]?.stringValue ?? ""
            switch type {
            case "fine", "create_obligation":
                if let amount {
                    return "Multa de \(amount.formatted(.number)) \(currency)"
                }
                return "Multa"
            default:
                return type
            }
        }.joined(separator: " · ")
    }

    private static func describe(condition: JSONValue) -> String {
        guard let op = condition["op"]?.stringValue else { return "Siempre aplica" }
        switch op {
        case "and":
            let parts = condition["conditions"]?.arrayValue?.map(describe(condition:)) ?? []
            return parts.joined(separator: " y ")
        case "or":
            let parts = condition["conditions"]?.arrayValue?.map(describe(condition:)) ?? []
            return parts.joined(separator: " o ")
        default:
            let field = condition["field"]?.stringValue ?? "?"
            let fieldLabel: String
            switch field {
            case "minutes_late": fieldLabel = "minutos tarde"
            case "same_day_cancellation": fieldLabel = "cancelación del mismo día"
            default: fieldLabel = field
            }
            let value = condition["value"]
            let valueLabel = value?.numberValue.map { $0.formatted(.number) }
                ?? value?.boolValue.map { $0 ? "sí" : "no" }
                ?? value?.stringValue
                ?? "?"
            let opLabel: String
            switch op {
            case ">": opLabel = "mayor a"
            case ">=": opLabel = "mayor o igual a"
            case "<": opLabel = "menor a"
            case "<=": opLabel = "menor o igual a"
            case "=", "==": opLabel = "igual a"
            case "!=": opLabel = "distinto de"
            default: opLabel = op
            }
            return "\(fieldLabel) \(opLabel) \(valueLabel)"
        }
    }
}

/// Resultado de `create_rule()`.
public struct RuleCreated: Decodable, Sendable, Equatable {
    public let ruleId: UUID
    public let rule: Rule

    enum CodingKeys: String, CodingKey {
        case ruleId = "rule_id"
        case rule
    }
}

// MARK: - Builders (CreateRuleWizard → backend jsonb)

/// Triggers de reglas que el wizard de F.8 soporta.
public enum RuleTrigger: String, Codable, Sendable, CaseIterable, Identifiable {
    case checkedIn = "event.checked_in"
    case participationCancelled = "event.participation_cancelled"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .checkedIn: return "Al hacer check-in"
        case .participationCancelled: return "Al cancelar asistencia"
        }
    }
}

public enum RuleConditionBuilder {
    /// `minutes_late > threshold`
    public static func lateMoreThan(minutes: Double) -> JSONValue {
        .object([
            "op": .string(">"),
            "field": .string("minutes_late"),
            "value": .number(minutes)
        ])
    }

    /// `same_day_cancellation = true`
    public static func sameDayCancellation() -> JSONValue {
        .object([
            "op": .string("="),
            "field": .string("same_day_cancellation"),
            "value": .bool(true)
        ])
    }
}

public enum RuleConsequenceBuilder {
    /// `[{type: fine, amount, currency}]`
    public static func fine(amount: Double, currency: String) -> JSONValue {
        .array([
            .object([
                "type": .string("fine"),
                "amount": .number(amount),
                "currency": .string(currency)
            ])
        ])
    }
}
