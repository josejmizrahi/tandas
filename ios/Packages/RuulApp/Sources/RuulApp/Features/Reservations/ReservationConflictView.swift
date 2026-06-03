import SwiftUI
import RuulCore

/// F.9 — resolver un conflicto de reservación: el admin elige al ganador;
/// el backend rechaza al perdedor y aprueba al ganador. También se puede
/// escalar a una decisión votada (F.10).
public struct ReservationConflictView: View {
    let conflict: ReservationConflict
    let resource: Resource
    let context: AppContext
    let store: ReservationsStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var isShowingEscalate = false

    public init(
        conflict: ReservationConflict,
        resource: Resource,
        context: AppContext,
        store: ReservationsStore,
        container: DependencyContainer
    ) {
        self.conflict = conflict
        self.resource = resource
        self.context = context
        self.store = store
        self.container = container
    }

    private var reservationA: Reservation? { store.reservation(byId: conflict.reservationAId) }
    private var reservationB: Reservation? { store.reservation(byId: conflict.reservationBId) }

    public var body: some View {
        List {
            Section {
                Label {
                    Text("Dos solicitudes piden \(resource.displayName) en fechas que se traslapan. Elige quién se queda con la reservación.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
            }

            if let a = reservationA {
                reservationSection(a, title: "Solicitud A")
            }
            if let b = reservationB {
                reservationSection(b, title: "Solicitud B")
            }

            if store.canManage(in: context) && conflict.isOpen {
                Section {
                    NavigationLink {
                        CreateDecisionView(
                            context: context,
                            container: container,
                            prefilledTitle: "¿Quién se queda con \(resource.displayName)?",
                            prefilledType: .reservationDispute,
                            conflictReference: conflict.id
                        )
                    } label: {
                        Label("Escalar a votación", systemImage: "checkmark.seal")
                    }
                } footer: {
                    Text("Si prefieren decidirlo entre todos, crea una decisión y que el contexto vote.")
                }
            }
        }
        .navigationTitle("Conflicto")
        .navigationBarTitleDisplayMode(.inline)
        .actionErrorAlert(runner)
    }

    @ViewBuilder
    private func reservationSection(_ reservation: Reservation, title: String) -> some View {
        let requesterName = store.displayName(for: reservation.reservedForActorId ?? reservation.requestedByActorId)

        Section(title) {
            HStack(spacing: 12) {
                ActorInitialsView(name: requesterName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(requesterName)
                    Text("\(reservation.startsAt.formatted(date: .abbreviated, time: .omitted)) → \(reservation.endsAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(reservation.statusLabel, color: reservation.isActive ? .green : .orange)
            }

            if conflict.isOpen && store.canManage(in: context) && reservation.isPending {
                Button {
                    Task { await resolve(winner: reservation) }
                } label: {
                    Label("Darle la reservación a \(requesterName)", systemImage: "checkmark.circle.fill")
                }
                .disabled(runner.isRunning)
            }
        }
    }

    private func resolve(winner: Reservation) async {
        let success = await runner.run {
            try await store.resolveConflict(
                conflictId: conflict.id,
                winnerReservationId: winner.id,
                resourceId: resource.id,
                context: context
            )
        }
        if success { dismiss() }
    }
}

#Preview("Conflicto") {
    NavigationStack {
        ReservationConflictView(
            conflict: ReservationConflict(
                id: UUID(),
                resourceId: MockRuulRPCClient.DemoIds.casaValle,
                reservationAId: UUID(),
                reservationBId: UUID()
            ),
            resource: Resource(
                id: MockRuulRPCClient.DemoIds.casaValle,
                resourceType: "house",
                displayName: "Casa Valle"
            ),
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.familia,
                kind: .collective,
                subtype: "family",
                displayName: "Familia Mizrahi",
                roles: ["admin"]
            ),
            store: ReservationsStore(rpc: MockRuulRPCClient.demo(), previewReservations: [], permissions: MockRuulRPCClient.allPermissions),
            container: .demo()
        )
    }
}
