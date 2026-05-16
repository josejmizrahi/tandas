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
        .event, .asset, .slot, .fund, .right, .space
    ]

    public func isImplemented(_ type: ResourceType) -> Bool {
        builder(for: type) != nil
    }

    private static func key(for type: ResourceType) -> String {
        switch type {
        case .event:            return "event"
        case .fund:             return "fund"
        case .asset:            return "asset"
        case .space:            return "space"
        case .slot:             return "slot"
        case .right:            return "right"
        case .unknown(let raw): return raw
        }
    }

    /// Display metadata for types that don't yet have a builder. Used by
    /// the type picker to show "Próximamente" cards.
    public static func placeholderInfo(for type: ResourceType) -> (displayName: String, icon: String, summary: String)? {
        switch type {
        case .slot:
            return ("Turno", "ticket", "Ventana de uso de un activo. Crea un activo primero.")
        case .fund:
            return ("Fondo", "banknote", "Caja común para aportaciones y payouts.")
        case .space:
            return ("Espacio", "mappin.and.ellipse", "Lugar reservable: salón, cancha, sala.")
        default:
            return nil
        }
    }
}
