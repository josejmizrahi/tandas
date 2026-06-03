import SwiftUI
import RuulCore

/// F.12 — settlement: generar el neteo de deudas abiertas, ver quién paga a
/// quién y marcar pagos (sin duplicar — el backend es idempotente).
public struct SettlementView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: SettlementStore
    @State private var runner = ActionRunner()
    @State private var currency = "MXN"
    @State private var generateNotice: String?

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: SettlementStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
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
                settlementList
            }
        }
        .navigationTitle("Settlement")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .actionErrorAlert(runner)
        .alert("Settlement", isPresented: Binding(
            get: { generateNotice != nil },
            set: { if !$0 { generateNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(generateNotice ?? "")
        }
    }

    // MARK: - Contenido

    @ViewBuilder
    private var settlementList: some View {
        List {
            // Generar
            if store.canSettle(in: context) {
                Section {
                    HStack {
                        Text("Moneda")
                        Spacer()
                        TextField("MXN", text: $currency)
                            .textInputAutocapitalization(.characters)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    Button {
                        Task { await generate() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Generar settlement", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(runner.isRunning)
                } footer: {
                    Text("Netea todas las deudas abiertas en \(currency) y calcula el mínimo número de transferencias para quedar a mano.")
                }
            }

            // Batches
            if store.batches.isEmpty {
                Section {
                    EmptyStateView(
                        symbolName: "checkmark.circle",
                        title: "Sin settlements",
                        message: "Cuando haya deudas abiertas, genera un settlement para liquidarlas con el mínimo de transferencias."
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(store.batches) { batch in
                    batchSection(batch)
                }
            }
        }
    }

    @ViewBuilder
    private func batchSection(_ batch: SettlementBatch) -> some View {
        let items = store.items(for: batch.id)
        let pendingCount = items.filter { !$0.isPaid }.count

        Section {
            ForEach(items) { item in
                itemRow(item, batch: batch)
            }
        } header: {
            HStack {
                Text(batch.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Settlement")
                Spacer()
                if batch.isFinalized {
                    StatusBadge("Liquidado", color: .green)
                } else {
                    StatusBadge("\(pendingCount) pendientes", color: .orange)
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: SettlementItem, batch: SettlementBatch) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(store.displayName(for: item.fromActorId))
                        .font(.callout.weight(.medium))
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.displayName(for: item.toActorId))
                        .font(.callout.weight(.medium))
                }
                Text(item.amount.currencyLabel(item.currency))
                    .font(.title3.bold())
                    .foregroundStyle(item.isPaid ? .secondary : .primary)
            }

            Spacer()

            if item.isPaid {
                Label("Pagado", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else if store.canMarkPaid(item, context: context, myActorId: myActorId) {
                // MarkPaidButton
                Button {
                    Task { await markPaid(item) }
                } label: {
                    Text("Marcar pagado")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(runner.isRunning)
            } else {
                StatusBadge("Pendiente", color: .orange)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Acciones

    private func generate() async {
        await runner.run {
            let result = try await store.generate(context: context, currency: currency)
            if result.batchId == nil {
                if result.items.isEmpty && result.message != nil {
                    generateNotice = result.obligationsNetted == nil
                        ? "No hay deudas abiertas en \(currency)."
                        : "Todas las deudas se netearon a cero — quedaron liquidadas sin transferencias."
                } else {
                    generateNotice = "No hay nada que liquidar."
                }
            } else {
                generateNotice = "Settlement generado: \(result.items.count) transferencia(s) para quedar a mano."
            }
        }
    }

    private func markPaid(_ item: SettlementItem) async {
        await runner.run {
            let result = try await store.markPaid(itemId: item.id, context: context, myActorId: myActorId)
            if result.alreadyPaid {
                generateNotice = "Ese pago ya estaba registrado — no se duplica."
            } else if result.batchFinalized {
                generateNotice = "¡Pago registrado! Todas las transferencias del settlement están completas."
            } else if let closed = result.obligationsClosed {
                generateNotice = "Pago registrado. \(closed) deuda(s) quedaron liquidadas."
            }
        }
    }
}

#Preview("Settlement") {
    NavigationStack {
        SettlementView(
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
