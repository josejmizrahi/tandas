import SwiftUI
import RuulCore

/// R.3A / F.NAV.9 — "Mi Actividad" — feed personalizado del actor actual.
/// Combina 3 fuentes (subscriptions + ownership + membership). El backend
/// define `source`, `subscriptionType` y `score`; iOS sólo presenta.
///
/// F.NAV.9 polish:
/// - Agrupación por día (Hoy / Ayer / fecha).
/// - Friendly title compuesto desde payload (no keys técnicos).
/// - Drop del tag "Suscripción" repetido — la fuente queda como un dot de
///   color en la izquierda.
public struct MyActivityFeedView: View {
    let container: DependencyContainer

    @State private var store: ActivityFeedStore
    /// Tap en un item con subject conocido (resource/event/decision/obligation)
    /// empuja el detail correspondiente.
    @State private var pushedSubject: ActivitySubjectDestination?
    /// R.6.AI.3 — Resumen on-device del feed via FoundationModels.
    @State private var summaryService = ActivitySummaryService()

    public init(container: DependencyContainer) {
        self.container = container
        _store = State(initialValue: ActivityFeedStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.reload() }
                }

            case .loaded:
                feedList
            }
        }
        .navigationTitle("Mi Actividad")
        .task {
            await store.load()
        }
        .refreshable {
            await store.reload()
        }
        .navigationDestination(item: $pushedSubject) { dest in
            destinationView(for: dest)
        }
    }

    @ViewBuilder
    private func destinationView(for dest: ActivitySubjectDestination) -> some View {
        switch dest {
        case let .resource(id, ctx):
            ResourceDetailView(resourceId: id, context: ctx, container: container)
        case let .event(id, ctx):
            EventDetailView(eventId: id, context: ctx, container: container)
        case let .decision(id, ctx):
            DecisionDetailView(decisionId: id, context: ctx, container: container)
        case let .obligation(id, ctx):
            ObligationDetailView(obligationId: id, context: ctx, container: container)
        }
    }

    @ViewBuilder
    private var feedList: some View {
        if store.items.isEmpty {
            EmptyStateView(
                symbolName: "antenna.radiowaves.left.and.right",
                title: "Sin señales todavía",
                message: "Suscríbete a contextos, recursos, decisiones o eventos. Aquí verás las últimas actualizaciones de lo que te importa."
            )
        } else {
            List {
                aiSummarySection
                ForEach(groupedItems, id: \.label) { group in
                    Section {
                        ForEach(group.items) { item in
                            if let destination = subjectDestination(for: item) {
                                Button {
                                    pushedSubject = destination
                                } label: {
                                    feedRow(item)
                                }
                                .buttonStyle(.plain)
                            } else {
                                feedRow(item)
                            }
                        }
                    } header: {
                        Text(group.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func feedRow(_ item: FeedItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(sourceColor(item.source).badgeFill)
                    .frame(width: 32, height: 32)
                Image(systemName: item.asActivityEvent.symbolName)
                    .font(.callout)
                    .foregroundStyle(sourceColor(item.source))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.asActivityEvent.friendlyTitle(currentActorId: container.currentActorStore.actorId))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if let ctxName = contextName(for: item.contextActorId) {
                        Text(ctxName)
                    }
                    if let occurred = item.occurredAt {
                        Text("·")
                        Text(occurred.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Agrupación por día

    private var groupedItems: [DayGroup] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let groups = Dictionary(grouping: store.items) { item -> Date in
            guard let occurred = item.occurredAt else { return .distantPast }
            return calendar.startOfDay(for: occurred)
        }

        return groups.keys.sorted(by: >).map { day in
            let label: String
            if calendar.isDate(day, inSameDayAs: today) {
                label = "Hoy"
            } else if calendar.isDate(day, inSameDayAs: yesterday) {
                label = "Ayer"
            } else if day == .distantPast {
                label = "Sin fecha"
            } else {
                label = day.formatted(.dateTime.day().month(.wide).year())
            }
            return DayGroup(
                label: label,
                items: (groups[day] ?? []).sorted {
                    ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
                }
            )
        }
    }

    private struct DayGroup {
        let label: String
        let items: [FeedItem]
    }

    // MARK: - Helpers

    private func sourceColor(_ source: FeedSource) -> Color {
        Theme.Source.tint(source)
    }

    private func contextName(for contextActorId: UUID?) -> String? {
        guard let id = contextActorId else { return nil }
        return container.contextStore.availableContexts.first { $0.id == id }?.displayName
    }

    /// Deriva el destino de navegación a partir del subject del item.
    /// Sólo enrutamos a primitivas con detail view real. Items sin subject
    /// navegable (rules, settlement, expense suelto…) quedan no-tap.
    private func subjectDestination(for item: FeedItem) -> ActivitySubjectDestination? {
        guard let ctxId = item.contextActorId,
              let ctx = container.contextStore.availableContexts.first(where: { $0.id == ctxId })
        else { return nil }

        if let resourceId = item.resourceId {
            return .resource(resourceId, ctx)
        }
        if let decisionId = item.decisionId {
            return .decision(decisionId, ctx)
        }
        if let obligationId = item.obligationId {
            return .obligation(obligationId, ctx)
        }
        guard let subjectId = item.subjectId else { return nil }
        switch item.subjectType {
        case "resource":             return .resource(subjectId, ctx)
        case "calendar_event":       return .event(subjectId, ctx)
        case "decision":             return .decision(subjectId, ctx)
        case "obligation":           return .obligation(subjectId, ctx)
        default:                     return nil
        }
    }

    // MARK: - R.6.AI.3 Activity Summary

    @ViewBuilder
    private var aiSummarySection: some View {
        Section {
            switch summaryService.phase {
            case .idle:
                Button {
                    Task { await summaryService.summarize(input: buildSummaryInput()) }
                } label: {
                    Label("Resumir mi actividad", systemImage: "sparkles")
                        .symbolRenderingMode(.hierarchical)
                        .frame(maxWidth: .infinity)
                }
                .disabled(!summaryService.isAvailable || store.items.isEmpty)
            case .loading:
                HStack {
                    ProgressView()
                    Text("Resumiendo…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            case .loaded(let summary):
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Button("Generar otro") {
                        Task { await summaryService.summarize(input: buildSummaryInput()) }
                    }
                    .font(.caption)
                }
            case .unavailable(let reason):
                Label(reason, systemImage: "sparkles.slash")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Label("Resumen con Apple Intelligence", systemImage: "sparkles")
        }
    }

    /// Pre-agrega los items en un string compacto que el modelo convierte a
    /// prosa. Limitamos a counts por kind + top 5 highlights para no inflar
    /// el context window.
    private func buildSummaryInput() -> String {
        let items = store.items.prefix(40)
        guard !items.isEmpty else { return "" }
        let counts = Dictionary(grouping: items, by: { $0.asActivityEvent.eventType })
            .mapValues { $0.count }
        let countsLine = counts
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        let highlights = items.prefix(5).map { item -> String in
            let title = item.asActivityEvent.friendlyTitle(currentActorId: container.currentActorStore.actorId)
            let ctxName = contextName(for: item.contextActorId) ?? "?"
            return "- \(title) (\(ctxName))"
        }.joined(separator: "\n")
        return """
            Total de eventos recientes: \(items.count).
            Distribución por tipo: \(countsLine).
            Highlights:
            \(highlights)
            """
    }
}

/// Destino enrutable de un item del feed de actividad.
private enum ActivitySubjectDestination: Hashable {
    case resource(UUID, AppContext)
    case event(UUID, AppContext)
    case decision(UUID, AppContext)
    case obligation(UUID, AppContext)
}

#Preview("Mi Actividad — demo") {
    NavigationStack {
        MyActivityFeedView(container: .demo())
    }
}
