import SwiftUI
import RuulCore

/// Lista todas las reservaciones del contexto (cross-resource) usando
/// `list_context_reservations`. No carga conflictos (sólo viven por recurso).
/// Las swipe actions reusan los mismos paths de la lista por-recurso.
public struct ContextReservationsView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ReservationsStore

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: ReservationsStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.loadByContext(context: context) }
                }

            case .loaded:
                loadedContent
            }
        }
        .navigationTitle("Reservaciones")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadByContext(context: context)
        }
        .refreshable {
            await store.loadByContext(context: context)
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.loadByContext(context: context)
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if store.upcoming.isEmpty && store.pastOrInactive.isEmpty {
            EmptyStateView(
                symbolName: "calendar.badge.clock",
                title: "Sin reservaciones",
                message: "Cuando alguien reserve un recurso del contexto, aparecerá aquí."
            )
        } else {
            List {
                if !store.upcoming.isEmpty {
                    Section("Próximas") {
                        ForEach(store.upcoming) { reservation in
                            row(reservation)
                        }
                    }
                }

                if !store.pastOrInactive.isEmpty {
                    Section("Anteriores") {
                        ForEach(store.pastOrInactive) { reservation in
                            row(reservation)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ reservation: Reservation) -> some View {
        // R.5W.P1 — tap → push al Resource Detail (antes el row era inerte;
        // el resto del Detail pattern ya empuja a su propia vista).
        NavigationLink {
            ResourceDetailViewV2(
                resourceId: reservation.resourceId,
                context: context,
                container: container
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.resourceName(for: reservation.resourceId) ?? "Recurso")
                        .font(.body.weight(.medium))
                    Text(rangeAndOwner(reservation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(reservation.statusLabel, color: Theme.Status.reservation(reservation.status))
            }
        }
        .swipeActions(edge: .trailing) {
            swipeActions(reservation)
        }
    }

    @ViewBuilder
    private func swipeActions(_ reservation: Reservation) -> some View {
        let isMine = reservation.requestedByActorId == container.currentActorStore.actorId
            || reservation.reservedForActorId == container.currentActorStore.actorId

        if store.canManage(in: context) && reservation.isPending {
            Button("Aprobar") {
                Task { await runAndReload { try await container.rpc.approveReservation(reservationId: reservation.id) } }
            }
            .tint(.green)
        }
        if store.canManage(in: context) && reservation.status == "approved" {
            Button("Confirmar") {
                Task { await runAndReload { try await container.rpc.confirmReservation(reservationId: reservation.id) } }
            }
            .tint(.blue)
        }
        if (isMine || store.canManage(in: context)) && (reservation.isPending || reservation.isActive) {
            Button("Cancelar", role: .destructive) {
                Task { await runAndReload { try await container.rpc.cancelReservation(reservationId: reservation.id) } }
            }
        }
    }

    private func runAndReload(_ action: () async throws -> Void) async {
        try? await action()
        await store.loadByContext(context: context)
    }

    private func rangeAndOwner(_ reservation: Reservation) -> String {
        let start = reservation.startsAt.formatted(date: .abbreviated, time: .omitted)
        let end = reservation.endsAt.formatted(date: .abbreviated, time: .omitted)
        let who = store.displayName(for: reservation.reservedForActorId ?? reservation.requestedByActorId)
        return "\(who) · \(start) → \(end)"
    }
}

#Preview("Reservaciones del contexto") {
    NavigationStack {
        ContextReservationsView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.familia,
                kind: .collective,
                subtype: "family",
                displayName: "Familia Mizrahi",
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
