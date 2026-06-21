import SwiftUI
import RuulCore

// MARK: - R.2T Recurso reservado (Section dedicada — link a Reserva via source_event_id)
//
// Extraído mecánicamente de `EventDetailView.swift` (split por tamaño del
// archivo).

/// Muestra los recursos reservados para este evento (caso Mundial: Palco
/// para los 5 partidos). Si no hay reservaciones linkeadas, no renderiza.
/// Tap → push ResourceDetailViewV2 (donde el usuario ya ve detalles del
/// recurso + linkedEvents de vuelta).
struct EventDetailLinkedReservationsSection: View {
    let linkedReservations: [Reservation]
    let linkedResourceNames: [UUID: String]
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        if !linkedReservations.isEmpty {
            Section {
                ForEach(linkedReservations) { reservation in
                    NavigationLink {
                        ResourceDetailViewV2(
                            resourceId: reservation.resourceId,
                            context: context,
                            container: container
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(linkedResourceNames[reservation.resourceId] ?? "Cosa")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Theme.Text.primary)
                                    .lineLimit(1)
                                Text(linkedReservationRange(reservation))
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "calendar.badge.checkmark")
                                .foregroundStyle(linkedReservationTint(reservation.status))
                        }
                    }
                }
            } header: {
                Text(linkedReservations.count == 1 ? "Cosa reservada" : "Cosas reservadas (\(linkedReservations.count))")
            } footer: {
                if let single = linkedReservations.first, linkedReservations.count == 1 {
                    Text(linkedReservationStatusLabel(single.status))
                }
            }
        }
    }

    private func linkedReservationRange(_ r: Reservation) -> String {
        let start = r.startsAt.formatted(date: .abbreviated, time: .shortened)
        let end = r.endsAt.formatted(date: .abbreviated, time: .shortened)
        return "\(start) – \(end)"
    }

    private func linkedReservationStatusLabel(_ status: String) -> String {
        switch status {
        case "requested": return "Solicitada — pendiente de aprobación."
        case "approved":  return "Aprobada — pendiente de confirmar."
        case "confirmed": return "Confirmada para el evento."
        case "cancelled": return "Cancelada."
        case "completed": return "Completada."
        case "rejected":  return "Rechazada."
        default:          return "Estado: \(status)."
        }
    }

    private func linkedReservationTint(_ status: String) -> Color {
        switch status {
        case "confirmed": return Theme.Tint.success
        case "approved":  return Theme.Tint.info
        case "requested": return Theme.Tint.warning
        case "cancelled", "rejected": return Theme.Tint.critical
        default: return Theme.Tint.primary
        }
    }
}
