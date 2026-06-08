import SwiftUI
import RuulCore

/// F.10 — lista de decisiones del contexto (abiertas + historial).
public struct DecisionsListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: DecisionsStore
    @State private var isShowingCreate = false

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: DecisionsStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
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
                decisionsList
            }
        }
        .navigationTitle("Decisiones")
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
                        Label("Proponer", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            NavigationStack {
                CreateDecisionView(context: context, container: container)
            }
        }
    }

    @ViewBuilder
    private var decisionsList: some View {
        if store.decisions.isEmpty {
            EmptyStateView(
                symbolName: "checkmark.seal",
                title: "Sin decisiones",
                message: "Propón algo y que el contexto vote: cambiar una regla, aprobar un gasto, resolver un conflicto."
            )
        } else {
            List {
                if !store.open.isEmpty {
                    Section("Abiertas (\(store.open.count))") {
                        ForEach(store.open) { decision in
                            decisionRow(decision)
                        }
                    }
                }
                if !store.closed.isEmpty {
                    Section("Historial") {
                        ForEach(store.closed) { decision in
                            decisionRow(decision)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func decisionRow(_ decision: Decision) -> some View {
        NavigationLink {
            DecisionDetailView(decisionId: decision.id, context: context, container: container)
        } label: {
            LabeledContent {
                Text(decision.statusLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor(decision.status))
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(decision.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(2)
                        Text(decision.type.label + " · " + store.displayName(for: decision.createdByActorId))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(1)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(Theme.Tint.primary)
                }
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        Theme.Status.decision(status)
    }
}

#Preview("Decisiones") {
    NavigationStack {
        DecisionsListView(
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
