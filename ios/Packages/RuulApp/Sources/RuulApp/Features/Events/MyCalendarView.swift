import SwiftUI
import RuulCore

/// R.5V.Calendar — Mi calendario cross-context. Agrega eventos + reservaciones
/// donde participo a través de todos mis contextos disponibles. Carga en
/// paralelo por contexto y combina los resultados.
public struct MyCalendarView: View {
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var aggregatedEvents: [(event: CalendarEvent, context: AppContext)] = []
    @State private var aggregatedReservations: [(reservation: Reservation, context: AppContext, resourceName: String?)] = []
    @State private var displayedMonth: Date
    @State private var selectedDay: Date?

    private let cal = Calendar.current

    public init(container: DependencyContainer) {
        self.container = container
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        _displayedMonth = State(initialValue: monthStart)
        _selectedDay = State(initialValue: Calendar.current.startOfDay(for: .now))
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando tu calendario…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                calendarList
            }
        }
        .navigationTitle("Mi calendario")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Loading

    private func load() async {
        if aggregatedEvents.isEmpty && aggregatedReservations.isEmpty { phase = .loading }
        let myActorId = container.currentActorStore.actorId
        let contexts = container.contextStore.availableContexts
        guard !contexts.isEmpty else {
            phase = .loaded
            return
        }
        do {
            // Paralelo: events + reservations por contexto.
            try await withThrowingTaskGroup(of: ContextSlice.self) { group in
                for ctx in contexts {
                    group.addTask {
                        async let events = container.rpc.listEvents(contextId: ctx.id)
                        async let reservations: [Reservation] = ctx.isPersonal
                            ? []
                            : (try? await container.rpc.listContextReservations(contextId: ctx.id)) ?? []
                        let (loadedEvents, loadedReservations) = try await (events, reservations)
                        return ContextSlice(
                            context: ctx,
                            events: loadedEvents,
                            reservations: loadedReservations
                        )
                    }
                }
                var allEvents: [(CalendarEvent, AppContext)] = []
                var allReservations: [(Reservation, AppContext, String?)] = []
                for try await slice in group {
                    for event in slice.events {
                        allEvents.append((event, slice.context))
                    }
                    // Solo mis reservaciones (donde participo).
                    for reservation in slice.reservations where isMyReservation(reservation, myActorId: myActorId) {
                        // El nombre del recurso vendrá de un mini-cache;
                        // si no lo tenemos, se mostrará "Recurso".
                        allReservations.append((reservation, slice.context, nil))
                    }
                }
                aggregatedEvents = allEvents
                aggregatedReservations = allReservations
            }
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    private func isMyReservation(_ r: Reservation, myActorId: UUID?) -> Bool {
        guard let myActorId else { return false }
        return r.requestedByActorId == myActorId || r.reservedForActorId == myActorId
    }

    // MARK: - List

    @ViewBuilder
    private var calendarList: some View {
        List {
            Section {
                RuulCalendarMonthGrid(
                    displayedMonth: $displayedMonth,
                    selectedDay: $selectedDay,
                    dotColor: dotColor(for:),
                    legendItems: [
                        ("Eventos", Theme.Tint.primary),
                        ("Reservas", Theme.Tint.success)
                    ]
                )
                .listRowInsets(EdgeInsets(top: Theme.Spacing.sm, leading: Theme.Spacing.md, bottom: Theme.Spacing.sm, trailing: Theme.Spacing.md))
            }

            if let selectedDay {
                daySections(selectedDay)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Day decoration

    private func dotColor(for date: Date) -> Color? {
        let dayEvents = events(on: date)
        let dayReservations = reservations(on: date)
        if !dayEvents.isEmpty && !dayReservations.isEmpty { return Theme.Tint.warning }
        if !dayEvents.isEmpty { return Theme.Tint.primary }
        if !dayReservations.isEmpty { return Theme.Tint.success }
        return nil
    }

    @ViewBuilder
    private func daySections(_ day: Date) -> some View {
        let dayEvents = events(on: day)
        let dayReservations = reservations(on: day)

        if dayEvents.isEmpty && dayReservations.isEmpty {
            Section {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(Theme.Text.tertiary)
                    Text("Día libre")
                        .font(.callout)
                        .foregroundStyle(Theme.Text.secondary)
                }
                .padding(.vertical, Theme.Spacing.xs)
            } header: {
                Text(day.formatted(date: .complete, time: .omitted))
            }
        } else {
            if !dayEvents.isEmpty {
                Section {
                    ForEach(dayEvents, id: \.event.id) { entry in
                        NavigationLink {
                            EventDetailView(eventId: entry.event.id, context: entry.context, container: container)
                        } label: {
                            eventRow(entry.event, contextName: entry.context.displayName)
                        }
                    }
                } header: {
                    Label("Eventos", systemImage: "calendar")
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
            if !dayReservations.isEmpty {
                Section {
                    ForEach(dayReservations, id: \.reservation.id) { entry in
                        reservationRow(entry.reservation, contextName: entry.context.displayName)
                    }
                } header: {
                    Label("Mis reservaciones", systemImage: "calendar.badge.clock")
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEvent, contextName: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let starts = event.startsAt {
                        Text(starts.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                    Text(contextName)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: event.type.symbolName)
                .foregroundStyle(Theme.Tint.primary)
        }
    }

    @ViewBuilder
    private func reservationRow(_ reservation: Reservation, contextName: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(Theme.Tint.success)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(rangeText(reservation))
                    .font(.callout.weight(.medium))
                Text(contextName)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
            StatusBadge(reservation.statusLabel, color: Theme.Status.reservation(reservation.status))
        }
    }

    // MARK: - Filters

    private func events(on day: Date) -> [(event: CalendarEvent, context: AppContext)] {
        aggregatedEvents
            .filter { entry in
                guard let starts = entry.event.startsAt else { return false }
                return cal.isDate(starts, inSameDayAs: day)
            }
            .sorted { ($0.event.startsAt ?? .distantPast) < ($1.event.startsAt ?? .distantPast) }
    }

    private func reservations(on day: Date) -> [(reservation: Reservation, context: AppContext, resourceName: String?)] {
        aggregatedReservations.filter { entry in
            let dayStart = cal.startOfDay(for: day)
            guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return false }
            return entry.reservation.startsAt < dayEnd && entry.reservation.endsAt >= dayStart
        }
    }

    private func rangeText(_ r: Reservation) -> String {
        "\(r.startsAt.formatted(date: .abbreviated, time: .omitted)) → \(r.endsAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private struct ContextSlice: Sendable {
        let context: AppContext
        let events: [CalendarEvent]
        let reservations: [Reservation]
    }
}

#Preview("Mi calendario") {
    NavigationStack {
        MyCalendarView(container: .demo())
    }
}
