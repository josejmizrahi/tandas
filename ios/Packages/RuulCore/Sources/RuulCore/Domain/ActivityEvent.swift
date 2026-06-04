import Foundation

/// Un evento del log de actividad (`list_activity().activity[]` /
/// fila de `activity_events`).
public struct ActivityEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let eventType: String
    public let actorId: UUID?
    public let subjectType: String?
    public let subjectId: UUID?
    public let payload: JSONValue?
    public let resourceId: UUID?
    public let decisionId: UUID?
    public let obligationId: UUID?
    public let occurredAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case eventType = "event_type"
        case actorId = "actor_id"
        case subjectType = "subject_type"
        case subjectId = "subject_id"
        case payload
        case resourceId = "resource_id"
        case decisionId = "decision_id"
        case obligationId = "obligation_id"
        case occurredAt = "occurred_at"
    }

    public init(
        id: UUID,
        eventType: String,
        actorId: UUID? = nil,
        subjectType: String? = nil,
        subjectId: UUID? = nil,
        payload: JSONValue? = nil,
        resourceId: UUID? = nil,
        decisionId: UUID? = nil,
        obligationId: UUID? = nil,
        occurredAt: Date? = nil
    ) {
        self.id = id
        self.eventType = eventType
        self.actorId = actorId
        self.subjectType = subjectType
        self.subjectId = subjectId
        self.payload = payload
        self.resourceId = resourceId
        self.decisionId = decisionId
        self.obligationId = obligationId
        self.occurredAt = occurredAt
    }

    /// `true` cuando el evento lo generó el sistema (rule engine, conflictos).
    public var isSystemGenerated: Bool {
        payload?["system"]?.boolValue ?? false
    }

    /// Dominio del evento (`expense.recorded` → `expense`).
    public var domain: String {
        String(eventType.split(separator: ".").first ?? "")
    }

    /// Descripción legible en español del tipo de evento.
    public var typeLabel: String {
        switch eventType {
        case "context.created": return "Contexto creado"
        case "context.updated": return "Contexto actualizado"
        case "invite.created": return "Invitación creada"
        case "invite.revoked": return "Invitación cancelada"
        case "membership.joined", "member.joined": return "Se unió al contexto"
        case "membership.invited", "member.invited": return "Miembro invitado"
        case "membership.removed", "member.removed": return "Miembro removido"
        case "membership.left", "member.left": return "Salió del contexto"
        case "resource.created": return "Nuevo recurso"
        case "resource.updated": return "Recurso actualizado"
        case "resource.transferred": return "Recurso transferido"
        case "right.granted": return "Derecho otorgado"
        case "right.revoked": return "Derecho revocado"
        case "event.created", "calendar_event.created": return "Nuevo evento"
        case "event.rsvp", "event.rsvp_updated": return "RSVP actualizado"
        case "event.checked_in": return "Check-in"
        case "event.participation_cancelled": return "Asistencia cancelada"
        case "event.closed", "calendar_event.closed": return "Evento cerrado"
        case "reservation.requested": return "Nueva reservación"
        case "reservation.approved": return "Reservación aprobada"
        case "reservation.confirmed": return "Reservación confirmada"
        case "reservation.cancelled": return "Reservación cancelada"
        case "reservation.conflict_detected": return "Conflicto de reservación"
        case "reservation.conflict_resolved": return "Conflicto resuelto"
        case "decision.created": return "Nueva decisión"
        case "decision.vote_cast", "vote.cast": return "Nuevo voto"
        case "decision.option_added", "decision.option_created": return "Opción agregada"
        case "decision.closed": return "Decisión cerrada"
        case "decision.approved": return "Decisión aprobada"
        case "decision.rejected": return "Decisión rechazada"
        case "decision.executed": return "Decisión ejecutada"
        case "rule.created": return "Nueva regla"
        case "rule.evaluated": return "Regla evaluada"
        case "obligation.created": return "Nueva obligación"
        case "obligation.completed", "obligation.fulfilled": return "Obligación cumplida"
        case "obligation.settled", "obligation.paid": return "Obligación pagada"
        case "obligation.cancelled": return "Obligación cancelada"
        case "obligation.disputed": return "Obligación disputada"
        case "obligation.forgiven": return "Obligación perdonada"
        case "fine.created": return "Multa generada"
        case "expense.recorded": return "Nuevo gasto"
        case "split.generated": return "Reparto generado"
        case "game_result.recorded": return "Resultado de juego"
        case "settlement.generated": return "Liquidación generada"
        case "settlement.paid": return "Pago de liquidación"
        case "document.created", "document.registered": return "Nuevo documento"
        case "subscription.created", "subscription.activated": return "Nueva suscripción"
        case "trust.added": return "Confianza declarada"
        case "trust.removed": return "Confianza retirada"
        default:
            // Fallback humano: "expense.recorded" → "Expense recorded".
            let cleaned = eventType
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
    }

    /// F.NAV.9 — Título contextualizado que extrae datos del `payload` para
    /// componer una línea natural ("Nuevo gasto · MXN 1,300"). Si no hay
    /// payload útil, retorna `typeLabel` plano. NUNCA expone keys técnicos.
    public func friendlyTitle(currentActorId: UUID? = nil) -> String {
        let label = typeLabel
        guard let payload else { return label }

        // Subject title — sirve para decisiones / eventos / recursos / obligaciones.
        if let title = payload["title"]?.stringValue, !title.isEmpty {
            return "\(label) · \(title)"
        }
        // Monto + moneda — sirve para expense / fine / obligation / settlement.
        if let amount = payload["amount"]?.numberValue {
            let currency = payload["currency"]?.stringValue ?? ""
            let formatted = formatAmount(amount, currency: currency)
            return "\(label) · \(formatted)"
        }
        return label
    }

    private func formatAmount(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.isEmpty ? "MXN" : currency
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: amount)) ?? "\(currency) \(Int(amount))"
    }

    /// SF Symbol por dominio.
    public var symbolName: String {
        switch domain {
        case "context": return "person.3.fill"
        case "membership", "member", "invite": return "person.badge.plus"
        case "resource", "right": return "shippingbox.fill"
        case "event", "calendar_event": return "calendar"
        case "reservation": return "calendar.badge.clock"
        case "decision": return "checkmark.seal.fill"
        case "rule": return "ruler.fill"
        case "obligation", "fine": return "exclamationmark.circle.fill"
        case "expense", "split", "game_result", "settlement": return "dollarsign.circle.fill"
        case "document": return "doc.fill"
        default: return "circle.fill"
        }
    }
}

/// Respuesta completa de `list_activity()`.
public struct ActivityPage: Sendable, Equatable {
    public let contextActorId: UUID
    public let activity: [ActivityEvent]

    public init(contextActorId: UUID, activity: [ActivityEvent]) {
        self.contextActorId = contextActorId
        self.activity = activity
    }
}

extension ActivityPage: Decodable {
    enum CodingKeys: String, CodingKey {
        case contextActorId = "context_actor_id"
        case activity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextActorId = try c.decode(UUID.self, forKey: .contextActorId)
        self.activity = try c.decodeIfPresent([ActivityEvent].self, forKey: .activity) ?? []
    }
}
