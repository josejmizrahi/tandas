import SwiftUI
import RuulCore

/// R.5V.Calendar — Calendario mensual de un recurso específico. Muestra
/// reservaciones del recurso + eventos del contexto que reservan este recurso
/// (linkados vía `reservation.source_event_id`).
///
/// Complementa `ReservationsCalendarView` (que vive dentro del segmented
/// "Lista/Calendario" de ReservationsListView). Este es el calendar standalone
/// accesible desde `ResourceDetailViewV2`.
public struct ResourceCalendarView: View {
    let resource: Resource
    let context: AppContext
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var reservations: [Reservation] = []
    @State private var linkedEvents: [CalendarEvent] = []
    @State private var displayedMonth: Date
    @State private var selectedDay: Date?

    private let cal = Calendar.current

    public init(resource: Resource, context: AppContext, container: DependencyContainer) {
        self.resource = resource
        self.context = context
        self.container = container
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        _displayedMonth = State(initialValue: monthStart)
        _selectedDay = State(initialValue: Calendar.current.startOfDay(for: .now))
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando calendario…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                calendarList
            }
        }
        .navigationTitle("Calendario · \(resource.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if reservations.isEmpty && linkedEvents.isEmpty { phase = .loading }
        do {
            // Reservaciones del recurso (cross-resource context query filtrada).
            let allReservations: [Reservation]
            if context.isPersonal {
                allReservations = []
            } else {
                allReservations = (try? await container.rpc.listContextReservations(contextId: context.id)) ?? []
            }
            reservations = allReservations.filter { $0.resourceId == resource.id }

            // Eventos del contexto que tocan este recurso vía reservation.source_event_id.
            let linkedEventIds = Set(reservations.compactMap(\.sourceEventId))
            if !linkedEventIds.isEmpty {
                let allEvents = (try? await container.rpc.listEvents(contextId: context.id)) ?? []
                linkedEvents = allEvents.filter { linkedEventIds.contains($0.id) }
            } else {
                linkedEvents = []
            }
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
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
                        ("Reservas", Theme.Tint.success),
                        ("Eventos", Theme.Tint.primary)
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

    private func dotColor(for date: Date) -> Color? {
        let hasReservations = !reservations(on: date).isEmpty
        let hasEvents = !events(on: date).isEmpty
        if hasReservations && hasEvents { return Theme.Tint.warning }
        if hasReservations { return Theme.Tint.success }
        if hasEvents { return Theme.Tint.primary }
        return nil
    }

    @ViewBuilder
    private func daySections(_ day: Date) -> some View {
        let dayReservations = reservations(on: day)
        let dayEvents = events(on: day)

        if dayReservations.isEmpty && dayEvents.isEmpty {
            Section {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(Theme.Text.tertiary)
                    Text("\(resource.displayName) está libre este día")
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
                    Label("Eventos en este recurso", systemImage: "calendar")
                        .foregroundStyle(Theme.Text.secondary)
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
                Text(rangeText(reservation))
                    .font(.callout.weight(.medium))
                if reservation.sourceEventId != nil {
                    Text("Por un evento")
                        .font(.caption)
                        .foregroundStyle(Theme.Tint.primary)
                }
            }
            Spacer()
            StatusBadge(reservation.statusLabel, color: Theme.Status.reservation(reservation.status))
        }
    }

    // MARK: - Filters

    private func events(on day: Date) -> [CalendarEvent] {
        linkedEvents
            .filter { event in
                guard let starts = event.startsAt else { return false }
                return cal.isDate(starts, inSameDayAs: day)
            }
            .sorted { ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast) }
    }

    private func reservations(on day: Date) -> [Reservation] {
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return reservations.filter { r in
            r.startsAt < dayEnd && r.endsAt >= dayStart
        }
    }

    private func rangeText(_ r: Reservation) -> String {
        "\(r.startsAt.formatted(date: .abbreviated, time: .omitted)) → \(r.endsAt.formatted(date: .abbreviated, time: .omitted))"
    }
}
