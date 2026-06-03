import SwiftUI
import RuulCore

/// F.11 — home de dinero del contexto: balances, obligaciones abiertas,
/// registrar gasto/multa/juego y entrar al settlement.
public struct MoneyHomeView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: MoneyStore
    @State private var isShowingExpense = false
    @State private var isShowingGameResult = false
    @State private var isShowingFine = false

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: MoneyStore(rpc: container.rpc))
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }

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
                moneyList
            }
        }
        .navigationTitle("Dinero")
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .toolbar {
            if store.canRecord(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isShowingExpense = true
                        } label: {
                            Label("Registrar gasto", systemImage: "cart")
                        }
                        Button {
                            isShowingGameResult = true
                        } label: {
                            Label("Resultado de juego", systemImage: "dice")
                        }
                        Button {
                            isShowingFine = true
                        } label: {
                            Label("Multa manual", systemImage: "exclamationmark.circle")
                        }
                    } label: {
                        Label("Registrar", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingExpense) {
            RecordExpenseView(context: context, store: store, container: container)
        }
        .sheet(isPresented: $isShowingGameResult) {
            RecordGameResultView(context: context, store: store, container: container)
        }
        .sheet(isPresented: $isShowingFine) {
            RecordFineView(context: context, store: store, container: container)
        }
    }

    // MARK: - Contenido

    @ViewBuilder
    private var moneyList: some View {
        List {
            // Mi balance
            Section {
                let myBalance = store.balance(for: myActorId)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tu balance en \(context.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(myBalance.currencyLabel(nil))
                            .font(.title.bold())
                            .foregroundStyle(myBalance < 0 ? .red : (myBalance > 0 ? .green : .primary))
                    }
                    Spacer()
                    Image(systemName: myBalance < 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(myBalance < 0 ? .red : .green)
                }
                .padding(.vertical, 4)

                Text(myBalance < 0 ? "Debes dinero" : (myBalance > 0 ? "Te deben dinero" : "Estás a mano"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Balances por miembro
            if !store.members.isEmpty {
                Section("Balances") {
                    ForEach(store.members) { member in
                        let balance = store.balance(for: member.actorId)
                        HStack(spacing: 12) {
                            ActorInitialsView(name: member.displayName, size: 32)
                            Text(member.displayName)
                            Spacer()
                            Text(balance.currencyLabel(nil))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(balance < 0 ? .red : (balance > 0 ? .green : .secondary))
                        }
                    }
                }
            }

            // Obligaciones abiertas
            obligationsSection

            // Settlement
            Section {
                NavigationLink {
                    SettlementView(context: context, container: container)
                } label: {
                    Label("Liquidar deudas (settlement)", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                }
            } footer: {
                Text("El settlement netea todas las deudas abiertas y calcula el mínimo de transferencias.")
            }
        }
    }

    @ViewBuilder
    private var obligationsSection: some View {
        Section("Cuentas abiertas (\(store.openObligations.count))") {
            if store.openObligations.isEmpty {
                Text("Nadie debe nada 🎉")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(store.openObligations) { obligation in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(store.displayName(for: obligation.debtorActorId, contextId: obligation.contextActorId)) → \(store.displayName(for: obligation.creditorActorId, contextId: obligation.contextActorId))")
                                .font(.callout)
                            Spacer()
                            Text((obligation.amount ?? 0).currencyLabel(obligation.currency))
                                .font(.callout.weight(.semibold))
                        }
                        HStack(spacing: 6) {
                            StatusBadge(obligation.typeLabel, color: obligationColor(obligation.obligationType))
                            if obligation.sourceRuleId != nil {
                                StatusBadge("Automática", color: .indigo)
                            }
                            if let created = obligation.createdAt {
                                Text(created.formatted(.relative(presentation: .named)))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func obligationColor(_ type: String) -> Color {
        switch type {
        case "fine", "sanction": return .red
        case "expense_share", "trip_share": return .blue
        case "game_debt": return .purple
        case "contribution", "dues": return .orange
        default: return .gray
        }
    }
}

#Preview("Dinero") {
    NavigationStack {
        MoneyHomeView(
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
