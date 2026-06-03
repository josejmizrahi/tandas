import SwiftUI
import RuulCore

/// F.7 — lista de eventos del contexto (próximos + pasados).
public struct EventsListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: EventsStore
    @State private var isShowingCreate = false

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: EventsStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.load(context: context) }
                }

            case .loaded:
                eventsList
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
            CreateEventView(context: context, store: store, container: container)
        }
    }

    @ViewBuilder
    private var eventsList: some View {
        if store.events.isEmpty {
            EmptyStateView(
                symbolName: "calendar",
                title: "Sin eventos",
                message: "Crea la primera cena, reunión o noche de juegos."
            )
        } else {
            List {
                if !store.upcoming.isEmpty {
                    Section("Próximos") {
                        ForEach(store.upcoming) { event in
                            eventRow(event)
                        }
                    }
                }
                if !store.past.isEmpty {
                    Section("Pasados") {
                        ForEach(store.past) { event in
                            eventRow(event)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEvent) -> some View {
        NavigationLink {
            EventDetailView(eventId: event.id, context: context, container: container)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: event.type.symbolName)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.title)
                            .lineLimit(1)
                        if event.isRecurring {
                            Image(systemName: "repeat")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let starts = event.startsAt {
                        Text(starts.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusBadge(event)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ event: CalendarEvent) -> some View {
        switch event.status {
        case "scheduled": StatusBadge("Programado", color: .blue)
        case "completed": StatusBadge("Cerrado", color: .gray)
        case "cancelled": StatusBadge("Cancelado", color: .red)
        case "in_progress": StatusBadge("En curso", color: .green)
        default: StatusBadge(event.status, color: .secondary)
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
