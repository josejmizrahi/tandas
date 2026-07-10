import SwiftUI
import RuulCore

/// R.8.E — Botes del contexto (pools): botes (winner_takes_all) y botes
/// con meta (equity_target). Backend = autoridad: nombres, totales y status
/// vienen de `list_context_pools`.
public struct PoolsListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: PoolsStore
    @State private var isShowingCreate = false
    /// 2026-06-21 — P0 #6 friend-group launch: swipe + tap accessory abre quick
    /// contribute sin pasar por PoolDetailView.
    @State private var quickContributeTarget: PoolAccount?

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
        .navigationTitle("Botes")
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
                .accessibilityLabel("Crear bote")
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            CreatePoolSheet(context: context, store: store)
        }
        .sheet(item: $quickContributeTarget) { pool in
            QuickContributeSheet(pool: pool, context: context, container: container, store: store)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.pools.isEmpty {
            VStack(spacing: Theme.Spacing.md) {
                RuulEmptyState(
                    title: "Sin botes todavía",
                    systemImage: "banknote",
                    message: "Crea un bote para la próxima noche de juegos o un bote con meta para un viaje."
                )
                Button {
                    isShowingCreate = true
                } label: {
                    Label("Crear bote", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
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
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if pool.isOpen {
                                Button {
                                    quickContributeTarget = pool
                                } label: {
                                    Label("Aportar", systemImage: "plus.circle.fill")
                                }
                                .tint(Theme.Tint.success)
                            }
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

// MARK: - Quick Contribute Sheet (P0 #6)

/// Sheet de aportación rápida desde la lista de botes. Friend-group launch:
/// el usuario ve "Bote del Mundial $4500" y quiere meter $500 sin entrar al
/// detalle. Swipe leading o tap "Aportar" abre este sheet 1-tap.
private struct QuickContributeSheet: View {
    let pool: PoolAccount
    let context: AppContext
    let container: DependencyContainer
    let store: PoolsStore

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var contributorId: UUID?
    @State private var runner = ActionRunner()

    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: ""))
    }
    private var currency: String { pool.currency ?? "MXN" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: pool.policyKey == "equity_target" ? "target" : "banknote.fill")
                            .foregroundStyle(Theme.Tint.success)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pool.displayName)
                                .font(.callout.weight(.semibold))
                            Text("Total: \((pool.totals?.basisTotal ?? 0).compactCurrencyLabel(currency))")
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                }

                Section("Aporte") {
                    HStack {
                        Text("$")
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                        Text(currency)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }

                ContributorPickerSection(
                    context: context,
                    container: container,
                    contributorId: $contributorId
                )

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Aportar").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled((amount ?? 0) <= 0 || runner.isRunning)
                } footer: {
                    Text("Tu aporte se suma al bote hasta que se resuelva.")
                }
            }
            .navigationTitle("Aportar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulCompactSheet()
    }

    private func submit() async {
        guard let amount else { return }
        let success = await runner.run {
            _ = try await store.contribute(
                ContributeToPoolInput(
                    poolAccountId: pool.poolAccountId,
                    basisKind: "cash",
                    amount: amount,
                    currency: currency,
                    clientId: UUID().uuidString,
                    contributorActorId: contributorId
                ),
                context: context
            )
        }
        if success { dismiss() }
    }
}

#Preview("Botes") {
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
