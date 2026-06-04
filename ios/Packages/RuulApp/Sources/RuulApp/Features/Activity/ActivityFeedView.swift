import SwiftUI
import RuulCore

/// F.13 — memoria del contexto: timeline completo de lo que pasó, sin
/// mezclar contextos (RLS lo garantiza del lado del backend).
public struct ActivityFeedView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ActivityStore
    @State private var selectedEvent: ActivityEvent?

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: ActivityStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
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
                feedList
            }
        }
        .navigationTitle("Actividad")
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .toolbar {
            if store.hasDescendants {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: Binding(
                        get: { store.includeDescendants },
                        set: { newValue in
                            Task { await store.setIncludeDescendants(newValue, context: context) }
                        }
                    )) {
                        Label("Incluir subcontextos", systemImage: "list.bullet.indent")
                    }
                    .toggleStyle(.button)
                }
            }
        }
        .sheet(item: $selectedEvent) { event in
            ActivityDetailView(event: event, context: context, store: store)
        }
    }

    @ViewBuilder
    private var feedList: some View {
        if store.events.isEmpty {
            EmptyStateView(
                symbolName: "clock.arrow.circlepath",
                title: "Sin actividad",
                message: "Todo lo que pase en \(context.displayName) queda registrado aquí: eventos, gastos, multas, decisiones, reservaciones…"
            )
        } else {
            List {
                ForEach(groupedByDay, id: \.day) { group in
                    Section(group.day) {
                        ForEach(group.events) { event in
                            Button {
                                selectedEvent = event
                            } label: {
                                eventRow(event)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if store.hasMore {
                    Section {
                        Button {
                            Task { await store.loadMore(context: context) }
                        } label: {
                            if store.isLoadingMore {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Cargar más")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: ActivityEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: event.symbolName)
                .foregroundStyle(event.isSystemGenerated ? Color.indigo : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.typeLabel)
                    .font(.callout)
                HStack(spacing: 6) {
                    Text(store.displayName(for: event.actorId, contextId: context.id, contextName: context.displayName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if event.isSystemGenerated {
                        StatusBadge("Automático", color: .indigo)
                    }
                }
            }
            Spacer()
            if let occurred = event.occurredAt {
                Text(occurred.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Agrupación por día

    private var groupedByDay: [(day: String, events: [ActivityEvent])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: store.events) { event -> Date in
            calendar.startOfDay(for: event.occurredAt ?? .distantPast)
        }
        return groups
            .sorted { $0.key > $1.key }
            .map { (day: $0.key.formatted(date: .complete, time: .omitted), events: $0.value) }
    }
}

/// F.13 — detalle de un evento de actividad: payload legible.
public struct ActivityDetailView: View {
    let event: ActivityEvent
    let context: AppContext
    let store: ActivityStore

    @Environment(\.dismiss) private var dismiss

    public init(event: ActivityEvent, context: AppContext, store: ActivityStore) {
        self.event = event
        self.context = context
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: event.symbolName)
                            .font(.system(size: 28))
                            .foregroundStyle(event.isSystemGenerated ? Color.indigo : Color.accentColor)
                            .frame(width: 52, height: 52)
                            .background(Color.accentColor.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.typeLabel)
                                .font(.headline)
                            if event.isSystemGenerated {
                                StatusBadge("Generado por el sistema", color: .indigo)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Información") {
                    InfoRow(
                        symbolName: "person",
                        title: "Quién",
                        value: store.displayName(for: event.actorId, contextId: context.id, contextName: context.displayName)
                    )
                    if let occurred = event.occurredAt {
                        InfoRow(
                            symbolName: "clock",
                            title: "Cuándo",
                            value: occurred.formatted(date: .abbreviated, time: .standard)
                        )
                    }
                    InfoRow(symbolName: "tag", title: "Tipo", value: event.eventType)
                }

                if let payload = event.payload?.objectValue, !payload.isEmpty {
                    Section("Detalles") {
                        ForEach(payload.keys.sorted(), id: \.self) { key in
                            if let value = payload[key], key != "system" {
                                InfoRow(
                                    symbolName: "info.circle",
                                    title: payloadKeyLabel(key),
                                    value: payloadValueLabel(value)
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Detalle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    private func payloadKeyLabel(_ key: String) -> String {
        switch key {
        case "amount": return "Monto"
        case "currency": return "Moneda"
        case "description": return "Descripción"
        case "minutes_late": return "Minutos tarde"
        case "same_day_cancellation": return "Cancelación mismo día"
        case "split_method": return "Tipo de reparto"
        case "participants": return "Participantes"
        case "obligations_created": return "Deudas creadas"
        case "obligation_type": return "Tipo de obligación"
        case "rule_title": return "Regla"
        case "paid_by": return "Pagado por"
        default: return key
        }
    }

    private func payloadValueLabel(_ value: JSONValue) -> String {
        if let s = value.stringValue { return s }
        if let n = value.numberValue { return n.formatted(.number) }
        if let b = value.boolValue { return b ? "Sí" : "No" }
        return "—"
    }
}

#Preview("Actividad") {
    NavigationStack {
        ActivityFeedView(
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
