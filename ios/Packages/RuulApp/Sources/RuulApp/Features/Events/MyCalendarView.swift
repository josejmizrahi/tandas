import SwiftUI
import RuulCore

/// R.5V.Calendar — Mi calendario cross-context. Agrega TODO lo que tiene fecha
/// donde participo: eventos · reservaciones · votos con deadline · obligaciones
/// con vencimiento. Carga en paralelo por contexto y combina los resultados.
public struct MyCalendarView: View {
    let container: DependencyContainer

    @State private var phase: StorePhase = .idle
    @State private var aggregatedEvents: [(event: CalendarEvent, context: AppContext)] = []
    @State private var aggregatedReservations: [(reservation: Reservation, context: AppContext)] = []
    @State private var aggregatedDecisions: [(decision: Decision, context: AppContext)] = []
    @State private var aggregatedObligations: [(obligation: Obligation, context: AppContext)] = []
    @State private var displayedMonth: Date
    @State private var selectedDay: Date?
    @State private var createEventTarget: AppContext?

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
        .sheet(item: $createEventTarget) { ctx in
            // Trae su propio NavigationStack interno (mismo patrón que HomeView).
            CreateEventView(
                context: ctx,
                store: EventsStore(rpc: container.rpc),
                container: container,
                onCreated: { _ in
                    createEventTarget = nil
                    Task { await load() }
                }
            )
        }
    }

    // MARK: - Loading

    private func load() async {
        if aggregatedEvents.isEmpty && aggregatedReservations.isEmpty
            && aggregatedDecisions.isEmpty && aggregatedObligations.isEmpty {
            phase = .loading
        }
        let myActorId = container.currentActorStore.actorId
        let contexts = container.contextStore.availableContexts
        guard !contexts.isEmpty else {
            phase = .loaded
            return
        }
        do {
            try await withThrowingTaskGroup(of: ContextSlice.self) { group in
                for ctx in contexts {
                    group.addTask {
                        // Cargas en paralelo por contexto. Toleramos fallos parciales:
                        // sólo events es required; el resto opcional vía try?.
                        async let events = container.rpc.listEvents(contextId: ctx.id)
                        async let reservations: [Reservation] = ctx.isPersonal
                            ? []
                            : (try? await container.rpc.listContextReservations(contextId: ctx.id)) ?? []
                        async let decisions: [Decision] = (try? await container.rpc.listDecisions(contextId: ctx.id)) ?? []
                        async let obligations: [Obligation] = ctx.isPersonal
                            ? []
                            : (try? await container.rpc.listObligations(contextId: ctx.id)) ?? []
                        let (loadedEvents, loadedReservations, loadedDecisions, loadedObligations) =
                            try await (events, reservations, decisions, obligations)
                        return ContextSlice(
                            context: ctx,
                            events: loadedEvents,
                            reservations: loadedReservations,
                            decisions: loadedDecisions,
                            obligations: loadedObligations
                        )
                    }
                }
                var allEvents: [(CalendarEvent, AppContext)] = []
                var allReservations: [(Reservation, AppContext)] = []
                var allDecisions: [(Decision, AppContext)] = []
                var allObligations: [(Obligation, AppContext)] = []
                for try await slice in group {
                    for event in slice.events {
                        allEvents.append((event, slice.context))
                    }
                    for reservation in slice.reservations where isMyReservation(reservation, myActorId: myActorId) {
                        allReservations.append((reservation, slice.context))
                    }
                    // Sólo decisions abiertas con closesAt en el futuro (deadlines reales).
                    for decision in slice.decisions where decision.closesAt != nil && decision.isOpen {
                        allDecisions.append((decision, slice.context))
                    }
                    // Sólo obligations abiertas con dueAt y donde participo (debtor/creditor).
                    for obligation in slice.obligations where obligation.dueAt != nil
                        && obligation.isOpen
                        && isMyObligation(obligation, myActorId: myActorId) {
                        allObligations.append((obligation, slice.context))
                    }
                }
                aggregatedEvents = allEvents
                aggregatedReservations = allReservations
                aggregatedDecisions = allDecisions
                aggregatedObligations = allObligations
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

    private func isMyObligation(_ o: Obligation, myActorId: UUID?) -> Bool {
        guard let myActorId else { return false }
        return o.debtorActorId == myActorId || o.creditorActorId == myActorId
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

    // MARK: - Day decoration

    /// Color del dot del día. Prioridad: critical (obligation vencida) >
    /// warning (mix) > purple (vote deadline) > primary (event) >
    /// success (reservation).
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

    // MARK: - Day section

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
                createEventButton
            } header: {
                Text(day.formatted(date: .complete, time: .omitted))
            }
        } else {
            if !dayVotes.isEmpty {
                Section {
                    ForEach(dayVotes, id: \.decision.id) { entry in
                        NavigationLink {
                            DecisionDetailView(decisionId: entry.decision.id, context: entry.context, container: container)
                        } label: {
                            voteRow(entry.decision, contextName: entry.context.displayName)
                        }
                    }
                } header: {
                    Label("Votos pendientes", systemImage: "checkmark.bubble.fill")
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
            if !dayObligations.isEmpty {
                Section {
                    ForEach(dayObligations, id: \.obligation.id) { entry in
                        NavigationLink {
                            ObligationDetailView(obligationId: entry.obligation.id, context: entry.context, container: container)
                        } label: {
                            obligationRow(entry.obligation, contextName: entry.context.displayName)
                        }
                    }
                } header: {
                    Label("Compromisos vencen", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
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
                        NavigationLink {
                            ResourceDetailViewV2(
                                resourceId: entry.reservation.resourceId,
                                context: entry.context,
                                container: container
                            )
                        } label: {
                            reservationRow(entry.reservation, contextName: entry.context.displayName)
                        }
                    }
                } header: {
                    Label("Mis reservaciones", systemImage: "calendar.badge.clock")
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        }
    }

    /// R.15 — un día libre invita a crear algo. Con 1 solo colectivo va
    /// directo; con varios, Menu para elegir el grupo; sin colectivos no hay
    /// dónde crear y no mostramos nada.
    @ViewBuilder
    private var createEventButton: some View {
        let collectives = container.contextStore.collectiveContexts
        if collectives.count == 1, let only = collectives.first {
            Button {
                createEventTarget = only
            } label: {
                Label("Crear evento", systemImage: "plus.circle.fill")
            }
        } else if collectives.count > 1 {
            Menu {
                ForEach(collectives) { ctx in
                    Button(ctx.displayName) { createEventTarget = ctx }
                }
            } label: {
                Label("Crear evento", systemImage: "plus.circle.fill")
            }
        }
    }

    // MARK: - Rows

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
                    }
                    Text("·")
                    Text(contextName).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary)
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

    @ViewBuilder
    private func voteRow(_ decision: Decision, contextName: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let closes = decision.closesAt {
                        Text("Cierra \(closes.formatted(date: .omitted, time: .shortened))")
                    }
                    Text("·")
                    Text(contextName).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary)
            }
        } icon: {
            Image(systemName: "checkmark.bubble.fill")
                .foregroundStyle(.purple)
        }
    }

    @ViewBuilder
    private func obligationRow(_ obligation: Obligation, contextName: String) -> some View {
        let myActorId = container.currentActorStore.actorId
        let iOwe = obligation.debtorActorId == myActorId
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(obligation.title ?? obligation.kindLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(iOwe ? "Debo cumplir" : "Por cobrar")
                        .foregroundStyle(iOwe ? Theme.Tint.warning : Theme.Tint.success)
                    Text("·")
                    Text(contextName).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary)
            }
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.Tint.warning)
        }
    }

    // MARK: - Filters by day

    private func events(on day: Date) -> [(event: CalendarEvent, context: AppContext)] {
        aggregatedEvents
            .filter { entry in
                guard let starts = entry.event.startsAt else { return false }
                return cal.isDate(starts, inSameDayAs: day)
            }
            .sorted { ($0.event.startsAt ?? .distantPast) < ($1.event.startsAt ?? .distantPast) }
    }

    private func reservations(on day: Date) -> [(reservation: Reservation, context: AppContext)] {
        aggregatedReservations.filter { entry in
            let dayStart = cal.startOfDay(for: day)
            guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return false }
            return entry.reservation.startsAt < dayEnd && entry.reservation.endsAt >= dayStart
        }
    }

    private func decisions(closingOn day: Date) -> [(decision: Decision, context: AppContext)] {
        aggregatedDecisions.filter { entry in
            guard let closes = entry.decision.closesAt else { return false }
            return cal.isDate(closes, inSameDayAs: day)
        }
        .sorted { ($0.decision.closesAt ?? .distantPast) < ($1.decision.closesAt ?? .distantPast) }
    }

    private func obligations(dueOn day: Date) -> [(obligation: Obligation, context: AppContext)] {
        aggregatedObligations.filter { entry in
            guard let due = entry.obligation.dueAt else { return false }
            return cal.isDate(due, inSameDayAs: day)
        }
        .sorted { ($0.obligation.dueAt ?? .distantPast) < ($1.obligation.dueAt ?? .distantPast) }
    }

    private func rangeText(_ r: Reservation) -> String {
        "\(r.startsAt.formatted(date: .abbreviated, time: .omitted)) → \(r.endsAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private struct ContextSlice: Sendable {
        let context: AppContext
        let events: [CalendarEvent]
        let reservations: [Reservation]
        let decisions: [Decision]
        let obligations: [Obligation]
    }
}

#Preview("Mi calendario") {
    NavigationStack {
        MyCalendarView(container: .demo())
    }
}
