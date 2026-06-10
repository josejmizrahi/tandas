import SwiftUI
import RuulCore

/// R.5Z.fix.SETTLEMENT.REDESIGN (2026-06-10 founder) — rediseño completo
/// Apple-native + 2-way handshake.
///
/// Doctrina Ruul (founder lock):
/// - List + Section, no custom cards.
/// - Hero section con balance neto del usuario.
/// - Section "Te deben" (yo soy creditor) + Section "Debes" (yo soy debtor).
/// - Tap row → bottom sheet con detalle + acciones canónicas según rol.
/// - Status badges semánticos:
///   * `pending` → "Pendiente" (warning).
///   * `pending_confirmation` → "Esperando confirmación" / "Confirma este pago"
///     según rol (high prio en el lado creditor).
///   * `paid` → "Liquidado" (success), colapsable.
///
/// 2-way handshake:
/// - Debtor marca pagado → status='pending_confirmation' + attention al creditor.
/// - Creditor confirma o rechaza (con razón).
/// - Si rechaza, el debtor recibe attention prioridad alta.
public struct SettlementView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: SettlementStore
    @State private var runner = ActionRunner()
    @State private var currency = "MXN"
    @State private var generateNotice: String?
    /// Item seleccionado para mostrar el bottom sheet con acciones.
    @State private var selectedItemId: UUID?
    /// Reject flow: muestra TextField para razón.
    @State private var isShowingRejectSheet = false
    @State private var rejectReason = ""
    @State private var rejectTargetItemId: UUID?
    /// R.5Z.fix.SETTLEMENT.APPEAL — debtor apela el rechazo del creditor.
    @State private var isShowingAppealSheet = false
    @State private var appealReason = ""
    @State private var appealTargetItemId: UUID?
    @State private var showsPaidHistory = false

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
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(context: context) }
                }
            case .loaded:
                settlementList
            }
        }
        .navigationTitle("Liquidaciones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.canSettle(in: context) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await generate() }
                        } label: {
                            Label("Recalcular", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(runner.isRunning)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Más opciones")
                }
            }
        }
        .task {
            await store.load(context: context)
            await autoGenerate()
        }
        .refreshable {
            await store.load(context: context)
            await autoGenerate()
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
        }
        .actionErrorAlert(runner)
        .alert("Liquidación", isPresented: Binding(
            get: { generateNotice != nil },
            set: { if !$0 { generateNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(generateNotice ?? "")
        }
        .sheet(item: Binding(
            get: { selectedItemId.map { ItemSheetWrapper(id: $0) } },
            set: { selectedItemId = $0?.id }
        )) { wrapper in
            if let item = activeItems.first(where: { $0.id == wrapper.id }) {
                ItemActionsSheet(
                    item: item,
                    fromName: store.displayName(for: item.fromActorId),
                    toName: store.displayName(for: item.toActorId),
                    myRole: roleFor(item),
                    isRunning: runner.isRunning,
                    onMarkPaid: { Task { await markPaid(item) } },
                    onConfirm: { Task { await confirmPaid(item) } },
                    onReject: {
                        rejectTargetItemId = item.id
                        rejectReason = ""
                        isShowingRejectSheet = true
                        selectedItemId = nil
                    },
                    onAppeal: {
                        appealTargetItemId = item.id
                        appealReason = ""
                        isShowingAppealSheet = true
                        selectedItemId = nil
                    },
                    canResolveAsAdmin: canResolveAsAdmin
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $isShowingRejectSheet) {
            rejectReasonSheet
        }
        .sheet(isPresented: $isShowingAppealSheet) {
            appealReasonSheet
        }
    }

    private var canResolveAsAdmin: Bool {
        store.canSettle(in: context)
    }

    // MARK: - Sectioned list

    private var activeItems: [SettlementItem] {
        store.batches.flatMap { store.items(for: $0.id) }.filter { !$0.isPaid }
    }
    private var paidItems: [SettlementItem] {
        store.batches.flatMap { store.items(for: $0.id) }.filter { $0.isPaid }
    }
    /// Items donde yo soy creditor activos.
    private var theyOweMe: [SettlementItem] {
        activeItems.filter { $0.toActorId == myActorId }
    }
    /// Items donde yo soy debtor activos.
    private var iOwe: [SettlementItem] {
        activeItems.filter { $0.fromActorId == myActorId }
    }
    /// Items que no me involucran (admin view).
    private var others: [SettlementItem] {
        activeItems.filter { $0.fromActorId != myActorId && $0.toActorId != myActorId }
    }

    @ViewBuilder
    private var settlementList: some View {
        List {
            heroSection
            if theyOweMe.isEmpty && iOwe.isEmpty && others.isEmpty && paidItems.isEmpty {
                emptyStateSection
            } else {
                if !theyOweMe.isEmpty { theyOweMeSection }
                if !iOwe.isEmpty       { iOweSection }
                if !others.isEmpty     { othersSection }
                if !paidItems.isEmpty  { paidHistorySection }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var heroSection: some View {
        let netCredit = theyOweMe.reduce(0) { $0 + $1.amount }
        let netDebit = iOwe.reduce(0) { $0 + $1.amount }
        let net = netCredit - netDebit
        let currency = (theyOweMe.first?.currency ?? iOwe.first?.currency ?? "MXN")

        Section {
            HStack(spacing: 14) {
                Image(systemName: net >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(net >= 0 ? Theme.Tint.success : Theme.Tint.critical)
                VStack(alignment: .leading, spacing: 4) {
                    Text(net >= 0 ? "Te deben en neto" : "Debes en neto")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                    Text(abs(net).currencyLabel(currency))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(Theme.Text.primary)
                }
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if !theyOweMe.isEmpty || !iOwe.isEmpty {
                HStack {
                    if !theyOweMe.isEmpty {
                        Label("\(theyOweMe.count) por cobrar", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.Tint.success)
                    }
                    Spacer()
                    if !iOwe.isEmpty {
                        Label("\(iOwe.count) por pagar", systemImage: "arrow.up.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.Tint.warning)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    @ViewBuilder
    private var emptyStateSection: some View {
        Section {
            RuulEmptyState(
                title: "Todo al día",
                systemImage: "checkmark.seal.fill",
                message: "No hay transferencias pendientes. Cuando registres gastos, las liquidaciones aparecen acá con el mínimo de transferencias para quedar a mano."
            )
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var theyOweMeSection: some View {
        Section {
            ForEach(theyOweMe) { item in
                Button {
                    selectedItemId = item.id
                } label: {
                    itemRow(item, role: .creditor)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Te deben")
        } footer: {
            Text("Toca un cobro para confirmar o reportar un problema con el pago.")
        }
    }

    @ViewBuilder
    private var iOweSection: some View {
        Section {
            ForEach(iOwe) { item in
                Button {
                    selectedItemId = item.id
                } label: {
                    itemRow(item, role: .debtor)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Debes")
        } footer: {
            Text("Toca una deuda para marcarla como pagada. El otro lado confirma o reporta.")
        }
    }

    @ViewBuilder
    private var othersSection: some View {
        Section {
            ForEach(others) { item in
                Button {
                    selectedItemId = item.id
                } label: {
                    itemRow(item, role: .observer)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Otras transferencias")
        }
    }

    @ViewBuilder
    private var paidHistorySection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsPaidHistory) {
                ForEach(paidItems) { item in
                    itemRow(item, role: roleFor(item))
                }
            } label: {
                Label("Historial liquidado (\(paidItems.count))", systemImage: "tray.full")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
        }
    }

    // MARK: - Row

    enum Role { case creditor, debtor, observer }

    private func roleFor(_ item: SettlementItem) -> Role {
        if item.toActorId == myActorId { return .creditor }
        if item.fromActorId == myActorId { return .debtor }
        return .observer
    }

    @ViewBuilder
    private func itemRow(_ item: SettlementItem, role: Role) -> some View {
        HStack(spacing: 12) {
            ActorInitialsView(name: counterpartName(item, role: role), size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(counterpartName(item, role: role))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                Text(item.amount.currencyLabel(item.currency))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(amountTint(item, role: role))
            }
            Spacer(minLength: 0)
            statusBadge(item, role: role)
        }
        .padding(.vertical, 4)
    }

    private func counterpartName(_ item: SettlementItem, role: Role) -> String {
        switch role {
        case .creditor: return store.displayName(for: item.fromActorId)
        case .debtor:   return store.displayName(for: item.toActorId)
        case .observer: return "\(store.displayName(for: item.fromActorId)) → \(store.displayName(for: item.toActorId))"
        }
    }

    private func amountTint(_ item: SettlementItem, role: Role) -> Color {
        if item.isPaid { return Theme.Text.secondary }
        switch role {
        case .creditor: return Theme.Tint.success
        case .debtor:   return Theme.Text.primary
        case .observer: return Theme.Text.primary
        }
    }

    @ViewBuilder
    private func statusBadge(_ item: SettlementItem, role: Role) -> some View {
        if item.isPaid {
            Label("Liquidado", systemImage: "checkmark.seal.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.Tint.success)
                .font(.title3)
        } else if item.isPendingConfirmation {
            if role == .creditor {
                Label("Por confirmar", systemImage: "bell.badge.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Tint.warning.opacity(0.15), in: Capsule())
                    .foregroundStyle(Theme.Tint.warning)
            } else {
                Label("Esperando", systemImage: "hourglass")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Tint.info.opacity(0.15), in: Capsule())
                    .foregroundStyle(Theme.Tint.info)
            }
        } else {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary)
        }
    }

    // MARK: - Reject sheet

    @ViewBuilder
    private var rejectReasonSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("¿Qué pasó? (opcional)", text: $rejectReason, axis: .vertical)
                        .lineLimit(3...5)
                } header: {
                    Text("Reportar problema")
                } footer: {
                    Text("Quien marcó el pago va a ver tu reporte como alerta de alta prioridad.")
                }
                Section {
                    Button(role: .destructive) {
                        Task { await rejectPaid() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Reportar y reabrir").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(runner.isRunning)
                }
            }
            .navigationTitle("Reportar pago")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { isShowingRejectSheet = false }
                }
            }
            .actionErrorAlert(runner)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Actions

    private func autoGenerate() async {
        guard store.canSettle(in: context) else { return }
        _ = try? await store.generate(context: context, currency: currency)
    }

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
                generateNotice = "Liquidación generada: \(result.items.count) transferencia(s)."
            }
        }
    }

    private func markPaid(_ item: SettlementItem) async {
        await runner.run {
            let result = try await store.markPaid(itemId: item.id, context: context, myActorId: myActorId)
            if result.alreadyPaid {
                generateNotice = "Ese pago ya estaba registrado."
            }
        }
        selectedItemId = nil
    }

    private func confirmPaid(_ item: SettlementItem) async {
        await runner.run {
            _ = try await container.rpc.confirmSettlementPaid(itemId: item.id)
            await store.load(context: context)
        }
        selectedItemId = nil
    }

    private func rejectPaid() async {
        guard let id = rejectTargetItemId else { return }
        let reason = rejectReason.trimmingCharacters(in: .whitespaces)
        await runner.run {
            try await container.rpc.rejectSettlementPaid(itemId: id, reason: reason.isEmpty ? nil : reason)
            await store.load(context: context)
        }
        isShowingRejectSheet = false
        rejectReason = ""
        rejectTargetItemId = nil
    }

    private func appealPaid() async {
        guard let id = appealTargetItemId else { return }
        let reason = appealReason.trimmingCharacters(in: .whitespaces)
        await runner.run {
            try await container.rpc.appealSettlementPaid(itemId: id, reason: reason.isEmpty ? nil : reason)
            await store.load(context: context)
        }
        isShowingAppealSheet = false
        appealReason = ""
        appealTargetItemId = nil
    }

    @ViewBuilder
    private var appealReasonSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Explica por qué insistís (opcional)", text: $appealReason, axis: .vertical)
                        .lineLimit(3...5)
                } header: {
                    Text("Apelar")
                } footer: {
                    Text("La transferencia pasa a disputa. Los administradores (money.settle) deciden si se confirma como pagada o no.")
                }
                Section {
                    Button {
                        Task { await appealPaid() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Apelar al admin").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(runner.isRunning)
                }
            }
            .navigationTitle("Apelar el pago")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { isShowingAppealSheet = false }
                }
            }
            .actionErrorAlert(runner)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Bottom sheet con acciones por item

private struct ItemActionsSheet: View {
    let item: SettlementItem
    let fromName: String
    let toName: String
    let myRole: SettlementView.Role
    let isRunning: Bool
    let onMarkPaid: () -> Void
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onAppeal: () -> Void
    let canResolveAsAdmin: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(fromName) → \(toName)")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text(item.amount.currencyLabel(item.currency))
                                .font(.title2.bold().monospacedDigit())
                                .foregroundStyle(Theme.Text.primary)
                        }
                        Spacer()
                    }
                } header: {
                    Text("Transferencia")
                }

                Section {
                    statusInfo
                }

                actionsSection
            }
            .navigationTitle("Liquidación")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var statusInfo: some View {
        if item.isPending {
            Label("Pendiente de pago", systemImage: "hourglass")
                .foregroundStyle(Theme.Tint.warning)
        } else if item.isPendingConfirmation {
            if myRole == .creditor {
                Label("\(fromName) dice que te pagó. Confirma para liquidar.", systemImage: "bell.badge.fill")
                    .foregroundStyle(Theme.Tint.warning)
            } else if myRole == .debtor {
                Label("Esperando que \(toName) confirme el pago.", systemImage: "hourglass")
                    .foregroundStyle(Theme.Tint.info)
            } else {
                Label("El pago está esperando confirmación.", systemImage: "hourglass")
                    .foregroundStyle(Theme.Tint.info)
            }
        } else if item.isDisputed {
            Label("En disputa — un admin tiene que resolver.", systemImage: "scale.3d")
                .foregroundStyle(Theme.Tint.critical)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            switch (myRole, item.status) {
            case (.debtor, "pending"):
                Button {
                    onMarkPaid()
                } label: {
                    Label("Marcar como pagado", systemImage: "checkmark.circle.fill")
                }
                .disabled(isRunning)
                // Si fue rechazado antes (metadata.rejected_at), también puede apelar.
                if item.metadata?["rejected_at"] != nil {
                    Button(role: .destructive) {
                        onAppeal()
                    } label: {
                        Label("Apelar al admin", systemImage: "scale.3d")
                    }
                    .disabled(isRunning)
                }
            case (.creditor, "pending_confirmation"):
                Button {
                    onConfirm()
                } label: {
                    Label("Confirmar pago", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.Tint.success)
                }
                .disabled(isRunning)
                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("Reportar problema", systemImage: "exclamationmark.triangle")
                }
                .disabled(isRunning)
            case (.creditor, "pending"):
                Button {
                    onConfirm()
                } label: {
                    Label("Marcar como recibido", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.Tint.success)
                }
                .disabled(isRunning)
            case (.debtor, "pending_confirmation"):
                Button(role: .destructive) {
                    onAppeal()
                } label: {
                    Label("Apelar al admin", systemImage: "scale.3d")
                }
                .disabled(isRunning)
            case (_, "disputed"):
                if canResolveAsAdmin {
                    Button {
                        onConfirm()
                    } label: {
                        Label("Confirmar el pago", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.Tint.success)
                    }
                    .disabled(isRunning)
                    Button(role: .destructive) {
                        onReject()
                    } label: {
                        Label("Marcar como NO pagado", systemImage: "xmark.circle")
                    }
                    .disabled(isRunning)
                } else {
                    Label("Esperando resolución del admin", systemImage: "hourglass")
                        .foregroundStyle(Theme.Text.secondary)
                }
            default:
                EmptyView()
            }
        } header: {
            Text("Acciones")
        }
    }
}

// MARK: - Helpers

private struct ItemSheetWrapper: Identifiable { let id: UUID }

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
