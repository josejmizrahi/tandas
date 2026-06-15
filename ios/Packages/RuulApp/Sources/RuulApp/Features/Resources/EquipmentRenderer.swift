import SwiftUI
import RuulCore

/// R.10.F.5 — `class_key="equipment"` renderer (electrónicos / herramientas /
/// muebles / electrodomésticos / inventario).
///
/// Migra `case "equipment":` inline en `ResourceDetailV2InfoSection` al
/// protocolo polimórfico. Cero cambio visual respecto al monolito previo.
@MainActor
struct EquipmentRenderer: ResourceSubtypeRenderer {
    static let classKey = "equipment"

    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(
            Group {
                if let make = d.resource.metadataString("make"),
                   let model = d.resource.metadataString("model") {
                    LabeledContent("Modelo", value: "\(make) \(model)")
                }
                if let serial = d.resource.metadataString("serial_number") {
                    LabeledContent("Serie") {
                        Text(serial)
                            .font(.callout.monospaced())
                    }
                }
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
