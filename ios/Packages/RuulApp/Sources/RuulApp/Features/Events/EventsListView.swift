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
                    Section("Próximos (\(store.upcoming.count))") {
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
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEvent) -> some View {
        NavigationLink {
            EventDetailView(eventId: event.id, context: context, container: container)
        } label: {
            LabeledContent {
                Text(statusLabel(event.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusTint(event.status))
            } label: {
                Label {
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
                            Text(starts.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: event.type.symbolName)
                        .foregroundStyle(Theme.Tint.primary)
                }
            }
        }
    }

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
