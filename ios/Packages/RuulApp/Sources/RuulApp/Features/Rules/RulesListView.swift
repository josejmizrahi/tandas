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
            // R.6.E.2 — Apple-native List: Section header + Label nativo (chevron
            // auto via NavigationLink) + status como trailing texto, sin custom HStack.
            List {
                Section {
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
                            LabeledContent {
                                Text(rule.isActive ? "Activa" : "Pausada")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(rule.isActive ? Theme.Tint.success : Theme.Text.tertiary)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.title).lineLimit(1)
                                        Text(rule.conditionDescription + " → " + rule.consequenceDescription)
                                            .font(.caption)
                                            .foregroundStyle(Theme.Text.secondary)
                                            .lineLimit(2)
                                    }
                                } icon: {
                                    Image(systemName: "ruler.fill")
                                        .foregroundStyle(Theme.Tint.primary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(store.rules.count) regla\(store.rules.count == 1 ? "" : "s")")
                } footer: {
                    Text("Las reglas se evalúan automáticamente cada vez que ocurre el evento. Las multas aparecen como obligaciones; las alertas aparecen en \"Atención\".")
                }
            }
            .listStyle(.insetGrouped)
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
