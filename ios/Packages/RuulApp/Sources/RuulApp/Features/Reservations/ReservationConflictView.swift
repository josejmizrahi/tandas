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
    /// R.2S — detail por reservación con `available_actions` canónicos del backend.
    @State private var detailA: ReservationDetail?
    @State private var detailB: ReservationDetail?

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

    /// R.2S — `resolve_conflict` aparece habilitado en CUALQUIERA de las dos
    /// reservaciones cuando el actor puede administrar.
    private var canResolve: Bool {
        (detailA?.can("resolve_conflict") ?? false) || (detailB?.can("resolve_conflict") ?? false)
    }

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
                reservationSection(a, detail: detailA, title: "Solicitud A")
            }
            if let b = reservationB {
                reservationSection(b, detail: detailB, title: "Solicitud B")
            }

            if canResolve && conflict.isOpen {
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
        .task {
            await reloadDetails()
        }
        .actionErrorAlert(runner)
    }

    @ViewBuilder
    private func reservationSection(_ reservation: Reservation, detail: ReservationDetail?, title: String) -> some View {
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

            if conflict.isOpen, let resolve = detail?.action("resolve_conflict") {
                Button {
                    Task { await resolveConflict(winner: reservation) }
                } label: {
                    Label("Darle la reservación a \(requesterName)", systemImage: "checkmark.circle.fill")
                }
                .disabled(runner.isRunning)
                .accessibilityHint(resolve.reason ?? "")
            }
        }
    }

    private func reloadDetails() async {
        async let a: ReservationDetail? = try? container.rpc.reservationDetail(reservationId: conflict.reservationAId)
        async let b: ReservationDetail? = try? container.rpc.reservationDetail(reservationId: conflict.reservationBId)
        let (loadedA, loadedB) = await (a, b)
        detailA = loadedA
        detailB = loadedB
    }

    private func resolveConflict(winner: Reservation) async {
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
