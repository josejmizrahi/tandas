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

    /// boleto, cupo, lugar — Fase 2 (Recurso compartido)
    case slot
    /// caja, fondo común
    case fund
    /// lugar en rotación
    case position
    /// palco, cabaña — Fase 2
    case asset
    /// aporte a tanda — Fase 3
    case contribution

    case unknown(String)
}
