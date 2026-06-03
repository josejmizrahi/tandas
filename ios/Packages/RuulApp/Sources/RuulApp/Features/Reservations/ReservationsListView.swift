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
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
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
                EmptyStateView(
                    symbolName: "calendar.badge.clock",
                    title: "Sin reservaciones",
                    message: "Solicita \(resource.displayName) para un rango de fechas."
                )
                .listRowBackground(Color.clear)
            }

            if !store.upcoming.isEmpty {
                Section("Próximas") {
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
    }

    @ViewBuilder
    private func reservationRow(_ reservation: Reservation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName(for: reservation.reservedForActorId ?? reservation.requestedByActorId))
                Text(rangeText(reservation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(reservation.statusLabel, color: statusColor(reservation.status))
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
                Task {
                    try? await store.cancel(reservationId: reservation.id, resourceId: resource.id, context: context)
                }
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
        switch status {
        case "requested": return .orange
        case "approved": return .blue
        case "confirmed": return .green
        case "rejected", "cancelled": return .red
        case "completed": return .gray
        default: return .secondary
        }
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
