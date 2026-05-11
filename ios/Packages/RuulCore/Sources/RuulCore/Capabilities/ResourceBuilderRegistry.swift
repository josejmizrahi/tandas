import Foundation

/// Maps `ResourceType` → concrete `ResourceBuilder` instance.
///
/// Drives the universal ResourceWizard's type picker and routes the
/// final submit to the correct builder. Types without a registered
/// builder appear in the picker as disabled "Próximamente" cards so
/// the user sees what's coming without being able to act on it.
///
/// Registry is immutable at runtime — adding a new resource type means
/// shipping a new builder + adding its entry here.
@MainActor
public final class ResourceBuilderRegistry {
    private let builders: [String: any ResourceBuilder]
    public init(builders: [any ResourceBuilder]) {
        var map: [String: any ResourceBuilder] = [:]
        for b in builders { map[Self.key(for: b.resourceType)] = b }
        self.builders = map
    }

    public func builder(for type: ResourceType) -> (any ResourceBuilder)? {
        builders[Self.key(for: type)]
    }

    public var allBuilders: [any ResourceBuilder] {
        Array(builders.values).sorted { $0.displayName < $1.displayName }
    }

    /// Resource types the wizard knows how to surface — both builders
    /// available NOW and types we want to tease in the picker.
    /// The wizard renders builders' cards enabled and the rest as
    /// "próximamente" placeholders.
    public static let surfaceTypes: [ResourceType] = [
        .event, .asset, .slot, .fund, .contribution, .proposal
    ]

    public func isImplemented(_ type: ResourceType) -> Bool {
        builder(for: type) != nil
    }

    private static func key(for type: ResourceType) -> String {
        switch type {
        case .event:            return "event"
        case .slot:             return "slot"
        case .booking:          return "booking"
        case .fund:             return "fund"
        case .position:         return "position"
        case .assignment:       return "assignment"
        case .rotation:         return "rotation"
        case .asset:            return "asset"
        case .guestPass:        return "guest_pass"
        case .contribution:     return "contribution"
        case .proposal:         return "proposal"
        case .unknown(let raw): return raw
        }
    }

    /// Display metadata for types that don't yet have a builder. Used by
    /// the type picker to show "Próximamente" cards.
    public static func placeholderInfo(for type: ResourceType) -> (displayName: String, icon: String, summary: String)? {
        switch type {
        case .fund:
            return ("Fondo", "banknote", "Caja común para aportaciones y payouts.")
        case .contribution:
            return ("Aportación", "arrow.up.bin", "Aporte recurrente o único a un fondo.")
        case .proposal:
            return ("Propuesta", "checklist", "Propuesta abierta a votación.")
        case .booking:
            return ("Reserva", "calendar.badge.checkmark", "Reclamar un slot.")
        case .guestPass:
            return ("Invitado", "person.crop.circle.badge.plus", "Acceso temporal para alguien fuera del grupo.")
        case .position:
            return ("Posición", "person.line.dotted.person", "Lugar en una rotación.")
        case .assignment:
            return ("Tarea", "checkmark.circle.badge.questionmark", "Responsabilidad asignada a alguien.")
        case .rotation:
            return ("Rotación", "arrow.triangle.2.circlepath", "Orden rotativo entre miembros.")
        default:
            return nil
        }
    }
}
