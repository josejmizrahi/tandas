import SwiftUI
import RuulCore

/// F.8 — lista de reglas del contexto.
public struct RulesListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: RulesStore
    @State private var isShowingCreate = false

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: RulesStore(rpc: container.rpc))
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
                rulesList
            }
        }
        .navigationTitle("Reglas")
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .toolbar {
            if store.canManage(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingCreate = true
                    } label: {
                        Label("Crear regla", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            CreateRuleWizard(context: context, store: store)
        }
    }

    @ViewBuilder
    private var rulesList: some View {
        if store.rules.isEmpty {
            EmptyStateView(
                symbolName: "ruler",
                title: "Sin reglas",
                message: "Las reglas convierten acuerdos en consecuencias automáticas: llegar tarde → multa, cancelar el mismo día → multa."
            )
        } else {
            List {
                ForEach(store.rules) { rule in
                    NavigationLink {
                        RuleDetailView(
                            rule: rule,
                            context: context,
                            container: container,
                            canManage: store.canManage(in: context),
                            onChanged: { Task { await store.load(context: context) } }
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "ruler.fill")
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.title)
                                    .lineLimit(1)
                                Text(rule.conditionDescription + " → " + rule.consequenceDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if rule.isActive {
                                StatusBadge("Activa", color: .green)
                            } else {
                                StatusBadge("Pausada", color: .gray)
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview("Reglas") {
    NavigationStack {
        RulesListView(
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
