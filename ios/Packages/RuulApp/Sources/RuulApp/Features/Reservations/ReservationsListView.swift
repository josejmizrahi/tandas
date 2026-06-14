import SwiftUI
import RuulCore

/// F.9 — reservaciones de un recurso: próximas, pasadas y conflictos abiertos.
public struct ReservationsListView: View {
    let resource: Resource
    let context: AppContext
    let container: DependencyContainer
    /// Contexto que gobierna el recurso — las solicitudes de reservación se
    /// crean ahí, aunque se navegue desde otro contexto (p.ej. el personal).
    let reservationContextId: UUID

    private enum ViewMode: String, CaseIterable {
        case list = "Lista"
        case calendar = "Calendario"
    }

    @State private var store: ReservationsStore
    @State private var isShowingRequest = false
    @State private var viewMode: ViewMode = .list
    /// Slice 7.A.3 — confirmation antes de cancelar por swipe (fat-finger safety).
    @State private var pendingCancel: Reservation?

    public init(resource: Resource, context: AppContext, reservationContextId: UUID? = nil, container: DependencyContainer) {
        self.resource = resource
        self.context = context
        self.reservationContextId = reservationContextId ?? context.id
        self.container = container
        _store = State(initialValue: ReservationsStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState()

            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(resourceId: resource.id, context: context) }
                }

            case .loaded:
                loadedContent
            }
        }
        .navigationTitle("Reservaciones")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.load(resourceId: resource.id, context: context)
        }
        .refreshable {
            await store.load(resourceId: resource.id, context: context)
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(resourceId: resource.id, context: context)
        }
        .toolbar {
            if store.canRequest(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingRequest = true
                    } label: {
                        Label("Reservar", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingRequest) {
            RequestReservationView(
                resource: resource,
                context: context,
                reservationContextId: reservationContextId,
                store: store,
                container: container
            )
        }
        .confirmationDialog(
            "¿Cancelar esta reservación?",
            isPresented: Binding(
                get: { pendingCancel != nil },
                set: { if !$0 { pendingCancel = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingCancel
        ) { target in
            Button("Cancelar reservación", role: .destructive) {
                Task {
                    try? await store.cancel(reservationId: target.id, resourceId: resource.id, context: context)
                    pendingCancel = nil
                }
            }
            Button("No cancelar", role: .cancel) {}
        } message: { target in
            Text("La reservación del \(target.startsAt.formatted(date: .abbreviated, time: .omitted)) quedará cancelada y liberará el horario.")
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        VStack(spacing: 0) {
            Picker("Vista", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch viewMode {
            case .list:
                reservationsList
            case .calendar:
                ReservationsCalendarView(resource: resource, context: context, store: store)
            }
        }
    }

    @ViewBuilder
    private var reservationsList: some View {
        List {
            // Conflictos primero — son lo que requiere acción.
            if !store.openConflicts.isEmpty {
                Section {
                    ForEach(store.openConflicts) { conflict in
                        NavigationLink {
                            ReservationConflictView(
                                conflict: conflict,
                                resource: resource,
                                context: context,
                                store: store,
                                container: container
                            )
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Conflicto de fechas")
                                        .foregroundStyle(.primary)
                                    Text(conflictSubtitle(conflict))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Conflictos abiertos (\(store.openConflicts.count))")
                }
            }

            if store.upcoming.isEmpty && store.pastOrInactive.isEmpty {
                RuulEmptyState(
                    title: "Sin reservaciones",
                    systemImage: "calendar.badge.clock",
                    message: "Solicita \(resource.displayName) para un rango de fechas."
                    )
                .listRowBackground(Color.clear)
            }

            if !store.upcoming.isEmpty {
                Section("Próximas (\(store.upcoming.count))") {
                    ForEach(store.upcoming) { reservation in
                        reservationRow(reservation)
                    }
                }
            }

            if !store.pastOrInactive.isEmpty {
                Section("Anteriores") {
                    ForEach(store.pastOrInactive) { reservation in
                        reservationRow(reservation)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func reservationRow(_ reservation: Reservation) -> some View {
        LabeledContent {
            Text(reservation.statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor(reservation.status))
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.displayName(for: reservation.reservedForActorId ?? reservation.requestedByActorId))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    Text(rangeText(reservation))
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
            } icon: {
                Image(systemName: "calendar")
                    .foregroundStyle(Theme.Tint.primary)
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
                Task {
                    try? await store.approve(reservationId: reservation.id, resourceId: resource.id, context: context)
                }
            }
            .tint(.green)
        }
        if store.canManage(in: context) && reservation.status == "approved" {
            Button("Confirmar") {
                Task {
                    try? await store.confirm(reservationId: reservation.id, resourceId: resource.id, context: context)
                }
            }
            .tint(.blue)
        }
        if (isMine || store.canManage(in: context)) && (reservation.isPending || reservation.isActive) {
            Button("Cancelar", role: .destructive) {
                pendingCancel = reservation
            }
        }
    }

    private func conflictSubtitle(_ conflict: ReservationConflict) -> String {
        let a = store.reservation(byId: conflict.reservationAId)
        let b = store.reservation(byId: conflict.reservationBId)
        let nameA = store.displayName(for: a?.reservedForActorId ?? a?.requestedByActorId)
        let nameB = store.displayName(for: b?.reservedForActorId ?? b?.requestedByActorId)
        return "\(nameA) y \(nameB) piden fechas que se traslapan"
    }

    private func rangeText(_ reservation: Reservation) -> String {
        let start = reservation.startsAt.formatted(date: .abbreviated, time: .omitted)
        let end = reservation.endsAt.formatted(date: .abbreviated, time: .omitted)
        return "\(start) → \(end)"
    }

    private func statusColor(_ status: String) -> Color {
        Theme.Status.reservation(status)
    }
}

#Preview("Reservaciones Casa Valle") {
    NavigationStack {
        ReservationsListView(
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
            container: .demo()
        )
    }
}
