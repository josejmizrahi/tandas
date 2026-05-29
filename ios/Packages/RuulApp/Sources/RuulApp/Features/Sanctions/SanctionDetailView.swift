import SwiftUI
import RuulCore

/// Detail surface for a single `GroupSanction` (Primitiva 11). Read +
/// act surface: shows full info + two context-aware actions — Pagar
/// (monetaria, dirigida a mí, obligation abierta) y, según quien mire,
/// **Apelar** (yo soy el sancionado) o **Disputar** (soy tercero).
/// Ambas abren `DisputeSanctionSheet`; el path de escalada a voto
/// vive dentro de la disputa resultante (`EscalateDisputeSheet`).
///
/// Closed sanctions (completed/reversed/cancelled) muestran un hint
/// neutro y ocultan las acciones — la fila sigue navegable para que el
/// historial tenga superficie consultable.
public struct SanctionDetailView: View {
    let container: DependencyContainer
    let groupId: UUID
    let myMembershipId: UUID
    let sanction: GroupSanction

    @State private var pendingPaySanction: GroupSanction?
    /// V2-G4.1 — payment progress hidratado on appear.
    @State private var paymentStatus: SanctionPaymentStatus?
    /// V2-G4.2 — active payment plan, or nil if none.
    @State private var paymentPlan: SanctionPaymentPlan?
    @State private var isShowingProposePlan: Bool = false
    @State private var isCancellingPlan: Bool = false

    public init(
        container: DependencyContainer,
        groupId: UUID,
        myMembershipId: UUID,
        sanction: GroupSanction
    ) {
        self.container = container
        self.groupId = groupId
        self.myMembershipId = myMembershipId
        self.sanction = sanction
    }

    @State private var pendingDisputeNav: GroupDispute?

    public var body: some View {
        @Bindable var disputesStore = container.disputesStore
        return List {
            heroSection
            linkedDisputeSection
            infoSection
            progressSection
            paymentPlanSection
            paymentHistorySection
            actionsSection
        }
        .navigationTitle(L10n.SanctionDetail.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pendingDisputeNav) { dispute in
            DisputeDetailView(
                store: container.disputesStore,
                groupId: groupId,
                dispute: dispute
            )
        }
        .task {
            await loadPaymentStatus()
            // V3 Batch B-4 — necesitamos disputesStore.disputes para
            // resolver el dispute_id del sanction client-side.
            if sanction.disputeId != nil {
                await container.disputesStore.refreshIfNeeded(groupId: groupId)
            }
        }
        .sheet(item: $pendingPaySanction) { sanction in
            PaySanctionSheet(
                container: container,
                groupId: groupId,
                myMembershipId: myMembershipId,
                sanction: sanction
            ) {
                pendingPaySanction = nil
                Task {
                    await container.moneyStore.refresh(groupId: groupId, membershipId: myMembershipId)
                    await container.sanctionsStore.refresh(groupId: groupId)
                    await loadPaymentStatus()
                }
            }
        }
        .sheet(isPresented: $isShowingProposePlan) {
            if let status = paymentStatus, status.amountOutstanding > 0 {
                ProposePaymentPlanSheet(
                    container: container,
                    sanction: sanction,
                    paymentStatus: status
                ) {
                    isShowingProposePlan = false
                    Task { await loadPaymentStatus() }
                }
            }
        }
        .sheet(isPresented: $disputesStore.isDisputeSanctionPresented) {
            DisputeSanctionSheet(store: disputesStore, groupId: groupId)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: sanction.kind.systemImageName)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(sanction.isDisputed ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    .frame(width: 80, height: 80)
                    .background(.thinMaterial, in: Circle())

                VStack(spacing: 4) {
                    Text(sanction.kind.label)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(sanction.status.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(sanction.isDisputed
                                            ? Color.orange.opacity(0.18)
                                            : Color.gray.opacity(0.12))
                        )
                        .foregroundStyle(sanction.isDisputed
                                          ? AnyShapeStyle(.orange)
                                          : AnyShapeStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Linked Dispute (V3 Batch B-4)

    /// Universal Detail Context bloque — cuando hay disputa abierta
    /// contra esta sanción, surface el link directo. Resuelto client-
    /// side desde disputesStore.disputes; si todavía no se cargó la
    /// lista, mostramos el link con label genérico para no bloquear el
    /// flow.
    @ViewBuilder
    private var linkedDisputeSection: some View {
        if let disputeId = sanction.disputeId {
            let linked = container.disputesStore.disputes
                .first(where: { $0.id == disputeId })
            Section {
                Button {
                    if let dispute = linked {
                        pendingDisputeNav = dispute
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Esta sanción está siendo disputada")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            if let dispute = linked {
                                Text(disputeSubtitle(for: dispute))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Tocá para ver el detalle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if linked != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(linked == nil)
            }
        }
    }

    private func disputeSubtitle(for dispute: GroupDispute) -> String {
        var parts: [String] = [String(localized: dispute.status.label)]
        if let opener = dispute.openedByDisplayName {
            parts.append("Abrió: \(opener)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Info

    @ViewBuilder
    private var infoSection: some View {
        Section(L10n.SanctionDetail.infoSection) {
            LabeledContent {
                Text(sanction.targetDisplayName)
            } label: {
                Text(L10n.SanctionDetail.targetLabel)
            }
            if let issuer = sanction.issuedByDisplayName {
                LabeledContent {
                    Text(issuer)
                } label: {
                    Text(L10n.SanctionDetail.issuerLabel)
                }
            }
            LabeledContent {
                Text(sanction.reason)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(6)
            } label: {
                Text(L10n.SanctionDetail.reasonLabel)
            }
            if sanction.isMonetary, let amount = sanction.amount, let unit = sanction.unit {
                LabeledContent {
                    Text("\(amount.formatted()) \(unit)")
                        .monospacedDigit()
                } label: {
                    Text(L10n.SanctionDetail.amountLabel)
                }
            }
            if let starts = sanction.startsAt {
                LabeledContent {
                    Text(starts, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.SanctionDetail.startsAtLabel)
                }
            }
            if let ends = sanction.endsAt {
                LabeledContent {
                    Text(ends, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.SanctionDetail.endsAtLabel)
                }
            }
            if let created = sanction.createdAt {
                LabeledContent {
                    Text(created, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.SanctionDetail.createdAtLabel)
                }
            }
        }
    }

    // MARK: - Payment progress (V2-G4.1)

    @ViewBuilder
    private var progressSection: some View {
        if let status = paymentStatus, status.hasObligation, status.amountOriginal > 0 {
            Section("Pago") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Pagado")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(formatAmount(status.amountPaid)) de \(formatAmount(status.amountOriginal))")
                            .font(.subheadline.monospacedDigit())
                    }
                    ProgressView(value: status.progress)
                        .tint(status.isFullyPaid ? .green : .accentColor)
                    if status.amountOutstanding > 0 {
                        Text("Pendiente \(formatAmount(status.amountOutstanding))\(status.unit.map { " \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if status.isFullyPaid {
                        Label("Sanción saldada", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var paymentHistorySection: some View {
        if let status = paymentStatus, !status.payments.isEmpty {
            Section("Pagos") {
                ForEach(status.payments) { payment in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(payment.paidByDisplayName ?? "—")
                                .font(.subheadline)
                            if let when = payment.paidAt {
                                Text(when, format: .dateTime.day().month().year().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(formatAmount(payment.amountClosed))
                            .font(.subheadline.monospacedDigit())
                    }
                }
            }
        }
    }

    private func formatAmount(_ value: Decimal) -> String {
        let n = NSDecimalNumber(decimal: value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: n) ?? "\(value)"
    }

    private func loadPaymentStatus() async {
        async let status = container.sanctionsRepository.paymentStatus(sanctionId: sanction.id)
        async let plan = container.sanctionsRepository.paymentPlan(sanctionId: sanction.id)
        do {
            paymentStatus = try await status
        } catch {
            // Silent — chrome no-crítico.
        }
        do {
            paymentPlan = try await plan
        } catch {
            // Silent.
        }
    }

    // MARK: - Payment plan (V2-G4.2)

    @ViewBuilder
    private var paymentPlanSection: some View {
        if let plan = paymentPlan, plan.active,
           let installments = plan.installments,
           let installmentAmount = plan.installmentAmount {
            Section("Plan de pago") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Cuotas")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(plan.installmentsPaid ?? 0)/\(installments)")
                            .font(.subheadline.monospacedDigit())
                    }
                    ProgressView(value: plan.progress)
                        .tint(plan.isOverdue ? .red : .accentColor)
                    HStack {
                        Text("Cada cuota")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatAmount(installmentAmount))
                            .font(.caption.monospacedDigit())
                    }
                    if let nextDue = plan.nextDueAt {
                        HStack {
                            Image(systemName: plan.isOverdue ? "clock.badge.exclamationmark" : "clock")
                                .foregroundStyle(plan.isOverdue ? .red : .secondary)
                            Text(plan.isOverdue ? "Cuota vencida el" : "Próxima cuota")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(nextDue, format: .dateTime.day().month().year())
                                .font(.caption.monospacedDigit())
                        }
                    } else {
                        Label("Plan completado", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let notes = plan.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)

                if canManageThisPlan(plan) {
                    Button(role: .destructive) {
                        Task { await cancelPlan(plan) }
                    } label: {
                        if isCancellingPlan {
                            ProgressView()
                        } else {
                            Label("Cancelar plan", systemImage: "xmark.circle")
                        }
                    }
                    .disabled(isCancellingPlan)
                }
            }
        } else if shouldOfferProposePlan {
            Section("Plan de pago") {
                Button {
                    isShowingProposePlan = true
                } label: {
                    Label("Proponer plan en cuotas", systemImage: "calendar.badge.plus")
                }
            }
        }
    }

    private var shouldOfferProposePlan: Bool {
        guard sanction.targetMembershipId == myMembershipId,
              sanction.status.isOpen,
              let status = paymentStatus,
              status.amountOutstanding > 0
        else { return false }
        return true
    }

    private func canManageThisPlan(_ plan: SanctionPaymentPlan) -> Bool {
        // Target can always cancel its own plan. Admin path uses
        // assert_permission server-side; surface stays target-only
        // hasta exponer permission check (V3).
        sanction.targetMembershipId == myMembershipId
    }

    private func cancelPlan(_ plan: SanctionPaymentPlan) async {
        guard let planId = plan.planId else { return }
        isCancellingPlan = true
        defer { isCancellingPlan = false }
        do {
            try await container.sanctionsRepository.cancelPaymentPlan(planId: planId, reason: nil)
            await loadPaymentStatus()
        } catch {
            // Silent for V2-G4.2 — V3 surfaces error toast.
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section(L10n.SanctionDetail.actionsSection) {
            if sanction.status.isOpen {
                if canPay {
                    Button {
                        pendingPaySanction = sanction
                    } label: {
                        Label(L10n.SanctionDetail.payAction, systemImage: "creditcard")
                    }
                } else if sanction.isMonetary, sanction.targetMembershipId == myMembershipId {
                    Text(L10n.SanctionDetail.paidHint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if sanction.status != .disputed {
                    Button {
                        container.disputesStore.beginDisputingSanction(sanction.id)
                    } label: {
                        if isTarget {
                            Label(L10n.SanctionDetail.appealAction, systemImage: "checkmark.seal")
                        } else {
                            Label(L10n.SanctionDetail.disputeAction, systemImage: "scale.3d")
                        }
                    }
                }
            } else {
                Text(L10n.SanctionDetail.closedHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isTarget: Bool {
        sanction.targetMembershipId == myMembershipId
    }

    /// Pay shows only when the sanction is monetary, targets me, AND
    /// the linked `group_obligations` row is still in my open list.
    /// Mirrors the cluster filter on `MoneyDashboardView` so the two
    /// surfaces agree.
    private var canPay: Bool {
        guard sanction.isMonetary,
              sanction.targetMembershipId == myMembershipId,
              sanction.status.isOpen
        else { return false }
        guard let oid = sanction.obligationId else { return true }
        return container.moneyStore.obligations.contains { $0.id == oid }
    }
}
