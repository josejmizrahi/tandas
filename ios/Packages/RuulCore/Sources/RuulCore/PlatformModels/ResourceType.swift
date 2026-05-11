import Foundation

// @codegen:enum
public enum ResourceType: Codable, Sendable, Hashable {
    /// V1 — the only implemented type. Lives in `events` table; queried via
    /// `events_view` which projects to a Resource shape.
    case event

    // V2+ types — declared here so the platform model is V4-ready. Edge
    // function rule engine ignores types it doesn't know about; Swift code
    // throws a clear error if it sees one before the matching template
    // ships.

    /// Boleto, cupo, lugar — Fase 2 (shared_resource template).
    /// Una ventana de uso de un Asset.
    case slot
    /// Reserva de un Slot por un Member — Fase 2.
    case booking
    /// Caja, fondo común — Fase 3.
    case fund
    /// Lugar en rotación.
    case position
    /// "A quién le toca" — Fase 2 (rotating_position module).
    case assignment
    /// Orden rotativo sobre Members o Resources — Fase 2.
    case rotation
    /// Palco, cabaña, casa — Fase 2 (recurso físico/digital compartido).
    case asset
    /// Invitado temporal con permisos limitados — Fase 2 (guest_pass module).
    case guestPass
    /// Aporte a tanda — Fase 3.
    case contribution
    /// Cambio sugerido a cualquier Resource/Rule/Policy — Fase 5.
    case proposal

    case unknown(String)
}

extension ResourceType {
    /// Human-facing label for this resource type, in the singular. Single
    /// source of truth — view layers (HomeView, GroupTabView,
    /// ResourceDetailSheet, DetailSummaryView) must read from here instead
    /// of inlining their own switch. Phrasing leans colloquial Mexican
    /// Spanish to match the social register of the product, not the
    /// taxonomy used in code/migrations.
    public var humanLabel: String {
        switch self {
        case .event:        return "Evento"
        case .slot:         return "Turno"
        case .booking:      return "Reserva"
        case .fund:         return "Fondo"
        case .position:     return "Posición"
        case .assignment:   return "Encargo"
        case .rotation:     return "Rotación"
        case .asset:        return "Activo"
        case .guestPass:    return "Invitado"
        case .contribution: return "Cuota"
        case .proposal:     return "Propuesta"
        case .unknown(let raw): return raw
        }
    }

    /// Plural form of `humanLabel`. Used for section headers ("Tus turnos",
    /// "Tus cuotas") and counters. Keep parity with `humanLabel` when adding
    /// new cases.
    public var humanLabelPlural: String {
        switch self {
        case .event:        return "Eventos"
        case .slot:         return "Turnos"
        case .booking:      return "Reservas"
        case .fund:         return "Fondos"
        case .position:     return "Posiciones"
        case .assignment:   return "Encargos"
        case .rotation:     return "Rotaciones"
        case .asset:        return "Activos"
        case .guestPass:    return "Invitados"
        case .contribution: return "Cuotas"
        case .proposal:     return "Propuestas"
        case .unknown(let raw): return raw
        }
    }
}
