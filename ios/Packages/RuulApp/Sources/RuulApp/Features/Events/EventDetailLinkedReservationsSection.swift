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
///
/// R.15 — swipe actions inline "Aprobar" (requested) / "Confirmar" (approved)
/// para quien tiene `reservations.manage`, mismos paths que
/// `ContextReservationsView`. Tras la acción, el padre recarga vía `onChanged`.
struct EventDetailLinkedReservationsSection: View {
    let linkedReservations: [Reservation]
    let linkedResourceNames: [UUID: String]
    let context: AppContext
    let container: DependencyContainer
    let store: EventDetailStore
    /// Recarga las reservaciones linkeadas en el padre (dueño del @State).
    let onChanged: () async -> Void

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
                    .swipeActions(edge: .trailing) {
                        reservationSwipeActions(reservation)
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

    /// Mismo gate que `ReservationsStore.canManage(in:)` — replica porque esta
    /// section vive del `EventDetailStore` (que ya trae `my_permissions` del
    /// mismo `context_summary`).
    private var canManageReservations: Bool {
        context.isPersonal || store.myPermissions.contains("reservations.manage")
    }

    @ViewBuilder
    private func reservationSwipeActions(_ reservation: Reservation) -> some View {
        if canManageReservations && reservation.isPending {
            Button("Aprobar") {
                Task { await runAndReload { try await container.rpc.approveReservation(reservationId: reservation.id) } }
            }
            .tint(.green)
        }
        if canManageReservations && reservation.status == "approved" {
            Button("Confirmar") {
                Task { await runAndReload { try await container.rpc.confirmReservation(reservationId: reservation.id) } }
            }
            .tint(.blue)
        }
    }

    private func runAndReload(_ action: () async throws -> Void) async {
        try? await action()
        await onChanged()
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
