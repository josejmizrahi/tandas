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
    /// R.2S.5 — scope universal: `context` | `event_type` | `event` | `resource_type` |
    /// `resource` | `decision` | `reservation` | `membership` | `money_transaction` |
    /// `obligation` | `custom`. Nil = legacy (= 'context').
    public let targetScope: String?
    /// R.2S.5 — filtro jsonb `{key: value}` evaluado contra el payload del trigger.
    /// `{}` o nil matchea cualquier payload.
    public let targetFilter: JSONValue?
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
        case targetScope = "target_scope"
        case targetFilter = "target_filter"
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
        targetScope: String? = nil,
        targetFilter: JSONValue? = nil,
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
        self.targetScope = targetScope
        self.targetFilter = targetFilter
        self.createdAt = createdAt
    }

    public var isActive: Bool { status == "active" }

    /// Scope tipado si el backend lo conoce (con fallback a `context` si nil/legacy).
    public var scope: RuleTargetScope { RuleTargetScope(rawValue: targetScope ?? "context") ?? .context }

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

/// Triggers de reglas que el wizard de F.8 soporta. R.2S.5 expandió la lista
/// con triggers de dominios no-evento (reservaciones, gastos).
public enum RuleTrigger: String, Codable, Sendable, CaseIterable, Identifiable {
    case checkedIn = "event.checked_in"
    case participationCancelled = "event.participation_cancelled"
    case reservationCancelled = "reservation.cancelled"
    // R.6.E fix 2026-06-08: el activity_event real emitido por `record_expense` es
    // `expense.recorded` (sin prefijo "money."). Reglas creadas con la raw value
    // anterior nunca disparaban porque el catálogo no contiene `money.expense_recorded`.
    case moneyExpenseRecorded = "expense.recorded"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .checkedIn: return "Al hacer check-in"
        case .participationCancelled: return "Al cancelar asistencia"
        case .reservationCancelled: return "Al cancelar una reservación"
        case .moneyExpenseRecorded: return "Al registrar un gasto"
        }
    }
}

/// R.2S.5 — scope de aplicación de una regla. El backend evalúa la regla solo
/// cuando el trigger emite un evento del dominio matching del scope.
public enum RuleTargetScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case context, eventType = "event_type", event
    case resourceType = "resource_type", resource
    case decision, reservation, membership
    case moneyTransaction = "money_transaction"
    case obligation, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .context: return "Todo el contexto"
        case .eventType: return "Tipo de evento"
        case .event: return "Un evento puntual"
        case .resourceType: return "Tipo de recurso"
        case .resource: return "Un recurso puntual"
        case .decision: return "Decisiones"
        case .reservation: return "Reservaciones"
        case .membership: return "Miembros"
        case .moneyTransaction: return "Transacciones de dinero"
        case .obligation: return "Obligaciones"
        case .custom: return "Personalizado"
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

/// R.2S.5 — builders para condition_tree de los nuevos triggers (reservación/gasto).
public enum RuleConditionBuilderR2S5 {
    /// `hours_before < threshold` — para `reservation.cancelled` (cancelación tardía).
    public static func cancelledLessHoursBefore(_ hours: Double) -> JSONValue {
        .object([
            "op": .string("<"),
            "field": .string("hours_before"),
            "value": .number(hours)
        ])
    }

    /// `amount > threshold` — para `money.expense_recorded` (alerta de gasto alto).
    public static func amountGreaterThan(_ amount: Double) -> JSONValue {
        .object([
            "op": .string(">"),
            "field": .string("amount"),
            "value": .number(amount)
        ])
    }
}

/// R.2S.5 — builders de `target_filter` por scope.
public enum RuleTargetFilterBuilder {
    /// Filtra por un recurso específico (target_scope=resource).
    public static func resource(_ id: UUID) -> JSONValue {
        .object(["resource_id": .string(id.uuidString)])
    }

    /// Filtra por tipo de recurso (target_scope=resource_type).
    public static func resourceType(_ rawType: String) -> JSONValue {
        .object(["resource_type": .string(rawType)])
    }

    /// Filtra por currency (target_scope=money_transaction).
    public static func currency(_ code: String) -> JSONValue {
        .object(["currency": .string(code)])
    }
}
