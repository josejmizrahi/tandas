import SwiftUI
import RuulCore

/// R.3A — "Mi Actividad" — feed personalizado del actor actual.
///
/// NO es un feed social. Combina 3 fuentes (subscriptions + ownership +
/// membership) y muestra las últimas señales relevantes. El backend define
/// `source`, `subscriptionType` y `score`; iOS sólo presenta.
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
                ForEach(store.items) { item in
                    feedRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func feedRow(_ item: FeedItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.asActivityEvent.symbolName)
                .foregroundStyle(item.asActivityEvent.isSystemGenerated ? Color.indigo : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.asActivityEvent.typeLabel)
                    .font(.callout)
                HStack(spacing: 6) {
                    sourceBadge(item)
                    if let subType = item.subscriptionType {
                        Text(subType.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if let occurred = item.occurredAt {
                Text(occurred.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func sourceBadge(_ item: FeedItem) -> some View {
        switch item.source {
        case .subscription:
            StatusBadge(item.source.label, color: .blue)
        case .ownership:
            StatusBadge(item.source.label, color: .orange)
        case .membership:
            StatusBadge(item.source.label, color: .green)
        }
    }
}

#Preview("Mi Actividad — demo") {
    NavigationStack {
        MyActivityFeedView(container: .demo())
    }
}
