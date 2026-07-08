import SwiftUI
import RuulCore

/// R.8.MiMundo.S6 — Vista cross-context de las reservaciones donde participo
/// (requested_by o reserved_for == myActorId). Fan-out paralelo similar a
/// `MyCalendarView`, agregando lookup de resource displayName vía `myWorld()`.
///
/// Picker Próximas / Pasadas / Canceladas. Tap → ResourceDetailViewV2 del
/// recurso reservado (no hay detail view dedicada por reservación; el resource
/// es el contexto natural — ahí ves todas las reservaciones del recurso).
public struct MyReservationsView: View {
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var aggregated: [Entry] = []
    @State private var resourceNames: [UUID: String] = [:]
    @State private var filter: ReservationFilter = .upcoming
    @State private var selected: SelectedTarget?

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando reservaciones…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                content
            }
        }
        .navigationTitle("Mis reservaciones")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { target in
            NavigationStack {
                ResourceDetailViewV2(
                    resourceId: target.resourceId,
                    context: target.context,
                    container: container
                )
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let filtered = aggregated.filter { matchesFilter($0) }.sorted(by: startsAtAsc)

        List {
            filterSection
            if filtered.isEmpty {
                emptySection
            } else {
                Section {
                    ForEach(filtered) { entry in
                        Button {
                            selected = SelectedTarget(resourceId: entry.reservation.resourceId, context: entry.context)
                        } label: {
                            row(entry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            swipeActions(entry)
                        }
                    }
                } header: {
                    Label(filter.headerLabel, systemImage: filter.headerSymbol)
                        .foregroundStyle(filter.headerTint)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var filterSection: some View {
        Section {
            Picker("Filtro", selection: $filter) {
                ForEach(ReservationFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.sm, leading: Theme.Spacing.md,
                                       bottom: Theme.Spacing.sm, trailing: Theme.Spacing.md))
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: filter == .upcoming ? "calendar.badge.checkmark" : "tray")
                    .foregroundStyle(Theme.Text.tertiary)
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .upcoming:  return "Sin reservaciones próximas"
        case .past:      return "Sin reservaciones pasadas"
        case .cancelled: return "Sin reservaciones canceladas"
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        let resourceName = resourceNames[entry.reservation.resourceId] ?? "Recurso"
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(statusTint(entry.reservation.status))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(resourceName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(rangeText(entry.reservation))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                Text(entry.context.displayName)
                    .font(.caption2)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.reservation.statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusTint(entry.reservation.status))
        }
    }

    // MARK: - Swipe actions

    /// R.15 — cancelar desde la lista. Todas las entries son mías (filtro
    /// `isMine` en `load()`), así que "Cancelar" es honesto para reservas
    /// requested/approved que aún no terminan. Mismo path que
    /// ContextReservationsView, incluido el reload post-acción.
    /// No hay "Aprobar"/"Confirmar": esta vista sólo agrega reservas donde soy
    /// requester/beneficiario y no carga `myPermissions` por contexto.
    @ViewBuilder
    private func swipeActions(_ entry: Entry) -> some View {
        let r = entry.reservation
        if (r.status == "requested" || r.status == "approved") && r.endsAt >= Date() {
            Button("Cancelar", role: .destructive) {
                Task { await runAndReload { try await container.rpc.cancelReservation(reservationId: r.id) } }
            }
        }
    }

    private func runAndReload(_ action: () async throws -> Void) async {
        try? await action()
        await load()
    }

    private func rangeText(_ r: Reservation) -> String {
        let start = r.startsAt.formatted(date: .abbreviated, time: .shortened)
        let end = r.endsAt.formatted(date: .abbreviated, time: .shortened)
        return "\(start) → \(end)"
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "approved", "confirmed": return Theme.Tint.success
        case "requested", "waitlisted": return Theme.Tint.info
        case "rejected", "cancelled":   return Theme.Tint.critical
        case "completed":               return Theme.Text.secondary
        default:                        return Theme.Text.secondary
        }
    }

    private func startsAtAsc(_ a: Entry, _ b: Entry) -> Bool {
        a.reservation.startsAt < b.reservation.startsAt
    }

    // MARK: - Filter logic

    private func matchesFilter(_ entry: Entry) -> Bool {
        let r = entry.reservation
        let isCancelled = (r.status == "rejected" || r.status == "cancelled")
        switch filter {
        case .upcoming:
            return !isCancelled && r.endsAt >= Date()
        case .past:
            return !isCancelled && r.endsAt < Date()
        case .cancelled:
            return isCancelled
        }
    }

    // MARK: - Data

    private func load() async {
        if aggregated.isEmpty { phase = .loading }
        let myActorId = container.currentActorStore.actorId
        let contexts = container.contextStore.availableContexts
        guard !contexts.isEmpty else {
            aggregated = []
            phase = .loaded
            return
        }
        // Carga my_world() y reservas por contexto en paralelo.
        async let world: MyWorld? = try? await container.rpc.myWorld()
        async let slices: [ContextSlice] = withTaskGroup(of: ContextSlice.self) { group in
            for ctx in contexts where !ctx.isPersonal {
                // Personal context no tiene resource_reservations; skip por velocidad.
                group.addTask {
                    let reservations: [Reservation] = (try? await container.rpc.listContextReservations(contextId: ctx.id)) ?? []
                    return ContextSlice(context: ctx, reservations: reservations)
                }
            }
            var out: [ContextSlice] = []
            for await slice in group { out.append(slice) }
            return out
        }

        let loadedWorld = await world
        let loadedSlices = await slices

        var names: [UUID: String] = [:]
        for resource in loadedWorld?.resources ?? [] {
            names[resource.resourceId] = resource.displayName
        }

        var all: [Entry] = []
        for slice in loadedSlices {
            for r in slice.reservations where isMine(r, myActorId: myActorId) {
                all.append(Entry(reservation: r, context: slice.context))
            }
        }
        resourceNames = names
        aggregated = all
        phase = .loaded
    }

    private func isMine(_ r: Reservation, myActorId: UUID?) -> Bool {
        guard let myActorId else { return false }
        return r.requestedByActorId == myActorId || r.reservedForActorId == myActorId
    }

    // MARK: - Types

    private struct Entry: Identifiable, Sendable {
        let reservation: Reservation
        let context: AppContext
        var id: UUID { reservation.id }
    }

    private struct ContextSlice: Sendable {
        let context: AppContext
        let reservations: [Reservation]
    }

    private struct SelectedTarget: Identifiable {
        let resourceId: UUID
        let context: AppContext
        var id: UUID { resourceId }
    }

    private enum ReservationFilter: String, CaseIterable, Identifiable {
        case upcoming, past, cancelled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .upcoming:  return "Próximas"
            case .past:      return "Pasadas"
            case .cancelled: return "Canceladas"
            }
        }
        var headerLabel: String { label }
        var headerSymbol: String {
            switch self {
            case .upcoming:  return "calendar.badge.checkmark"
            case .past:      return "clock.arrow.circlepath"
            case .cancelled: return "xmark.circle.fill"
            }
        }
        var headerTint: Color {
            switch self {
            case .upcoming:  return Theme.Tint.success
            case .past:      return Theme.Text.secondary
            case .cancelled: return Theme.Tint.critical
            }
        }
    }
}

#Preview("Mis reservaciones (demo)") {
    NavigationStack {
        MyReservationsView(container: .demo())
    }
}
