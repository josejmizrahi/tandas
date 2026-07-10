import SwiftUI
import RuulCore

/// F.7 — lista de eventos del contexto.
///
/// **R.5V.X (2026-06-09)** — Rebuild Apple-native + Liquid Glass (mismo patrón
/// que MyResourcesView v3):
/// 1. Hero summary card con Liquid Glass interactivo (próximos + breakdown
///    por horizonte temporal: Hoy / Esta semana / Más adelante)
/// 2. `.searchable` para filtrar por título
/// 3. Sections agrupadas por horizonte (Hoy / Mañana / Esta semana / Este mes
///    / Más adelante / Pasados) con tints semánticos
/// 4. Estados via componentes Ruul* (RuulLoadingState / RuulErrorState /
///    RuulEmptyState)
public struct EventsListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: EventsStore
    @State private var isShowingCreate = false
    /// R.15 — al crear un evento desde el tab, empujamos su detalle (misma
    /// conducta que el "+" global de CreateIntentSheet).
    @State private var createdEvent: CreatedEventTarget?
    @State private var query: String = ""
    /// R.5V.Zoom — Namespace para matched transition source → destination zoom.
    @Namespace private var zoomNamespace

    private struct CreatedEventTarget: Identifiable, Hashable {
        let id: UUID
    }

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: EventsStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando eventos…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(context: context) }
                }
            case .loaded:
                loadedContent
            }
        }
        .navigationTitle("Eventos")
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
        }
        .toolbar {
            if store.canCreate(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingCreate = true
                    } label: {
                        Label("Crear evento", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            CreateEventView(context: context, store: store, container: container, onCreated: { id in
                isShowingCreate = false
                createdEvent = CreatedEventTarget(id: id)
            })
        }
        .navigationDestination(item: $createdEvent) { created in
            EventDetailView(eventId: created.id, context: context, container: container)
        }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private var loadedContent: some View {
        if store.events.isEmpty {
            RuulEmptyState(
                title: "Sin eventos",
                systemImage: "calendar",
                message: "Crea la primera cena, reunión o noche de juegos."
            )
        } else {
            let filtered = filter(store.events)
            let grouped = groupByHorizon(filtered)
            List {
                heroSection(store.upcoming)
                ForEach(EventHorizon.displayOrder, id: \.self) { horizon in
                    if let items = grouped[horizon], !items.isEmpty {
                        Section {
                            ForEach(items) { event in
                                eventRow(event, horizon: horizon)
                            }
                        } header: {
                            Text("\(horizon.displayName) (\(items.count))")
                        }
                    }
                }
                if grouped.isEmpty {
                    Section {
                        Text("Sin coincidencias con \"\(query)\"")
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Theme.Spacing.md)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar evento")
            .searchToolbarBehavior(.minimize)
        }
    }

    // MARK: - Hero (R.17.1 — celda agrupada nativa, mismo lenguaje que el hero
    // de Dinero y los detalles. Sin listRowBackground(.clear) ni inset leading:4
    // que lo dejaban flotando/jammed a la izquierda — se veía "extraño".)

    @ViewBuilder
    private func heroSection(_ upcoming: [CalendarEvent]) -> some View {
        Section {
            heroContent(upcoming)
                .ruulHeroRow()
        }
    }

    @ViewBuilder
    private func heroContent(_ upcoming: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let next = upcoming.first {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Próximo plan", systemImage: "calendar")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.Tint.primary)
                    Text(next.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                    Text(heroSubtitle(next, total: upcoming.count))
                        .font(.subheadline)
                        .foregroundStyle(Theme.Text.secondary)
                }
                let breakdown = upcomingBreakdown(upcoming)
                if breakdown.count > 1 {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(breakdown, id: \.0) { horizon, count in
                            horizonChip(horizon, count: count)
                        }
                    }
                }
                NavigationLink {
                    EventDetailView(eventId: next.id, context: context, container: container)
                } label: {
                    Label("Ver evento", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.title)
                        .foregroundStyle(Theme.Tint.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sin planes próximos")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.Text.primary)
                        Text("Arma la próxima cena, viaje o juego del grupo.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if store.canCreate(in: context) {
                    Button {
                        isShowingCreate = true
                    } label: {
                        Label("Crear evento", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private func heroSubtitle(_ next: CalendarEvent, total: Int) -> String {
        var parts: [String] = []
        if let starts = next.startsAt {
            parts.append(starts.formatted(date: .abbreviated, time: .shortened))
        }
        if total > 1 {
            parts.append("\(total) eventos próximos")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func horizonChip(_ horizon: EventHorizon, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: horizon.symbolName)
                .font(.caption.weight(.semibold))
            Text("\(count) \(horizon.shortLabel)")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(horizon.tint)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(horizon.tint.opacity(Theme.Surface.badgeFillSubtle), in: Capsule())
    }

    // MARK: - Event row

    @ViewBuilder
    private func eventRow(_ event: CalendarEvent, horizon: EventHorizon) -> some View {
        NavigationLink {
            EventDetailView(eventId: event.id, context: context, container: container)
                .navigationTransition(.zoom(sourceID: event.id, in: zoomNamespace))
        } label: {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Image(systemName: event.type.symbolName)
                    .foregroundStyle(horizon.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(1)
                        if event.isRecurring {
                            Image(systemName: "repeat")
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                    if let starts = event.startsAt {
                        Text(eventDateLabel(starts, horizon: horizon))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text(statusLabel(event.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusTint(event.status))
            }
        }
        .matchedTransitionSource(id: event.id, in: zoomNamespace)
    }

    private func eventDateLabel(_ date: Date, horizon: EventHorizon) -> String {
        switch horizon {
        case .today:
            return date.formatted(date: .omitted, time: .shortened)
        case .tomorrow:
            return "Mañana · " + date.formatted(date: .omitted, time: .shortened)
        case .thisWeek:
            // Weekday + hora
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        case .thisMonth, .later:
            return date.formatted(date: .abbreviated, time: .shortened)
        case .past:
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    // MARK: - Filter + group

    private func filter(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return events }
        return events.filter { $0.title.lowercased().contains(q) }
    }

    private func groupByHorizon(_ events: [CalendarEvent]) -> [EventHorizon: [CalendarEvent]] {
        Dictionary(grouping: events, by: { EventHorizon.from(event: $0) })
            .mapValues { items in
                items.sorted { ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast) }
            }
    }

    private func upcomingBreakdown(_ upcoming: [CalendarEvent]) -> [(EventHorizon, Int)] {
        let grouped = Dictionary(grouping: upcoming, by: { EventHorizon.from(event: $0) })
        return EventHorizon.upcomingOrder.compactMap { horizon in
            guard let count = grouped[horizon]?.count, count > 0 else { return nil }
            return (horizon, count)
        }
    }

    // MARK: - Status helpers (preserved)

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "scheduled":   return "Programado"
        case "completed":   return "Cerrado"
        case "cancelled":   return "Cancelado"
        case "in_progress": return "En curso"
        default:            return status
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "scheduled":   return Theme.Tint.info
        case "completed":   return Theme.Text.tertiary
        case "cancelled":   return Theme.Tint.critical
        case "in_progress": return Theme.Tint.success
        default:            return Theme.Text.secondary
        }
    }
}

// MARK: - EventHorizon

private enum EventHorizon: String, CaseIterable, Hashable {
    case today, tomorrow, thisWeek, thisMonth, later, past

    /// Order para Sections (incluye Pasados al final).
    static let displayOrder: [EventHorizon] = [.today, .tomorrow, .thisWeek, .thisMonth, .later, .past]
    /// Order para hero breakdown (sin Pasados — solo upcoming).
    static let upcomingOrder: [EventHorizon] = [.today, .tomorrow, .thisWeek, .thisMonth, .later]

    static func from(event: CalendarEvent) -> EventHorizon {
        guard let starts = event.startsAt else { return .later }
        let cal = Calendar.current
        let now = Date()
        if starts < cal.startOfDay(for: now) { return .past }
        if cal.isDateInToday(starts) { return .today }
        if cal.isDateInTomorrow(starts) { return .tomorrow }
        // Esta semana = hasta el final de la semana actual.
        if let weekInterval = cal.dateInterval(of: .weekOfYear, for: now),
           starts < weekInterval.end {
            return .thisWeek
        }
        // Este mes = hasta el final del mes actual.
        if let monthInterval = cal.dateInterval(of: .month, for: now),
           starts < monthInterval.end {
            return .thisMonth
        }
        return .later
    }

    var displayName: String {
        switch self {
        case .today:     return "Hoy"
        case .tomorrow:  return "Mañana"
        case .thisWeek:  return "Esta semana"
        case .thisMonth: return "Este mes"
        case .later:     return "Más adelante"
        case .past:      return "Pasados"
        }
    }

    /// Short label para chips del hero ("3 hoy", "5 semana").
    var shortLabel: String {
        switch self {
        case .today:     return "hoy"
        case .tomorrow:  return "mañana"
        case .thisWeek:  return "esta semana"
        case .thisMonth: return "este mes"
        case .later:     return "más adelante"
        case .past:      return "pasados"
        }
    }

    var symbolName: String {
        switch self {
        case .today:     return "calendar.badge.exclamationmark"
        case .tomorrow:  return "sun.max.fill"
        case .thisWeek:  return "calendar"
        case .thisMonth: return "calendar.day.timeline.left"
        case .later:     return "calendar.badge.clock"
        case .past:      return "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .today:     return Theme.Tint.warning   // urgente
        case .tomorrow:  return Theme.Tint.warning
        case .thisWeek:  return Theme.Tint.primary
        case .thisMonth: return Theme.Tint.info
        case .later:     return Theme.Text.secondary
        case .past:      return Theme.Text.tertiary
        }
    }
}

#Preview("Eventos") {
    NavigationStack {
        EventsListView(
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
