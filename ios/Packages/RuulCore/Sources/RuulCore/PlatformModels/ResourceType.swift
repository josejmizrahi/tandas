import Foundation

// @codegen:enum
//
// Canonical 6 resource types per `Plans/Active/Constitution.md` §1 art. 2.
// Cualquier subtype nuevo pasa el filtro ontológico (§13) antes de añadirse.
// El backend (Postgres) enforza estos 6 valores vía CHECK constraints en
// `resources.resource_type`, `resource_series.resource_type`,
// `group_policies.target_resource_type`, `rule_shapes.valid_resource_types`
// (migración 00147).
public enum ResourceType: Codable, Sendable, Hashable, CaseIterable {
    /// Ocurrencia temporal coordinada (cena, junta, partido, ceremonia).
    case event
    /// Pool monetario del grupo (cochinito, tanda, fondo común, presupuesto).
    case fund
    /// Objeto físico o digital compartido (palco, vehículo, doc, IP, contenido).
    case asset
    /// Lugar físico o virtual reservable (salón, cancha, sala, espacio común).
    case space
    /// Ventana de capacidad reservable (turno, slot horario, asiento).
    case slot
    /// Derecho/acceso compartido (membresía externa, equity, custodia, uso).
    case right

    /// Defensive case for forward/backward codec compatibility. Server CHECK
    /// constraints prevent this from ever arriving from canonical sources.
    case unknown(String)
}

extension ResourceType {
    /// The 6 canonical cases, excluding the defensive `unknown` case.
    /// `unknown` cannot participate in `allCases` because it carries an
    /// associated value; only concrete server values belong in exhaustive
    /// iteration (e.g., chrome lookups, capability resolution).
    public static var allCases: [ResourceType] {
        [.event, .fund, .asset, .space, .slot, .right]
    }
}

extension ResourceType {
    /// Human-facing label for this resource type, in the singular. Single
    /// source of truth — view layers (HomeView, ResourceDetailSheet,
    /// ResourceSummaryView, etc.) must read from here instead of
    /// inlining their own switch. Phrasing leans colloquial Mexican
    /// Spanish to match the social register of the product, not the
    /// taxonomy used in code/migrations.
    public var humanLabel: String {
        switch self {
        case .event:        return "Evento"
        case .fund:         return "Fondo"
        case .asset:        return "Activo"
        case .space:        return "Espacio"
        case .slot:         return "Turno"
        case .right:        return "Acceso"
        case .unknown(let raw): return raw
        }
    }

    /// Plural form of `humanLabel`. Used for section headers ("Tus turnos",
    /// "Tus fondos") and counters. Keep parity with `humanLabel` when adding
    /// new cases.
    public var humanLabelPlural: String {
        switch self {
        case .event:        return "Eventos"
        case .fund:         return "Fondos"
        case .asset:        return "Activos"
        case .space:        return "Espacios"
        case .slot:         return "Turnos"
        case .right:        return "Accesos"
        case .unknown(let raw): return raw
        }
    }

    /// Whether the user can toggle capabilities on/off for this resource
    /// Historical knob: pre-doctrine, the asset/fund/space/slot/right
    /// types let the user toggle their capability set in Settings. Today
    /// caps are auto-on at creation and never user-visible (no Governance
    /// tab). Kept as a stub for future per-type gating decisions; today
    /// it returns the same shape but is not consulted by any UI.
    public var capabilitiesAreUserManaged: Bool {
        switch self {
        case .event:        return false
        case .fund, .asset, .space, .slot, .right: return true
        case .unknown:      return false
        }
    }
}
