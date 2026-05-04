import Foundation

public enum ResourceType: String, Codable, Sendable, Hashable, CaseIterable {
    /// V1 — the only implemented type. Lives in `events` table; queried via
    /// `events_view` which projects to a Resource shape.
    case event

    // V2+ types — declared here so the platform model is V4-ready. Edge
    // function rule engine ignores types it doesn't know about; Swift code
    // throws a clear error if it sees one before the matching template
    // ships.
    case slot          // boleto, cupo, lugar — Fase 2 (Recurso compartido)
    case fund          // caja, fondo común
    case position      // lugar en rotación
    case asset         // palco, cabaña — Fase 2
    case contribution  // aporte a tanda — Fase 3
}
