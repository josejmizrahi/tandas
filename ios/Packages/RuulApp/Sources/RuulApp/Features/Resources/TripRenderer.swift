import SwiftUI
import RuulCore

/// R.10.F.7 — `class_key="trip"` renderer (viaje familiar / road trip /
/// business trip / vacaciones).
///
/// Migra `case "trip":` inline en `ResourceDetailV2InfoSection` al protocolo
/// polimórfico. Cero cambio visual respecto al monolito previo.
///
/// Sections específicas pendientes (requieren filtering del orquestador):
///   - Itinerario: linkedEvents filtrados al rango [start_date, end_date]
///   - Gastos del viaje: linkedObligations filtrados al alcance del trip
/// Se evalúan en F.10 cuando se firme la opción A/B de Linked* delegation.
@MainActor
struct TripRenderer: ResourceSubtypeRenderer {
    static let classKey = "trip"

    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(
            Group {
                if let location = d.resource.locationText, !location.isEmpty {
                    LabeledContent("Destino", value: location)
                }
                if let startDate = d.resource.metadataString("start_date") {
                    LabeledContent("Inicio", value: startDate)
                }
                if let endDate = d.resource.metadataString("end_date") {
                    LabeledContent("Fin", value: endDate)
                }
            }
        )
    }

    /// R.10.F.f Hero subtitle — rango de fechas inicio → fin cuando ambas
    /// están definidas (formato corto). Critical-info para viajes.
    func heroSubtitle(_ d: ResourceDetailDescriptor) -> AnyView? {
        guard
            let startStr = d.resource.metadataString("start_date"),
            let endStr = d.resource.metadataString("end_date")
        else { return nil }
        return AnyView(
            Text("\(startStr) → \(endStr)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Text.secondary)
                .monospacedDigit()
        )
    }
}
