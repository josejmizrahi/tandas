import SwiftUI
import RuulCore

/// R.5V.Calendar — Calendario mensual del contexto. Agrega TODO lo que tiene
/// fecha: eventos · reservaciones · votos con deadline · obligaciones con
/// vencimiento. Carga en paralelo y combina los resultados.
public struct ContextCalendarView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var events: [CalendarEvent] = []
    @State private var reservations: [Reservation] = []
    @State private var decisions: [Decision] = []
    @State private var obligations: [Obligation] = []
    /// Map resourceId → displayName para rows de reservaciones.
    @State private var resourceNames: [UUID: String] = [:]

    @State private var displayedMonth: Date
    @State private var selectedDay: Date?

    private let cal = Calendar.current

    public init(context: AppContext, container: DependencyContainer) {
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
        .navigationTitle("Calendario")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if events.isEmpty && reservations.isEmpty && decisions.isEmpty && obligations.isEmpty {
            phase = .loading
        }
        do {
            async let eventsTask = container.rpc.listEvents(contextId: context.id)
            async let reservationsTask: [Reservation] = context.isPersonal
                ? []
                : (try? await container.rpc.listContextReservations(contextId: context.id)) ?? []
            async let decisionsTask: [Decision] = (try? await container.rpc.listDecisions(contextId: context.id)) ?? []
            async let obligationsTask: [Obligation] = context.isPersonal
                ? []
                : (try? await container.rpc.listObligations(contextId: context.id)) ?? []

            let (loadedEvents, loadedReservations, loadedDecisions, loadedObligations) =
                try await (eventsTask, reservationsTask, decisionsTask, obligationsTask)

            events = loadedEvents
            reservations = loadedReservations
            // Solo decisions abiertas con deadline.
            decisions = loadedDecisions.filter { $0.closesAt != nil && $0.isOpen }
            // Solo obligations abiertas con vencimiento.
            obligations = loadedObligations.filter { $0.dueAt != nil && $0.isOpen }

            // Resolver nombres de recursos para reservation rows.
            if !context.isPersonal && !reservations.isEmpty {
                if let resources = try? await container.rpc.listContextResources(contextId: context.id) {
                    resourceNames = Dictionary(uniqueKeysWithValues: resources.map { ($0.resourceId, $0.displayName) })
                }
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
                        ("Eventos", Theme.Tint.primary),
                        ("Reservas", Theme.Tint.success),
                        ("Votos", .purple),
                        ("Compromisos", Theme.Tint.warning)
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
        let hasEvents = !events(on: date).isEmpty
        let hasReservations = !reservations(on: date).isEmpty
        let hasVotes = !decisions(closingOn: date).isEmpty
        let hasObligations = !obligations(dueOn: date).isEmpty

        let count = [hasEvents, hasReservations, hasVotes, hasObligations].filter { $0 }.count
        if count == 0 { return nil }
        if count > 1 { return Theme.Tint.warning }
        if hasObligations { return Theme.Tint.warning }
        if hasVotes { return .purple }
        if hasEvents { return Theme.Tint.primary }
        return Theme.Tint.success
    }

    @ViewBuilder
    private func daySections(_ day: Date) -> some View {
        let dayEvents = events(on: day)
        let dayReservations = reservations(on: day)
        let dayVotes = decisions(closingOn: day)
        let dayObligations = obligations(dueOn: day)

        if dayEvents.isEmpty && dayReservations.isEmpty && dayVotes.isEmpty && dayObligations.isEmpty {
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
            if !dayVotes.isEmpty {
                Section {
                    ForEach(dayVotes) { decision in
                        NavigationLink {
                            DecisionDetailView(decisionId: decision.id, context: context, container: container)
                        } label: {
                            voteRow(decision)
                        }
                    }
                } header: {
                    Label("Votos pendientes", systemImage: "checkmark.bubble.fill")
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
            if !dayObligations.isEmpty {
                Section {
                    ForEach(dayObligations) { obligation in
                        NavigationLink {
                            ObligationDetailView(obligationId: obligation.id, context: context, container: container)
                        } label: {
                            obligationRow(obligation)
                        }
                    }
                } header: {
                    Label("Compromisos vencen", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
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
                    Label("Eventos", systemImage: "calendar")
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

    // MARK: - Rows

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
                Text(resourceNames[reservation.resourceId] ?? "Recurso")
                    .font(.callout.weight(.medium))
                Text(rangeText(reservation))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
            StatusBadge(reservation.statusLabel, color: Theme.Status.reservation(reservation.status))
        }
    }

    @ViewBuilder
    private func voteRow(_ decision: Decision) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
                if let closes = decision.closesAt {
                    Text("Cierra \(closes.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        } icon: {
            Image(systemName: "checkmark.bubble.fill")
                .foregroundStyle(.purple)
        }
    }

    @ViewBuilder
    private func obligationRow(_ obligation: Obligation) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(obligation.title ?? obligation.kindLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(obligation.kindLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.Tint.warning)
        }
    }

    // MARK: - Filters

    private func events(on day: Date) -> [CalendarEvent] {
        events
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

    private func decisions(closingOn day: Date) -> [Decision] {
        decisions.filter { d in
            guard let closes = d.closesAt else { return false }
            return cal.isDate(closes, inSameDayAs: day)
        }
        .sorted { ($0.closesAt ?? .distantPast) < ($1.closesAt ?? .distantPast) }
    }

    private func obligations(dueOn day: Date) -> [Obligation] {
        obligations.filter { o in
            guard let due = o.dueAt else { return false }
            return cal.isDate(due, inSameDayAs: day)
        }
        .sorted { ($0.dueAt ?? .distantPast) < ($1.dueAt ?? .distantPast) }
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
