import SwiftUI
import RuulCore

/// R.8.E/F — detalle de un fondo: total, aportes, acción "Aportar" y flujo
/// "Resolver" (winner_takes_all → picker de ganador + confirmación
/// destructiva; equity_target → confirmación destructiva directa).
/// Toda acción visible nace de `available_actions[]` del backend (F.2X).
public struct PoolDetailView: View {
    let poolAccountId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: PoolDetailStore
    @State private var runner = ActionRunner()
    @State private var isShowingContribute = false
    /// winner_takes_all — contributor elegido pendiente de confirmar.
    @State private var pendingWinner: PoolResolutionContributor?
    /// equity_target — confirmación directa.
    @State private var isConfirmingEquityResolve = false
    @State private var resultNotice: String?

    public init(poolAccountId: UUID, context: AppContext, container: DependencyContainer) {
        self.poolAccountId = poolAccountId
        self.context = context
        self.container = container
        _store = State(initialValue: PoolDetailStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState()

            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(poolAccountId: poolAccountId) }
                }

            case .loaded:
                if let detail = store.detail {
                    content(detail)
                }
            }
        }
        .navigationTitle(store.detail?.poolAccount.policyLabel ?? "Fondo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load(poolAccountId: poolAccountId) }
        .refreshable { await store.load(poolAccountId: poolAccountId) }
        .actionErrorAlert(runner)
        .sheet(isPresented: $isShowingContribute) {
            ContributePoolSheet(
                poolAccountId: poolAccountId,
                currency: store.detail?.poolAccount.currency ?? "MXN",
                store: store
            )
        }
        .confirmationDialog(
            pendingWinner.map { "¿Pagar el bote a \(displayName($0))?" } ?? "",
            isPresented: Binding(
                get: { pendingWinner != nil },
                set: { if !$0 { pendingWinner = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let winner = pendingWinner {
                Button(
                    "Resolver y pagar",
                    role: ActionPresentationCatalog.isDestructive(for: "pool.resolve") ? .destructive : nil
                ) {
                    Task { await resolve(winner: winner) }
                }
            }
            Button("Cancelar", role: .cancel) { pendingWinner = nil }
        } message: {
            if let payout = store.resolutionPreview?.payoutAmount,
               let currency = store.resolutionPreview?.payoutCurrency ?? store.detail?.poolAccount.currency {
                Text("Se pagará \(payout.currencyLabel(currency)) y el fondo quedará resuelto. Esta acción no se puede deshacer.")
            } else {
                Text("El fondo quedará resuelto. Esta acción no se puede deshacer.")
            }
        }
        .confirmationDialog(
            "¿Resolver el fondo?",
            isPresented: $isConfirmingEquityResolve,
            titleVisibility: .visible
        ) {
            Button(
                "Resolver fondo",
                role: ActionPresentationCatalog.isDestructive(for: "pool.resolve") ? .destructive : nil
            ) {
                Task { await resolve(winner: nil) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Las participaciones quedarán fijadas según lo aportado. Esta acción no se puede deshacer.")
        }
        .alert("Fondo resuelto", isPresented: Binding(
            get: { resultNotice != nil },
            set: { if !$0 { resultNotice = nil } }
        )) {
            Button("OK") { resultNotice = nil }
        } message: {
            Text(resultNotice ?? "")
        }
    }

    // MARK: - Contenido

    @ViewBuilder
    private func content(_ detail: PoolAccountDetail) -> some View {
        List {
            heroSection(detail)
            aportesSection(detail)
            if let preview = store.resolutionPreview, preview.isResolvable {
                previewSection(detail, preview: preview)
            }
            accionesSection(detail)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Preview de la resolución (R.8.C)

    /// Surface de `preview_pool_resolution`: composición del pot
    /// (winner_takes_all) o shares por contribuyente (equity_target).
    /// Solo aparece si la acción `pool.resolve` está disponible y la
    /// preview cargó. Cierra el gap "preview_pool_resolution — sin UI".
    @ViewBuilder
    private func previewSection(_ detail: PoolAccountDetail, preview: PoolResolutionPreview) -> some View {
        let currency = preview.payoutCurrency
            ?? preview.currency
            ?? detail.poolAccount.currency
            ?? "MXN"
        Section {
            if detail.poolAccount.policyKey == "winner_takes_all" {
                if let payout = preview.payoutAmount {
                    LabeledContent {
                        Text(payout.currencyLabel(currency))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.Tint.success)
                    } label: {
                        Label("Pago al ganador", systemImage: "trophy.fill")
                    }
                }
                if let stake = preview.stakeTotal, stake > 0 {
                    LabeledContent {
                        Text(stake.currencyLabel(currency))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.Text.secondary)
                    } label: {
                        Label("Apuestas pendientes", systemImage: "person.line.dotted.person")
                    }
                }
            } else {
                if let target = preview.targetAmount, target > 0 {
                    let progress = min(preview.totalBasis / target, 1)
                    ProgressView(value: progress) {
                        HStack {
                            Text("Progreso a meta")
                                .font(.callout)
                                .foregroundStyle(Theme.Text.primary)
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                    if let remaining = preview.remainingToTarget, remaining > 0 {
                        LabeledContent {
                            Text(remaining.currencyLabel(currency))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.Text.secondary)
                        } label: {
                            Label("Falta", systemImage: "arrow.up.right")
                        }
                    }
                }
                ForEach(preview.contributors) { contributor in
                    HStack(spacing: 12) {
                        ActorInitialsView(name: contributor.displayName ?? "?", size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(contributor.displayName ?? "Alguien")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text(contributor.basisAmount.currencyLabel(currency))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.Text.secondary)
                        }
                        Spacer(minLength: 12)
                        Text("\(Int((contributor.share * 100).rounded()))%")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.Tint.success)
                    }
                }
            }
            ForEach(preview.warnings, id: \.self) { warning in
                Label {
                    Text(warningCopy(warning))
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Tint.warning)
                }
            }
        } header: {
            Text("Vista previa de la resolución")
        } footer: {
            Text(previewFooter(detail.poolAccount.policyKey))
        }
    }

    private func previewFooter(_ policyKey: String) -> String {
        switch policyKey {
        case "winner_takes_all":
            return "El bote completo se pagará a la persona ganadora al resolver."
        case "equity_target":
            return "Cada contribuyente recibirá una participación proporcional a su aporte."
        default:
            return "Resolución según la política del fondo."
        }
    }

    /// Traduce los warnings canónicos (texto crudo del backend en inglés) a
    /// copy en español para el founder locale.
    private func warningCopy(_ raw: String) -> String {
        switch raw {
        case let s where s.contains("mixed currencies"):
            return "Mezcla de monedas — la resolución va a fallar hasta normalizar."
        case let s where s.contains("no basis entries"):
            return "Aún no hay aportes para resolver."
        case let s where s.contains("asset/service basis is excluded"):
            return "Las aportaciones en activo/servicio no se pagan en efectivo (transferencia manual)."
        case let s where s.contains("total basis is below target_amount"):
            return "El total aportado todavía no llega a la meta."
        case let s where s.contains("pool is not resolvable"):
            return "El fondo no está en un estado resolvible."
        default:
            return raw
        }
    }

    @ViewBuilder
    private func heroSection(_ detail: PoolAccountDetail) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(detail.poolAccount.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Text.primary)
                    Spacer()
                    StatusBadge(detail.poolAccount.statusLabel, color: statusColor(detail.poolAccount))
                }
                Text(detail.totals.basisTotal.compactCurrencyLabel(detail.poolAccount.currency ?? "MXN"))
                    .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.Tint.success)
                if let target = detail.poolAccount.targetAmount, target > 0 {
                    ProgressView(value: min(detail.totals.basisTotal / target, 1))
                    Text("Meta: \(target.compactCurrencyLabel(detail.poolAccount.currency ?? "MXN"))")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
                if detail.totals.myBasis > 0 {
                    Text("Tu aporte: \(detail.totals.myBasis.compactCurrencyLabel(detail.poolAccount.currency ?? "MXN"))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Text.secondary)
                }
                // Slice 7.A.6 — política explicada en hero (no solo en footer
                // del bloque Acciones), para que el usuario entienda CUÁL es
                // la mecánica del bote antes de aportar.
                if let policyHint = policyHint(detail.poolAccount.policyKey) {
                    Label {
                        Text(policyHint)
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                    .padding(.top, 4)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 8, trailing: 4))
        }
    }

    /// Slice 7.A.6 — copy explícito de las 3 políticas R.8 firmadas.
    private func policyHint(_ policyKey: String) -> String? {
        switch policyKey {
        case "winner_takes_all":
            return "El bote completo se paga a una sola persona ganadora al cerrarlo."
        case "equity_target":
            return "Cada participante recupera su aporte cuando se cierre el fondo."
        case "proportional":
            return "Las ganancias se reparten en proporción a lo que aportó cada quien."
        default:
            return nil
        }
    }

    @ViewBuilder
    private func aportesSection(_ detail: PoolAccountDetail) -> some View {
        Section {
            if detail.basisEntries.isEmpty {
                Text("Nadie ha aportado todavía.")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(detail.basisEntries) { entry in
                    HStack(spacing: 12) {
                        ActorInitialsView(name: entry.contributorDisplayName ?? "?", size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.contributorDisplayName ?? "Alguien")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text(entry.basisKindLabel)
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(entry.basisAmount.compactCurrencyLabel(entry.currency ?? detail.poolAccount.currency ?? "MXN"))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.Text.primary)
                    }
                }
            }
        } header: {
            Text("Aportes (\(detail.totals.entryCount))")
        }
    }

    @ViewBuilder
    private func accionesSection(_ detail: PoolAccountDetail) -> some View {
        let contribute = detail.action("pool.contribute")
        let resolve = detail.action("pool.resolve")
        if contribute != nil || resolve != nil {
            Section {
                if let contribute {
                    Button {
                        isShowingContribute = true
                    } label: {
                        Label(
                            contribute.label,
                            systemImage: ActionPresentationCatalog.presentation(for: contribute.actionKey).symbolName
                        )
                    }
                    .disabled(runner.isRunning)
                }
                if let resolve, store.resolutionPreview?.isResolvable != false {
                    resolveControl(detail, action: resolve)
                }
            } header: {
                Text("Qué puedes hacer")
            } footer: {
                if detail.poolAccount.policyKey == "winner_takes_all", resolve != nil {
                    Text("Al resolver, el bote completo se paga a la persona ganadora.")
                }
            }
        }
    }

    /// winner_takes_all → Menu con los contribuyentes (el ganador se elige al
    /// resolver); equity_target → botón directo con confirmación.
    @ViewBuilder
    private func resolveControl(_ detail: PoolAccountDetail, action: AvailableAction) -> some View {
        let symbol = ActionPresentationCatalog.presentation(for: action.actionKey).symbolName
        if detail.poolAccount.policyKey == "winner_takes_all" {
            Menu {
                Section("¿Quién ganó?") {
                    ForEach(winnerCandidates(detail)) { candidate in
                        Button {
                            pendingWinner = candidate
                        } label: {
                            Label(displayName(candidate), systemImage: "person.fill")
                        }
                    }
                }
            } label: {
                Label(action.label, systemImage: symbol)
            }
            .disabled(runner.isRunning)
        } else {
            Button {
                isConfirmingEquityResolve = true
            } label: {
                Label(action.label, systemImage: symbol)
            }
            .disabled(runner.isRunning)
        }
    }

    // MARK: - Lógica

    /// Ganador elegible: contribuyentes del pool (del preview si está; si no,
    /// derivados del basis ledger).
    private func winnerCandidates(_ detail: PoolAccountDetail) -> [PoolResolutionContributor] {
        if let contributors = store.resolutionPreview?.contributors, !contributors.isEmpty {
            return contributors
        }
        var seen: Set<UUID> = []
        var candidates: [PoolResolutionContributor] = []
        for entry in detail.basisEntries where !seen.contains(entry.contributorActorId) {
            seen.insert(entry.contributorActorId)
            candidates.append(PoolResolutionContributor(
                actorId: entry.contributorActorId,
                displayName: entry.contributorDisplayName,
                basisAmount: entry.basisAmount,
                share: 0
            ))
        }
        return candidates
    }

    private func displayName(_ contributor: PoolResolutionContributor) -> String {
        contributor.displayName ?? "Alguien"
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

    private func resolve(winner: PoolResolutionContributor?) async {
        let winnerName = winner.map(displayName(_:))
        pendingWinner = nil
        let success = await runner.run {
            let resolution: JSONValue? = winner.map {
                .object(["winner_actor_id": .string($0.actorId.uuidString)])
            }
            let result = try await store.resolve(
                poolAccountId: poolAccountId,
                resolution: resolution,
                clientId: UUID().uuidString
            )
            if let payout = result.payoutAmount, let winnerName {
                resultNotice = "Se pagó \(payout.currencyLabel(result.payoutCurrency)) a \(winnerName)."
            } else {
                resultNotice = "El fondo quedó resuelto."
            }
        }
        if !success {
            resultNotice = nil
        }
    }
}

// MARK: - Sheet de aporte

/// R.8.E — aporte simple en efectivo al fondo (`contribute_to_pool`,
/// basis_kind='cash').
///
/// Issue 2 founder (audit 2026-06-14, BLOQUEADO BACKEND) — el founder pidió
/// poder "registrar un aporte de otra persona" (caso: admin/treasurer recibe
/// efectivo y lo registra a nombre del aportante). El RPC backend
/// `contribute_to_pool` actualmente NO acepta `p_contributor_actor_id`: el
/// contributor se infiere del caller. Se requiere update backend antes de
/// poder cablear un picker "A nombre de" aquí. Documentar en backlog R.8 y
/// agregar `p_contributor_actor_id` (opcional, con permission check
/// `pool.contribute_on_behalf` o `money.settle`).
private struct ContributePoolSheet: View {
    let poolAccountId: UUID
    let currency: String
    let store: PoolDetailStore

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var runner = ActionRunner()

    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: "")) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tu aporte") {
                    HStack {
                        Text("$")
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                        Text(currency)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await contribute() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Aportar").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled((amount ?? 0) <= 0 || runner.isRunning)
                } footer: {
                    Text("El aporte queda registrado en el fondo hasta que se resuelva.")
                }
            }
            .navigationTitle("Aportar al fondo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private func contribute() async {
        guard let amount else { return }
        let success = await runner.run {
            _ = try await store.contribute(ContributeToPoolInput(
                poolAccountId: poolAccountId,
                basisKind: "cash",
                amount: amount,
                currency: currency,
                clientId: UUID().uuidString
            ))
        }
        if success { dismiss() }
    }
}

#Preview("Detalle de fondo") {
    NavigationStack {
        PoolDetailView(
            poolAccountId: MockRuulRPCClient.DemoIds.boteCena,
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
