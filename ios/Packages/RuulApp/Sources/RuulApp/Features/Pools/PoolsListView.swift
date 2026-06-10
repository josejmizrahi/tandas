import SwiftUI
import RuulCore

/// R.8.E — Fondos del contexto (pools): botes (winner_takes_all) y fondos
/// con meta (equity_target). Backend = autoridad: nombres, totales y status
/// vienen de `list_context_pools`.
public struct PoolsListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: PoolsStore
    @State private var isShowingCreate = false

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: PoolsStore(rpc: container.rpc))
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
                content
            }
        }
        .navigationTitle("Fondos")
        .task { await store.load(context: context) }
        .refreshable { await store.load(context: context) }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Crear fondo")
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            CreatePoolSheet(context: context, store: store)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.pools.isEmpty {
            VStack(spacing: Theme.Spacing.md) {
                RuulEmptyState(
                    title: "Sin fondos todavía",
                    systemImage: "banknote",
                    message: "Crea un bote para la próxima noche de juegos o un fondo con meta para un proyecto."
                )
                Button {
                    isShowingCreate = true
                } label: {
                    Label("Crear fondo", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else {
            List {
                Section {
                    ForEach(store.pools) { pool in
                        NavigationLink {
                            PoolDetailView(
                                poolAccountId: pool.poolAccountId,
                                context: context,
                                container: container
                            )
                        } label: {
                            poolRow(pool)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func poolRow(_ pool: PoolAccount) -> some View {
        HStack(spacing: 12) {
            Image(systemName: pool.policyKey == "equity_target" ? "target" : "banknote.fill")
                .foregroundStyle(pool.isOpen ? Theme.Tint.success : Theme.Text.tertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(pool.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(pool.policyLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text((pool.totals?.basisTotal ?? 0).compactCurrencyLabel(pool.currency ?? "MXN"))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.Text.primary)
                StatusBadge(pool.statusLabel, color: statusColor(pool))
            }
        }
    }

    private func statusColor(_ pool: PoolAccount) -> Color {
        switch pool.status {
        case "open": return Theme.Tint.success
        case "target_reached": return Theme.Tint.warning
        case "resolved": return .secondary
        case "cancelled": return Theme.Tint.critical
        default: return .secondary
        }
    }
}

#Preview("Fondos") {
    NavigationStack {
        PoolsListView(
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
