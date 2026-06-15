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
        // Placa intencionalmente NO va aquí — vive prominente en `heroSubtitle`
        // (E.4 dedup). VIN sí queda (less scanned, no critical identity).
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

    /// R.10.F.f Hero subtitle — placa monospaced. Identity field para vehículos
    /// (es lo primero que checas).
    func heroSubtitle(_ d: ResourceDetailDescriptor) -> AnyView {
        guard let plate = d.resource.metadataString("license_plate") else {
            return AnyView(EmptyView())
        }
        return AnyView(
            Text(plate)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(Theme.Text.secondary)
        )
    }
}
