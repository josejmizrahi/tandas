import SwiftUI
import RuulCore

/// R.10.B (R.10.F.1) — Polymorphic renderer per `class_key` for ResourceDetail.
///
/// Reemplaza el `switch d.class.classKey` que vivía inline en
/// `ResourceDetailV2InfoSection`. Cada conformer renderiza una rebanada del
/// body del Detail que varía por clase. Slice F.1 introduce el protocolo, el
/// registry y `GenericRenderer` solo — el resto de los cases sigue inline en
/// `ResourceDetailV2Info.swift` hasta que F.2–F.9 los migren uno por uno.
///
/// Doctrina:
///   - F.2X intent-first: los renderers NO branchean por type para acciones,
///     solo para shape visual (rows + sections informativas).
///   - R.5V native-first: AnyView es solo el adapter entre el protocolo y
///     `Section { ... }`. El contenido sigue siendo `LabeledContent` / `Label`.
///   - `any ResourceSubtypeRenderer` requiere AnyView porque protocols con
///     `@ViewBuilder` opaco no son existenciables sin primary associated types
///     por método (Swift 6).
@MainActor
protocol ResourceSubtypeRenderer {
    /// Class key con la que matchea el registry (e.g. "financial", "real_estate").
    static var classKey: String { get }

    /// Filas dentro de la Section "Información" — `LabeledContent` per campo.
    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView

    /// Fila bajo el título en el Hero (balance grande / placa monospaced /
    /// destino + fechas). Default: `EmptyView`. Se renderiza solo cuando el
    /// renderer aporta info crítica del subtype.
    func heroSubtitle(_ d: ResourceDetailDescriptor) -> AnyView

    /// Sections específicas del subtype, entre Info y los Linked* genéricos.
    /// Default: `EmptyView`.
    func subtypeSpecificSections(
        _ d: ResourceDetailDescriptor,
        context: AppContext,
        container: DependencyContainer
    ) -> AnyView
}

extension ResourceSubtypeRenderer {
    func heroSubtitle(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(EmptyView())
    }

    func subtypeSpecificSections(
        _ d: ResourceDetailDescriptor,
        context: AppContext,
        container: DependencyContainer
    ) -> AnyView {
        AnyView(EmptyView())
    }
}

/// Registry de renderers por `class_key`. Default fallback = `GenericRenderer`.
/// R.10.F.2–F.9 agregan cases conforme cada renderer ship.
@MainActor
enum ResourceSubtypeRegistry {
    static func renderer(for classKey: String) -> any ResourceSubtypeRenderer {
        switch classKey {
        case "financial":    return FinancialRenderer()
        case "real_estate":  return RealEstateRenderer()
        case "vehicle":      return VehicleRenderer()
        case "equipment":    return EquipmentRenderer()
        case "digital_asset": return DigitalAssetRenderer()
        case "document":     return DocumentRenderer()
        case "trip":         return TripRenderer()
        case "space":        return SpaceRenderer()
        // F.8 pivot (2026-06-15) — `pool` y `right` no aplican al ResourceDetail:
        // `pool_accounts` viven en su propia tabla con `pool_account_detail`
        // RPC → `PoolDetailView`; `resource_rights` son relationships
        // actor↔resource, no recursos en sí. Backend audit verificó 0 resources
        // reales con class_key='right'. Si aparecen en el futuro, GenericRenderer
        // los cubre.
        default: return GenericRenderer()
        }
    }
}

/// Catch-all renderer. Espejo exacto de `genericFields(_:)` legacy del Info
/// section. Sin behavior change.
@MainActor
struct GenericRenderer: ResourceSubtypeRenderer {
    static let classKey = "generic"

    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(
            Group {
                LabeledContent("Categoría", value: d.class.displayName)
                if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
                    LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
                }
            }
        )
    }
}
