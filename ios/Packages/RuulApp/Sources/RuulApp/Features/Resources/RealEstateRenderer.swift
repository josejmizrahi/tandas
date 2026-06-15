import SwiftUI
import RuulCore

/// R.10.F.3 — `class_key="real_estate"` renderer (casa / depto / oficina /
/// lote / terreno).
///
/// Migra `case "real_estate":` inline en `ResourceDetailV2InfoSection` al
/// protocolo polimórfico. Cero cambio visual respecto al monolito previo.
///
/// Las Sections específicas del subtype (Reservaciones header pattern E.5 +
/// Calendario drill) hoy viven en `ResourceDetailV2SectionsSection` consumiendo
/// `descriptor.sections` (reservations + calendar). Esa sección sigue
/// funcionando — el renderer no toca la navegación hasta que F.10 reorganice
/// el body order per subtype.
@MainActor
struct RealEstateRenderer: ResourceSubtypeRenderer {
    static let classKey = "real_estate"

    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(
            Group {
                if let location = d.resource.locationText, !location.isEmpty {
                    LabeledContent("Ubicación", value: location)
                }
                if let area = d.resource.metadataString("area_sqm") {
                    LabeledContent("Superficie", value: "\(area) m²")
                }
                if let bedrooms = d.resource.metadataString("bedrooms") {
                    LabeledContent("Habitaciones", value: bedrooms)
                }
                if let bathrooms = d.resource.metadataString("bathrooms") {
                    LabeledContent("Baños", value: bathrooms)
                }
                if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
                    LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
                }
            }
        )
    }
}
