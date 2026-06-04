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
                ForEach(groupedItems, id: \.label) { group in
                    Section {
                        ForEach(group.items) { item in
                            feedRow(item)
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
                    .fill(sourceColor(item.source).opacity(0.15))
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
        switch source {
        case .subscription: return .blue
        case .ownership:    return .orange
        case .membership:   return .green
        }
    }

    private func contextName(for contextActorId: UUID?) -> String? {
        guard let id = contextActorId else { return nil }
        return container.contextStore.availableContexts.first { $0.id == id }?.displayName
    }
}

#Preview("Mi Actividad — demo") {
    NavigationStack {
        MyActivityFeedView(container: .demo())
    }
}
