import SwiftUI
import RuulCore

/// R.10.F.4 — `class_key="vehicle"` renderer (auto / moto / barco / bicicleta).
///
/// Migra `case "vehicle":` inline en `ResourceDetailV2InfoSection` al
/// protocolo polimórfico. Cero cambio visual respecto al monolito previo.
///
/// Sections específicas pendientes (capability-gated, requieren backend
/// support):
///   - Mantenimientos (capability `maintainable`) → próximos servicios
///   - Uso/Asignación (capability `assignable`) → driver asignado + kilometraje
/// Se evalúan en F.10 cuando el descriptor exponga el shape (no hay metric
/// `mileage` ni linked maintenance events hoy).
@MainActor
struct VehicleRenderer: ResourceSubtypeRenderer {
    static let classKey = "vehicle"

    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(
            Group {
                if let make = d.resource.metadataString("make"),
                   let model = d.resource.metadataString("model") {
                    LabeledContent("Modelo", value: "\(make) \(model)")
                } else if let model = d.resource.metadataString("model") {
                    LabeledContent("Modelo", value: model)
                }
                if let year = d.resource.metadataString("year") {
                    LabeledContent("Año", value: year)
                }
                if let plate = d.resource.metadataString("license_plate") {
                    LabeledContent("Placa") {
                        Text(plate)
                            .font(.callout.monospaced())
                    }
                }
                if let vin = d.resource.metadataString("vin") {
                    LabeledContent("VIN") {
                        Text(vin)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
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
