import SwiftUI
import RuulCore

/// R.5V.Calendar — Calendario mensual del contexto: eventos + reservaciones
/// cross-resource en un solo mes view. Cada día se decora con dot del item
/// más importante; tap muestra el detalle del día.
public struct ContextCalendarView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var eventsStore: EventsStore
    @State private var reservationsStore: ReservationsStore
    @State private var displayedMonth: Date
    @State private var selectedDay: Date?

    private let cal = Calendar.current

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _eventsStore = State(initialValue: EventsStore(rpc: container.rpc))
        _reservationsStore = State(initialValue: ReservationsStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        _displayedMonth = State(initialValue: monthStart)
        _selectedDay = State(initialValue: Calendar.current.startOfDay(for: .now))
    }

    public var body: some View {
        Group {
            switch (eventsStore.phase, reservationsStore.phase) {
            case (.idle, _), (.loading, _), (_, .idle), (_, .loading):
                RuulLoadingState(title: "Cargando calendario…")
            case (.failed(let message), _), (_, .failed(let message)):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            default:
                calendarList
            }
        }
        .navigationTitle("Calendario")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        async let events: Void = eventsStore.load(context: context)
        async let reservations: Void = reservationsStore.loadByContext(context: context)
        _ = await (events, reservations)
    }

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

    // MARK: - Day section

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
                    ForEach(dayEvents) { event in
                        NavigationLink {
                            EventDetailView(eventId: event.id, context: context, container: container)
                        } label: {
                            eventRow(event)
                        }
                    }
                } header: {
                    HStack {
                        Label("Eventos", systemImage: "calendar")
                            .foregroundStyle(Theme.Text.secondary)
                        Spacer()
                        Text(day.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                }
            }
            if !dayReservations.isEmpty {
                Section {
                    ForEach(dayReservations) { reservation in
                        reservationRow(reservation)
                    }
                } header: {
                    Label("Reservaciones", systemImage: "calendar.badge.clock")
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEvent) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                if let starts = event.startsAt {
                    Text(starts.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        } icon: {
            Image(systemName: event.type.symbolName)
                .foregroundStyle(Theme.Tint.primary)
        }
    }

    @ViewBuilder
    private func reservationRow(_ reservation: Reservation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(Theme.Tint.success)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(reservationsStore.resourceName(for: reservation.resourceId) ?? "Recurso")
                    .font(.callout.weight(.medium))
                Text(rangeText(reservation))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
            StatusBadge(reservation.statusLabel, color: Theme.Status.reservation(reservation.status))
        }
    }

    // MARK: - Filters

    private func events(on day: Date) -> [CalendarEvent] {
        eventsStore.events
            .filter { event in
                guard let starts = event.startsAt else { return false }
                return cal.isDate(starts, inSameDayAs: day)
            }
            .sorted { ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast) }
    }

    private func reservations(on day: Date) -> [Reservation] {
        reservationsStore.reservations(covering: day, calendar: cal)
    }

    private func rangeText(_ r: Reservation) -> String {
        "\(r.startsAt.formatted(date: .abbreviated, time: .omitted)) → \(r.endsAt.formatted(date: .abbreviated, time: .omitted))"
    }
}

#Preview("Calendario del contexto") {
    NavigationStack {
        ContextCalendarView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal",
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
