import SwiftUI
import RuulCore

/// R.10.F.8 — `class_key="space"` renderer (palco / sala / locker / espacio
/// genérico físico).
///
/// Hasta F.7 los recursos `space` caían a `GenericRenderer` y perdían el
/// campo crítico `location_text` (catalog hoy: 1 resource real "Palco —
/// Estadio Azteca"). Este renderer expone ubicación + valor estimado.
///
/// El subtype hoy es solo `generic_space` (catalog R.5A.B.0) — futuros
/// subtypes (sala_juegos / locker / cabina) heredarán esta shape salvo
/// que el catalog agregue metadata específica.
@MainActor
struct SpaceRenderer: ResourceSubtypeRenderer {
    static let classKey = "space"

    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(
            Group {
                if let location = d.resource.locationText, !location.isEmpty {
                    LabeledContent("Ubicación", value: location)
                }
                if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
                    LabeledContent("Valor estimado", value: value.compactCurrencyLabel(currency))
                }
            }
        )
    }
}
