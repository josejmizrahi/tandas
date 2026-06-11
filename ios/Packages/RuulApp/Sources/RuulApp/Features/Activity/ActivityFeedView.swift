import SwiftUI
import RuulCore

/// F.13 — memoria del contexto: timeline completo de lo que pasó, sin
/// mezclar contextos (RLS lo garantiza del lado del backend).
public struct ActivityFeedView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ActivityStore
    @State private var selectedEvent: ActivityEvent?
    /// V.3 — export de la memoria institucional (CSV vía ShareLink).
    @State private var exportItem: ExportedHistory?
    @State private var isExporting = false

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: ActivityStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState()

            case .failed(let message):
                RuulErrorState(message: message) {
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
            // V.3 — "memoria institucional exportable": la promesa de la
            // visión ("historial completo, export simple") en CSV.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await exportHistory() }
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityLabel("Exportar historial")
                    }
                }
                .disabled(isExporting || !store.phase.isLoaded)
            }
        }
        .sheet(item: $selectedEvent) { event in
            ActivityDetailView(event: event, context: context, store: store)
        }
        .sheet(item: $exportItem) { item in
            ExportHistorySheet(item: item, contextName: context.displayName)
        }
    }

    /// V.3 — descarga hasta 500 eventos frescos y arma el CSV
    /// (fecha · evento · actor · detalle compacto del payload).
    private func exportHistory() async {
        isExporting = true
        defer { isExporting = false }
        let events = (try? await container.rpc.listActivity(
            contextId: context.id, limit: 500, before: nil,
            includeDescendants: store.includeDescendants
        )) ?? store.events

        var csv = "fecha,evento,actor,detalle\n"
        let formatter = ISO8601DateFormatter()
        for event in events {
            let date = event.occurredAt.map(formatter.string(from:)) ?? ""
            let actor = store.displayName(for: event.actorId, contextId: context.id, contextName: context.displayName)
            let detail = (event.payload?.objectValue ?? [:])
                .compactMap { key, value in value.stringValue.map { "\(key): \($0)" } }
                .sorted()
                .joined(separator: " · ")
            csv += [date, event.eventType, actor, detail]
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: ",") + "\n"
        }

        let safeName = context.displayName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName) — historial.csv")
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            exportItem = ExportedHistory(url: url, eventCount: events.count)
        } catch {
            // Sin alert dedicado: el botón simplemente no abre el sheet.
        }
    }

    @ViewBuilder
    private var feedList: some View {
        if store.events.isEmpty {
            RuulEmptyState(
                title: "Sin actividad",
                systemImage: "clock.arrow.circlepath",
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
                    HStack(spacing: Theme.Spacing.lg) {
                        Image(systemName: event.symbolName)
                            .font(.system(size: Theme.IconSize.sm))
                            .foregroundStyle(event.isSystemGenerated ? Color.indigo : Color.accentColor)
                            .frame(width: 52, height: 52)
                            .background(Color.accentColor.badgeFillSubtle, in: Circle())
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

// MARK: - V.3 Export

/// Item exportado (Identifiable para `.sheet(item:)`).
struct ExportedHistory: Identifiable {
    let url: URL
    let eventCount: Int
    var id: URL { url }
}

/// Sheet mínima con el resumen del export + ShareLink al CSV.
struct ExportHistorySheet: View {
    let item: ExportedHistory
    let contextName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "doc.text")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Historial de \(contextName)")
                    .font(.headline)
                Text("\(item.eventCount) eventos en CSV. La memoria del grupo, portable.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: item.url) {
                    Label("Compartir CSV", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
