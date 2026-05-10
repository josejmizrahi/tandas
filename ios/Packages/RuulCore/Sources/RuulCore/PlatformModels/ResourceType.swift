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
