import SwiftUI
import RuulCore

/// F.9 / R.2S.7 — resolver un conflicto de reservación. El admin elige entre
/// 8 modelos de resolución del backend:
/// - `winner` / `priority_based` / `admin_override` — escoge ganador, perdedor `rejected`.
/// - `waitlisted` — escoge ganador, perdedor `waitlisted` (espera disponibilidad).
/// - `lottery` — backend hace sorteo aleatorio.
/// - `split_dates` / `partial_approval` — backend parte el rango por la mitad.
/// - `requires_decision` — crea decisión `reservation_dispute` (existente).
public struct ReservationConflictView: View {
    let conflict: ReservationConflict
    let resource: Resource
    let context: AppContext
    let store: ReservationsStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    /// R.2S — detail por reservación con `available_actions` canónicos del backend.
    @State private var detailA: ReservationDetail?
    @State private var detailB: ReservationDetail?
    @State private var lastResolution: ResolveConflictResult?

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
                    Text("Dos solicitudes piden \(resource.displayName) en fechas que se traslapan. Elige cómo resolverlo.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
            }

            if let a = reservationA {
                reservationSection(a, detail: detailA, title: "Solicitud A", isB: false)
            }
            if let b = reservationB {
                reservationSection(b, detail: detailB, title: "Solicitud B", isB: true)
            }

            if canResolve && conflict.isOpen {
                otherOptionsSection
            }

            if let result = lastResolution {
                resolutionResultSection(result)
            }
        }
        .navigationTitle("Conflicto")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reloadDetails()
        }
        .actionErrorAlert(runner)
    }

    // MARK: - Reservation sections (winner + waitlisted)

    @ViewBuilder
    private func reservationSection(_ reservation: Reservation, detail: ReservationDetail?, title: String, isB: Bool) -> some View {
        let requesterName = store.displayName(for: reservation.reservedForActorId ?? reservation.requestedByActorId)
        let otherName = store.displayName(for: (isB ? reservationA : reservationB)?.reservedForActorId
                                          ?? (isB ? reservationA : reservationB)?.requestedByActorId)

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

            if conflict.isOpen, detail?.can("resolve_conflict") == true {
                Button {
                    Task { await resolve(.winner, winner: reservation.id) }
                } label: {
                    Label("Darle la reservación a \(requesterName)", systemImage: "checkmark.circle.fill")
                }
                .disabled(runner.isRunning)

                Button {
                    Task { await resolve(.waitlisted, winner: reservation.id) }
                } label: {
                    Label("Darle a \(requesterName), \(otherName) en lista de espera", systemImage: "hourglass")
                        .font(.callout)
                }
                .disabled(runner.isRunning)
            }
        }
    }

    // MARK: - Other resolution models

    @ViewBuilder
    private var otherOptionsSection: some View {
        Section {
            Button {
                Task { await resolve(.lottery, winner: nil) }
            } label: {
                Label("Sorteo aleatorio", systemImage: "die.face.5")
            }
            .disabled(runner.isRunning)

            Button {
                Task { await resolve(.splitDates, winner: nil) }
            } label: {
                Label("Partir las fechas a la mitad", systemImage: "scissors")
            }
            .disabled(runner.isRunning)

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
        } header: {
            Text("Otras formas de resolver")
        } footer: {
            Text("El sorteo lo hace el backend. Partir las fechas aprueba ambas, cada una con la mitad del rango.")
        }
    }

    // MARK: - Resolution result

    @ViewBuilder
    private func resolutionResultSection(_ result: ResolveConflictResult) -> some View {
        Section {
            Label {
                Text(resolutionSummary(result))
                    .font(.callout)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Resuelto")
        }
    }

    private func resolutionSummary(_ result: ResolveConflictResult) -> String {
        switch ResolutionModel(rawValue: result.resolutionModel) {
        case .lottery:
            guard let winnerId = result.winnerReservationId,
                  let winner = store.reservation(byId: winnerId) else {
                return "Sorteo realizado."
            }
            return "Sorteo: ganó \(store.displayName(for: winner.reservedForActorId ?? winner.requestedByActorId))."
        case .splitDates, .partialApproval:
            if let splitAt = result.splitAt {
                return "Fechas partidas en \(splitAt.formatted(date: .abbreviated, time: .shortened)). Ambas reservaciones aprobadas."
            }
            return "Fechas partidas. Ambas reservaciones aprobadas."
        case .waitlisted:
            guard let winnerId = result.winnerReservationId,
                  let winner = store.reservation(byId: winnerId) else {
                return "Una en lista de espera."
            }
            return "Aprobada \(store.displayName(for: winner.reservedForActorId ?? winner.requestedByActorId)); la otra queda en lista de espera."
        case .requiresDecision:
            return "Escalado a votación."
        default:
            guard let winnerId = result.winnerReservationId,
                  let winner = store.reservation(byId: winnerId) else {
                return "Ganador asignado."
            }
            return "Ganó \(store.displayName(for: winner.reservedForActorId ?? winner.requestedByActorId))."
        }
    }

    // MARK: - Actions

    private func reloadDetails() async {
        async let a: ReservationDetail? = try? container.rpc.reservationDetail(reservationId: conflict.reservationAId)
        async let b: ReservationDetail? = try? container.rpc.reservationDetail(reservationId: conflict.reservationBId)
        let (loadedA, loadedB) = await (a, b)
        detailA = loadedA
        detailB = loadedB
    }

    private func resolve(_ model: ResolutionModel, winner: UUID?) async {
        let success = await runner.run {
            let result = try await store.resolveConflict(
                conflictId: conflict.id,
                resolutionModel: model,
                winnerReservationId: winner,
                resourceId: resource.id,
                context: context
            )
            lastResolution = result
        }
        if success {
            // Para split_dates dejamos visible el resultado un momento antes de cerrar.
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
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
