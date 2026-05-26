import SwiftUI
import RuulUI
import RuulCore

/// "Dinero del grupo" — the single money detail hub for a group
/// (FASE 4 Wave 4 reframe 2026-05-25). Founder doctrine: this is THE
/// money surface where balances + multas + transacciones por contexto
/// + movimientos viven en un solo scroll layered, nunca en tabs.
/// Inspired by Apple Wallet × Apple Sports × Splitwise.
///
/// Sections (top → bottom, cada una auto-oculta vacía):
///
///   1. Hero — anchor: shared-pool balance + última actividad.
///   2. **Tu posición** (FASE 4 doctrine) — frase dyadic ("Te deben /
///      Debes / Estás al día") + CTA "Liquidar" inline cuando aplica.
///      Bloque emocional primero, NO un listado.
///   3. Liquidar pendientes — pares greedy viewer-involved + footer
///      "Ver plan completo" pushes `GroupSettlementPlanView`.
///   4. Multas — multas activas, split viewer-target vs grupo.
///   5. Por contexto — money agregado por `source_resource_id`. "Cena
///      del jueves: $400 aportado · $350 gastado".
///   6. Saldos por miembro (demoted) — preview top 3 con "Ver todos"
///      expand inline. Usa `dyadicBalanceRow` (Wave 2).
///   7. Movimientos recientes — top 5 entries con "Para X" /
///      "Compartido entre N" + badge in_kind. Footer pushes
///      `GroupTransactionsView`.
///   8. Dineros protegidos — Otros fondos (non-shared-pool).
///
/// V1 simple — el greedy es "pair largest debtor with largest creditor",
/// no Splitwise-style global optimum. Defer for later si se necesita.
@MainActor
public struct GroupMoneyDetailView: View {
    public let group: RuulCore.Group
    /// Callback that opens a fund detail. Routed by the host (typically
    /// MyGroupsTab via `router.openResource`) so this view stays
    /// presentation-only. Nil → fund rows render as labels without tap.
    public let onOpenFund: ((Fund) -> Void)?
    /// Callback to launch the fund-creation flow (resource wizard
    /// pre-selected to `.fund`). Nil → "Crear fondo" CTA hidden.
    public let onCreateFund: (() -> Void)?
    /// Push the full transactions list. Nil → footer link hidden.
    public let onOpenAllTransactions: (() -> Void)?
    /// Push the full settlement plan. Nil → footer link hidden.
    public let onOpenSettlementPlan: (() -> Void)?
    /// FASE 4 Wave 4 polish: open a resource detail by id. Drives the
    /// "Por contexto" section rows — tap a resource summary opens the
    /// resource detail (event / asset / fund / etc.). Nil → rows are
    /// non-tappable info only.
    public let onOpenResource: ((UUID) -> Void)?
    /// FASE 4 Wave 4 polish: open a single fine's detail. Drives the
    /// "Multas" section row tap target. Nil → rows non-tappable.
    public let onOpenFine: ((Fine) -> Void)?
    /// FASE 4 Wave 4 polish: push the full fines list. Nil → footer
    /// link hidden in the "Multas" section.
    public let onOpenAllFines: (() -> Void)?

    @Environment(AppState.self) private var app

    @State private var members: [MemberWithProfile] = []
    @State private var balances: [MemberGroupBalance] = []
    @State private var otherFunds: [Fund] = []
    @State private var recentEntries: [LedgerEntry] = []
    /// Money UX 2026-05-24 (hero pass): the canonical shared-pool
    /// summary, loaded so the hub can render the same large balance
    /// the SharedMoneyCard on the home shows — gives the detail
    /// surface a visual anchor instead of opening on the balances list.
    @State private var sharedPoolSummary: SharedPoolSummary?
    @State private var resourceNamesById: [UUID: String] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var settlementContext: SettlementContext?
    @State private var entryToReverse: UUID?
    @State private var entryEditingNote: NoteEditTarget?
    @State private var noteEditDraft: String = ""
    @State private var isSavingNote: Bool = false
    @State private var noteEditError: String?
    @State private var reverseError: String?

    public init(
        group: RuulCore.Group,
        onOpenFund: ((Fund) -> Void)? = nil,
        onCreateFund: (() -> Void)? = nil,
        onOpenAllTransactions: (() -> Void)? = nil,
        onOpenSettlementPlan: (() -> Void)? = nil,
        onOpenResource: ((UUID) -> Void)? = nil,
        onOpenFine: ((Fine) -> Void)? = nil,
        onOpenAllFines: (() -> Void)? = nil
    ) {
        self.group = group
        self.onOpenFund = onOpenFund
        self.onCreateFund = onCreateFund
        self.onOpenAllTransactions = onOpenAllTransactions
        self.onOpenSettlementPlan = onOpenSettlementPlan
        self.onOpenResource = onOpenResource
        self.onOpenFine = onOpenFine
        self.onOpenAllFines = onOpenAllFines
    }

    private struct NoteEditTarget: Identifiable {
        let id = UUID()
        let entryId: UUID
        let initialNote: String
    }

    /// Identifiable wrapper for the `.sheet(item:)` presentation of
    /// the settlement sheet. Carries the pre-filled (from, to, amount)
    /// from a tapped suggestion plus the row's stable key so the
    /// dashboard can animate the resolved row out after dismiss, and
    /// `viewerIsPayer` so the closure card can phrase the consequence
    /// from the right side of the dyad.
    private struct SettlementContext: Identifiable {
        let id = UUID()
        let toMemberId: UUID
        let amountCents: Int64
        let suggestionKey: String
        let viewerIsPayer: Bool
    }

    /// One greedy settlement suggestion: `from` owes `amountCents` to
    /// `to`. Built by `settlementSuggestions()` from the per-member nets.
    /// `id` is fresh per build (used for ForEach), but `key` is stable
    /// across rebuilds for cross-render identity (animation pinning).
    private struct SettlementSuggestion: Identifiable {
        let id = UUID()
        let fromMemberId: UUID
        let toMemberId: UUID
        let amountCents: Int64

        var key: String {
            "\(fromMemberId.uuidString)|\(toMemberId.uuidString)|\(amountCents)"
        }
    }

    /// FASE 4 Wave 2 (2026-05-25): the row the viewer just settled
    /// fades + scales away before `load()` repopulates, so the user
    /// sees the tension dissolve instead of a hard reload.
    @State private var dismissedSuggestionKey: String?
    /// FASE 4 Wave 2 (2026-05-25): the closure card that surfaces
    /// after a settle. Auto-dismisses on a 6s timer; the most recent
    /// `id` wins (concurrent settles don't stack banners).
    @State private var recentClosure: DyadicClosureState?
    /// FASE 4 Wave 4 (audit 2026-05-25): collapsable "Cómo funciona el
    /// dinero" info banner. Default = collapsed (no chrome). Founder
    /// can expand to read the 4-line model explanation.
    @State private var moneyInfoExpanded: Bool = false
    /// FASE 4 Wave 4 (Reembolsar): el CTA "Cobrar" en Tu posición abre
    /// `ReimburseMemberSheet` pre-filled con viewer + amount.
    @State private var reimburseCtx: ReimburseContext?

    fileprivate struct ReimburseContext: Identifiable {
        let id = UUID()
        let memberId: UUID
        let amountCents: Int64
    }
    /// FASE 4 Wave 4 (2026-05-25): viewer's active fines in this group,
    /// loaded from `myFines(userId:)` filtered by `groupId`. Drives the
    /// "Multas" section.
    @State private var activeFines: [Fine] = []
    /// FASE 4 Wave 4 Phase 3 (mig 20260525230000): server-side per-
    /// member breakdown (stake / receivable / obligation / settlement
    /// net) — replaces the client-side approximation that scanned
    /// `recentEntries` (limit 200). Powers "Tu posición" and the
    /// peer-settlement greedy.
    @State private var obligations: [MemberObligationSummary] = []
    /// Money 2.0 Phase 4.4 (mig 20260526030000 + 20260526010000): the
    /// per-pair obligations table. Used to compute settlement
    /// suggestions DIRECTLY from outstanding dyads instead of greedy
    /// pairing largest creditor ↔ largest debtor on per-member nets.
    /// Filtered client-side to active peer obligations (excludes
    /// fines — owed_to=NULL — which are surfaced separately).
    @State private var peerObligations: [Obligation] = []
    /// Phase 4.4 (mig 20260526040000): active pool charges in this
    /// group (cuotas / poker buy-ins / aportaciones esperadas). Drives
    /// the new "Cuotas pendientes" section. Filtered to active rows
    /// only — settled / voided historians live in the Movimientos feed.
    @State private var poolCharges: [Obligation] = []
    /// The pool charge whose payment sheet is currently being
    /// presented. Driven by tap on a row in the cuotas section.
    @State private var payingPoolCharge: Obligation?
    /// Confirmation target for void. The "Anular cuota" CTA only
    /// surfaces on rows where the viewer has the right to void (admin
    /// or original issuer).
    @State private var voidingPoolChargeId: UUID?
    /// FASE 4 Wave 4 (2026-05-25): expand the demoted Saldos section
    /// inline. Default collapsed → shows top 3, expand → shows all.
    @State private var balancesExpanded: Bool = false
    /// FASE 4 Wave 4 (2026-05-25): client-side movement filter for the
    /// "Movimientos recientes" section. Mail-style chip strip filters
    /// `recentEntries` to a single ledger kind. `nil` = todos.
    @State private var movementFilter: MovementFilter? = nil

    fileprivate enum MovementFilter: String, CaseIterable, Identifiable {
        case expense, contribution, settlement, fine, reimbursement
        var id: String { rawValue }
        var label: String {
            switch self {
            case .expense:       return "Gastos"
            case .contribution:  return "Aportes"
            case .settlement:    return "Liquidaciones"
            case .fine:          return "Multas"
            case .reimbursement: return "Reembolsos"
            }
        }
        /// Set of canonical ledger kind strings this chip matches.
        var kinds: Set<String> {
            switch self {
            case .expense:       return [LedgerEntry.Kind.expense]
            case .contribution:  return [LedgerEntry.Kind.contribution]
            case .settlement:    return [LedgerEntry.Kind.settlement]
            case .fine:          return [LedgerEntry.Kind.fineIssued, LedgerEntry.Kind.finePaid]
            case .reimbursement: return [LedgerEntry.Kind.reimbursement, LedgerEntry.Kind.payout]
            }
        }
    }

    private struct MoneyDashboardSnapshot: Sendable {
        let rows: [MemberGroupBalance]
    }

    private var phase: LoadPhase<MoneyDashboardSnapshot> {
        let coordError: CoordinatorError? = errorMessage.map {
            CoordinatorError(title: "No pudimos cargar el dinero del grupo", message: $0, isRetryable: true)
        }
        return LoadPhase.from(
            value: hasLoaded ? MoneyDashboardSnapshot(rows: visibleRows) : nil,
            isLoading: isLoading,
            error: coordError
        )
    }

    /// Hide settled rows (netCents == 0) — no noise on the steady state.
    /// Sort by abs(netCents) desc: largest debts / credits lead.
    private var visibleRows: [MemberGroupBalance] {
        balances
            .filter { $0.currency == group.currency && !$0.isSettled }
            .sorted { abs($0.netCents) > abs($1.netCents) }
    }

    /// FASE 4 Wave 4 Phase 3 + Tier 1 (2026-05-25): peer-relevant
    /// per-member balances. Uses `netPeerPositionCents` from
    /// `member_obligations_view` which EXCLUDES contributions/stake →
    /// the row labels stop mintiendo cuando alguien aportó capital.
    /// Excluded: members with both stake AND peer position = 0.
    private var visibleObligationRows: [MemberObligationSummary] {
        obligations
            .filter { $0.currency == group.currency }
            .filter { $0.hasAnyPosition }
            .sorted { abs($0.netPeerPositionCents) > abs($1.netPeerPositionCents) }
    }

    public var body: some View {
        AsyncContentView(
            phase: phase,
            onRetry: { await load() },
            loaded: { snapshot in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: RuulSpacing.xl) {
                        closureBanner
                        heroBlock
                        viewerPositionBlock
                        // FASE 4 Wave 4 Phase 3 (mig 20260525230000):
                        // re-activado — el greedy ahora corre sobre
                        // `netPeerPositionCents` (excluye aportes).
                        settlementSuggestionsSection
                        pendingPoolChargesSection
                        activeFinesSection
                        byContextSection
                        balancesSection(rows: snapshot.rows)
                        recentMovementsSection
                        otherFundsSection
                        moneyInfoBanner
                    }
                    .padding(.horizontal, RuulSpacing.lg)
                    .padding(.top, RuulSpacing.md)
                    .padding(.bottom, RuulSpacing.xl)
                }
                .refreshable { await load() }
            }
        )
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Dinero del grupo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $reimburseCtx) { ctx in
            ReimburseMemberSheet(
                groupId: group.id,
                currency: group.currency,
                members: members,
                suggestedMemberId: ctx.memberId,
                suggestedAmountCents: ctx.amountCents,
                onDidReimburse: {
                    Task { await load() }
                }
            )
            .environment(app)
        }
        .sheet(item: $payingPoolCharge) { charge in
            PayPoolChargeSheet(
                charge: charge,
                members: members,
                onDidPay: { Task { await load() } }
            )
            .environment(app)
        }
        .confirmationDialog(
            "¿Anular esta cuota?",
            isPresented: Binding(
                get: { voidingPoolChargeId != nil },
                set: { if !$0 { voidingPoolChargeId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Anular", role: .destructive) {
                if let id = voidingPoolChargeId {
                    Task { await performVoidPoolCharge(id) }
                }
            }
            Button("Cancelar", role: .cancel) { voidingPoolChargeId = nil }
        } message: {
            Text("La cuota deja de contar como deuda al pool. No genera ningún ajuste en el dinero.")
        }
        .sheet(item: $settlementContext) { ctx in
            SettlementSheet(
                groupId: group.id,
                resourceId: nil,
                currency: group.currency,
                members: members,
                suggestedToMemberId: ctx.viewerIsPayer ? ctx.toMemberId : myMemberId,
                suggestedFromMemberId: ctx.viewerIsPayer ? myMemberId : ctx.toMemberId,
                suggestedAmountCents: ctx.amountCents,
                onDidSettle: {
                    let key = ctx.suggestionKey
                    let counterpartId = ctx.toMemberId
                    let amount = Decimal(ctx.amountCents) / 100
                    let viewerSide: DyadicClosureCard.ViewerSide =
                        ctx.viewerIsPayer ? .payer : .creditor
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.35)) {
                            dismissedSuggestionKey = key
                        }
                        try? await Task.sleep(for: .milliseconds(380))
                        await load()
                        dismissedSuggestionKey = nil
                        await presentClosure(
                            counterpartId: counterpartId,
                            amount: amount,
                            viewerSide: viewerSide
                        )
                    }
                }
            )
            .environment(app)
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
        }
        .confirmationDialog(
            "¿Revertir esta operación?",
            isPresented: Binding(
                get: { entryToReverse != nil },
                set: { if !$0 { entryToReverse = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revertir", role: .destructive) {
                if let id = entryToReverse {
                    Task { await performReverse(entryId: id) }
                }
            }
            Button("Cancelar", role: .cancel) { entryToReverse = nil }
        } message: {
            Text("Se creará un movimiento de signo opuesto para cancelar el original. Los miembros verán el ajuste en la lista.")
        }
        .sheet(item: $entryEditingNote, onDismiss: {
            noteEditDraft = ""
            noteEditError = nil
        }) { target in
            noteEditSheet(target: target)
        }
        .alert("No pudimos revertir", isPresented: Binding(
            get: { reverseError != nil },
            set: { if !$0 { reverseError = nil } }
        )) {
            Button("OK", role: .cancel) { reverseError = nil }
        } message: {
            Text(reverseError ?? "")
        }
    }

    /// Sheet form for `update_ledger_entry_note` (mig 00372). Same shape
    /// the Activity feed uses — kept inline here so the hub stays a
    /// single-file surface and the user doesn't need to leave the
    /// money screen to fix a typo on a transaction note.
    @ViewBuilder
    private func noteEditSheet(target: NoteEditTarget) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Descripción", text: $noteEditDraft, axis: .vertical)
                        .lineLimit(2...6)
                }
                if let err = noteEditError {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
            .ruulSheetToolbar("Editar nota") {
                entryEditingNote = nil
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSavingNote ? "Guardando…" : "Guardar") {
                        Task { await performNoteEdit(target: target) }
                    }
                    .disabled(
                        isSavingNote
                        || noteEditDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            == target.initialNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }
        }
        .task {
            // Seed the draft on first present; .task fires once per
            // sheet instance so re-opens don't clobber an in-progress
            // edit on a different row.
            if noteEditDraft.isEmpty {
                noteEditDraft = target.initialNote
            }
        }
    }

    @MainActor
    private func performReverse(entryId: UUID) async {
        entryToReverse = nil
        do {
            _ = try await app.ledgerRepo.reverseEntry(
                entryId: entryId,
                reason: nil,
                clientId: UUID()
            )
            await load()
        } catch {
            reverseError = error.localizedDescription
        }
    }

    @MainActor
    private func performNoteEdit(target: NoteEditTarget) async {
        isSavingNote = true
        noteEditError = nil
        defer { isSavingNote = false }
        let trimmed = noteEditDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await app.ledgerRepo.updateEntryNote(
                entryId: target.entryId,
                note: trimmed.isEmpty ? nil : trimmed
            )
            entryEditingNote = nil
            await load()
        } catch {
            noteEditError = error.localizedDescription
        }
    }

    /// Authorization mirrors `reverse_ledger_entry` RPC (mig 00368):
    /// only the original `recorded_by` can reverse. Returns the row's
    /// id only when the viewer matches AND the entry isn't itself a
    /// reverse (`metadata.reversed_ledger_entry_id` absent).
    private func reversibleId(_ entry: LedgerEntry) -> UUID? {
        guard entry.recordedBy == app.session?.user.id else { return nil }
        if entry.metadata["reversed_ledger_entry_id"]?.stringValue != nil {
            return nil
        }
        return entry.id
    }

    // MARK: - Dashboard sections

    // MARK: - Closure banner (FASE 4 Wave 2)

    @ViewBuilder
    private var closureBanner: some View {
        if let c = recentClosure {
            DyadicClosureCard(
                counterpartName: c.counterpartName,
                amount: c.amount,
                currency: c.currency,
                viewerSide: c.viewerSide,
                outcome: c.outcome,
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.25)) {
                        recentClosure = nil
                    }
                }
            )
            .id(c.id)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity.combined(with: .scale(scale: 0.95))
            ))
        }
    }

    /// Compute the closure outcome by checking whether the greedy
    /// algorithm still produces a suggestion between (viewer, counterpart)
    /// after reload. Sets `recentClosure` with a 6-second auto-dismiss.
    @MainActor
    private func presentClosure(
        counterpartId: UUID,
        amount: Decimal,
        viewerSide: DyadicClosureCard.ViewerSide
    ) async {
        let stillSuggested = settlementSuggestions(balances: visibleRows).contains { s in
            guard let me = myMemberId else { return false }
            return (s.fromMemberId == me && s.toMemberId == counterpartId) ||
                   (s.fromMemberId == counterpartId && s.toMemberId == me)
        }
        let outcome: DyadicClosureCard.Outcome = stillSuggested ? .partial : .closed
        let state = DyadicClosureState(
            counterpartName: memberName(for: counterpartId) ?? "este miembro",
            amount: amount,
            currency: group.currency,
            viewerSide: viewerSide,
            outcome: outcome
        )
        withAnimation(.snappy) {
            recentClosure = state
        }
        try? await Task.sleep(for: .seconds(6))
        if recentClosure?.id == state.id {
            withAnimation(.easeOut(duration: 0.4)) {
                recentClosure = nil
            }
        }
    }

    // MARK: - Hero block

    /// First viewport contract:
    /// - cash in the shared pool
    /// - cash flow that produced it
    /// - the viewer's next actionable money step
    @ViewBuilder
    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            if let s = sharedPoolSummary {
                poolHero(s)
                Divider()
                cashFlowSummary(s)
            } else {
                emptyPoolHero
            }

            if let step = nextMoneyStep {
                Divider()
                nextStepRow(step)
            }
        }
        .padding(RuulSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ruulCardSurface(.solid)
    }

    private func poolHero(_ s: SharedPoolSummary) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("EFECTIVO DEL GRUPO")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .tracking(0.6)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatHero(s.balanceCents))
                    .font(.system(size: 40, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(s.isOverSpent ? Color.ruulNegative : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(s.currency)
                    .font(.body)
                    .foregroundStyle(Color.secondary)
            }
            Text(heroFooter(s))
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyPoolHero: some View {
        HStack(alignment: .top, spacing: RuulSpacing.md) {
            ColoredIconBadge(systemName: "banknote", tint: Color.ruulAccent)
            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                Text("Sin movimientos de dinero")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text("Aún no hay aportes, gastos ni liquidaciones.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func cashFlowSummary(_ s: SharedPoolSummary) -> some View {
        VStack(spacing: 0) {
            moneyMetricRow(
                icon: "arrow.down.to.line.compact",
                tint: Color.ruulPositive,
                title: "Aportes",
                value: formatCurrency(s.inCents, currency: s.currency),
                detail: "Dinero que entró al pool"
            )
            rowDivider
            moneyMetricRow(
                icon: "arrow.up.forward.circle",
                tint: Color.ruulNegative,
                title: "Gastos",
                value: formatCurrency(s.outCents, currency: s.currency),
                detail: "Dinero registrado como salida"
            )
            if s.inKindCents > 0 {
                rowDivider
                moneyMetricRow(
                    icon: "shippingbox",
                    tint: Color.ruulAccent,
                    title: "Activos",
                    value: formatCurrency(s.inKindCents, currency: s.currency),
                    detail: "Valor total \(formatCurrency(s.totalValueCents, currency: s.currency))"
                )
            }
        }
    }

    private func moneyMetricRow(
        icon: String,
        tint: Color,
        title: String,
        value: String,
        detail: String
    ) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: RuulSpacing.xxl, alignment: .center)
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, RuulSpacing.xs)
    }

    private enum NextMoneyAction {
        case reimbursePool(Int64)
        case payFine
        case settle(SettlementSuggestion, viewerIsPayer: Bool)
    }

    private struct MoneyNextStep {
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
        let amountCents: Int64?
        let action: NextMoneyAction?
    }

    private var nextMoneyStep: MoneyNextStep? {
        guard myMemberId != nil else { return nil }
        let b = myPositionBreakdown
        let peerDebits = viewerPeerPairs.filter { $0.fromMemberId == myMemberId }
        let peerCredits = viewerPeerPairs.filter { $0.toMemberId == myMemberId }

        if let s = peerDebits.first {
            let name = memberName(for: s.toMemberId) ?? "este miembro"
            return MoneyNextStep(
                icon: "arrow.up.right.circle.fill",
                tint: Color.ruulNegative,
                title: "Págale a \(name)",
                subtitle: "Tu siguiente liquidación directa",
                amountCents: s.amountCents,
                action: .settle(s, viewerIsPayer: true)
            )
        }
        if b.multasPendientesCents > 0 {
            let fineSubtitle = activeFines.isEmpty
                ? "Deuda pendiente al grupo"
                : (activeFines.count == 1 ? "1 multa activa" : "\(activeFines.count) multas activas")
            return MoneyNextStep(
                icon: "exclamationmark.triangle.fill",
                tint: Color.ruulNegative,
                title: "Paga tus multas pendientes",
                subtitle: fineSubtitle,
                amountCents: b.multasPendientesCents,
                action: .payFine
            )
        }
        if b.teDebenCents > 0 {
            return MoneyNextStep(
                icon: "arrow.down.left.circle.fill",
                tint: Color.ruulPositive,
                title: "Cobra del pool",
                subtitle: "El grupo te debe por gastos que pagaste",
                amountCents: b.teDebenCents,
                action: .reimbursePool(b.teDebenCents)
            )
        }
        if let s = peerCredits.first {
            let name = memberName(for: s.fromMemberId) ?? "este miembro"
            return MoneyNextStep(
                icon: "arrow.down.left.circle.fill",
                tint: Color.ruulPositive,
                title: "Cobra a \(name)",
                subtitle: "Liquidación directa pendiente",
                amountCents: s.amountCents,
                action: .settle(s, viewerIsPayer: false)
            )
        }

        let stake = b.aportadoCents + b.aportadoInKindCents
        return MoneyNextStep(
            icon: "checkmark.circle.fill",
            tint: Color.ruulPositive,
            title: "Estás al día",
            subtitle: stake > 0
                ? "Aportaste \(formatCurrency(stake, currency: group.currency))"
                : "Sin pendientes personales",
            amountCents: nil,
            action: nil
        )
    }

    @ViewBuilder
    private func nextStepRow(_ step: MoneyNextStep) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(step.action == nil ? "TU ESTADO" : "TU SIGUIENTE PASO")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .tracking(0.6)
            if let action = step.action {
                Button {
                    handle(nextAction: action)
                } label: {
                    nextStepContent(step, showsChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                nextStepContent(step, showsChevron: false)
            }
        }
    }

    private func nextStepContent(_ step: MoneyNextStep, showsChevron: Bool) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: step.icon)
                .font(.title3)
                .foregroundStyle(step.tint)
                .frame(width: RuulSpacing.xxl, alignment: .center)
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(step.subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let amount = step.amountCents {
                Text(formatCurrency(amount, currency: group.currency))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(step.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.vertical, RuulSpacing.xxs)
        .contentShape(Rectangle())
    }

    private func handle(nextAction: NextMoneyAction) {
        switch nextAction {
        case .reimbursePool(let amount):
            guard let myId = myMemberId else { return }
            reimburseCtx = ReimburseContext(memberId: myId, amountCents: amount)
        case .payFine:
            handle(action: .pagar)
        case .settle(let suggestion, viewerIsPayer: let viewerIsPayer):
            let counterpartId = viewerIsPayer
                ? suggestion.toMemberId
                : suggestion.fromMemberId
            settlementContext = SettlementContext(
                toMemberId: counterpartId,
                amountCents: suggestion.amountCents,
                suggestionKey: suggestion.key,
                viewerIsPayer: viewerIsPayer
            )
        }
    }

    private func formatHero(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = group.currency
        f.currencySymbol = "$"
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "es_MX")
        return f.string(from: amount as NSDecimalNumber) ?? "$\(cents / 100)"
    }

    private func heroFooter(_ s: SharedPoolSummary) -> String {
        if s.isOverSpent {
            return "Saldo negativo — más gastos que aportes"
        }
        guard s.hasActivity, let last = s.lastActivityAt else {
            return "Sin movimientos todavía"
        }
        return "Última actividad \(last.ruulRelative)"
    }

    // MARK: - Tu posición (FASE 4 Wave 4 — flat list, sentence-led)

    /// "Tu posición en este grupo" — flat list ordenada para lectura
    /// natural. Cada row es una sentencia completa que nombra su world
    /// (per `doctrine_money_two_worlds`), entonces NO necesita cards
    /// anidados ni headers de mundo. El subject de la frase ya lo dice:
    ///
    ///   📦 Aportaste $X (factual, factual top)
    ///   ↘  El grupo te debe $X (pool receivable)
    ///   ↘  Linda te debe $X (peer)
    ///   ↗  Le debes $X a Carlos (peer)
    ///   ⚠  Debes $X al grupo (multas)
    ///
    /// Banned (per doctrine): "Te deben $X" sin sujeto, "Le debes $X"
    /// sin objeto. Cada row tiene world implícito en su sentencia.
    @ViewBuilder
    private var viewerPositionBlock: some View {
        if myMemberId != nil {
            let b = myPositionBreakdown
            let peers = viewerPeerPairs
            let isAllZero = b.isAllZero && peers.isEmpty
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                sectionHeader("Tu posición en este grupo")
                if isAllZero {
                    HStack(spacing: RuulSpacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.ruulPositive)
                        Text("Estás al día")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(RuulSpacing.md)
                    .ruulCardSurface(.solid)
                } else {
                    positionFlatList(b: b, peers: peers)
                }
            }
        }
    }

    /// Flat list de rows. Orden: stake → receivables → debes → multas.
    /// Cada row se renderea solo si tiene contenido. Dividers entre
    /// rows visibles. Single `.ruulCardSurface` envolvente.
    @ViewBuilder
    private func positionFlatList(
        b: PositionBreakdown,
        peers: [SettlementSuggestion]
    ) -> some View {
        let stakeShown = b.aportadoCents > 0 || b.aportadoInKindCents > 0
        let receivablePoolShown = b.teDebenCents > 0
        let peerCredits = peers.filter { $0.toMemberId == myMemberId }
        let peerDebits = peers.filter { $0.fromMemberId == myMemberId }
        let multaShown = b.multasPendientesCents > 0
        VStack(spacing: 0) {
            var rowIndex = 0
            if stakeShown {
                let stakeDisplayCents = b.aportadoCents > 0
                    ? b.aportadoCents
                    : b.aportadoInKindCents
                positionRow(
                    icon: "shippingbox",
                    tint: Color.ruulAccent,
                    title: "Aportaste",
                    amount: stakeDisplayCents,
                    subtitle: stakeSubtitle(b),
                    action: nil
                )
                let _ = (rowIndex += 1)
            }
            if receivablePoolShown {
                if rowIndex > 0 { rowDivider }
                positionRow(
                    icon: "arrow.down.left.circle.fill",
                    tint: Color.ruulPositive,
                    title: "El grupo te debe",
                    amount: b.teDebenCents,
                    subtitle: "Por gastos del grupo que pagaste",
                    action: .cobrar
                )
                let _ = (rowIndex += 1)
            }
            ForEach(Array(peerCredits.enumerated()), id: \.element.id) { _, s in
                if rowIndex > 0 { rowDivider }
                peerPairRow(s)
                let _ = (rowIndex += 1)
            }
            ForEach(Array(peerDebits.enumerated()), id: \.element.id) { _, s in
                if rowIndex > 0 { rowDivider }
                peerPairRow(s)
                let _ = (rowIndex += 1)
            }
            if multaShown {
                if rowIndex > 0 { rowDivider }
                positionRow(
                    icon: "exclamationmark.triangle.fill",
                    tint: Color.ruulNegative,
                    title: "Debes al grupo",
                    amount: b.multasPendientesCents,
                    subtitle: "Multas pendientes",
                    action: .pagar
                )
                let _ = (rowIndex += 1)
            }
        }
        .ruulCardSurface(.solid)
    }

    /// Greedy settlement pairs (after Phase 3 obligations view, these
    /// reflect REAL peer debt — exclude stake). Filtered to viewer-
    /// involved only per `doctrine_money_two_worlds` (peer surfaces
    /// show only your relationships, never third-party).
    private var viewerPeerPairs: [SettlementSuggestion] {
        guard let myId = myMemberId else { return [] }
        return settlementSuggestions(balances: visibleRows)
            .filter { $0.fromMemberId == myId || $0.toMemberId == myId }
    }

    @ViewBuilder
    private func peerPairRow(_ s: SettlementSuggestion) -> some View {
        let viewerIsPayer = (s.fromMemberId == myMemberId)
        let counterpartId = viewerIsPayer ? s.toMemberId : s.fromMemberId
        let counterpartName = memberName(for: counterpartId) ?? "Miembro"
        let title = viewerIsPayer
            ? "Le debes a \(counterpartName)"
            : "\(counterpartName) te debe"
        let tint: Color = viewerIsPayer ? .ruulNegative : .ruulPositive
        let icon = viewerIsPayer
            ? "arrow.up.right.circle.fill"
            : "arrow.down.left.circle.fill"
        let subtitle = viewerIsPayer
            ? "Págale directo"
            : "Cóbrale directo"
        Button {
            settlementContext = SettlementContext(
                toMemberId: counterpartId,
                amountCents: s.amountCents,
                suggestionKey: s.key,
                viewerIsPayer: viewerIsPayer
            )
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: RuulSpacing.xxl, alignment: .center)
                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                Text(formatCurrency(s.amountCents, currency: group.currency))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stakeSubtitle(_ b: PositionBreakdown) -> String? {
        let inKind = b.aportadoInKindCents
        let cash = b.aportadoCents
        if inKind > 0 && cash > 0 {
            return "+ \(formatCurrency(inKind, currency: group.currency)) en activos"
        }
        if inKind > 0 && cash == 0 {
            return "Solo en activos · \(formatCurrency(inKind, currency: group.currency)) en especie"
        }
        return "Tu inversión en el pool"
    }

    private enum PositionAction { case cobrar, pagar }

    @ViewBuilder
    private func positionRow(
        icon: String,
        tint: Color,
        title: String,
        amount: Int64,
        subtitle: String?,
        action: PositionAction?
    ) -> some View {
        let actionable = action != nil
        Button {
            if let action { handle(action: action) }
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: RuulSpacing.xxl, alignment: .center)
                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let action {
                        // Inline action hint replaces the cramped
                        // floating button under the amount. Apple-
                        // native disclosure-of-action pattern.
                        Text(actionLabel(action))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.ruulAccent)
                            .padding(.top, RuulSpacing.xxs)
                    }
                }
                Spacer(minLength: 0)
                Text(formatCurrency(amount, currency: group.currency))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if actionable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!actionable)
    }

    private func actionLabel(_ a: PositionAction) -> String {
        switch a {
        case .cobrar: return "Cobrar del pool →"
        case .pagar:  return "Pagar multa →"
        }
    }

    private func handle(action: PositionAction) {
        switch action {
        case .cobrar:
            // "Cobrar" = el viewer cobra del pool lo que le deben. Abre
            // ReimburseMemberSheet pre-filled con el viewer y el monto
            // total del receivable. Esto escribe un `reimbursement`
            // entry que cancela su saldo a favor sin tocar el pool view.
            guard let myId = myMemberId else { return }
            let b = myPositionBreakdown
            reimburseCtx = ReimburseContext(
                memberId: myId,
                amountCents: b.teDebenCents
            )
        case .pagar:
            // Abre el detalle de la multa más antigua pendiente.
            if let fine = activeFines.first {
                onOpenFine?(fine)
            } else if let onOpenAllFines {
                onOpenAllFines()
            }
        }
    }

    /// FASE 4 Wave 4 (audit 2026-05-25): el modelo de dinero tiene 3
    /// dimensiones que el `netCents` mezcla en una sola cifra confusa.
    /// Este breakdown las separa para "Tu posición".
    fileprivate struct PositionBreakdown {
        let aportadoCents: Int64           // Σ contribution (cash) from=me
        let aportadoInKindCents: Int64     // Σ contribution (in_kind) from=me
        let teDebenCents: Int64            // Σ expense to=me − Σ payout/reimbursement to=me
        let multasPendientesCents: Int64   // Σ active fines against me

        static let zero = PositionBreakdown(
            aportadoCents: 0,
            aportadoInKindCents: 0,
            teDebenCents: 0,
            multasPendientesCents: 0
        )

        var isAllZero: Bool {
            aportadoCents == 0
                && aportadoInKindCents == 0
                && teDebenCents == 0
                && multasPendientesCents == 0
        }

        /// "Liquidar" CTA aplica solo para deuda accionable. Stake
        /// aportado NO es deuda — no se liquida, es tu inversión.
        var hasActionableDebt: Bool {
            teDebenCents > 0 || multasPendientesCents > 0
        }
    }

    private var myPositionBreakdown: PositionBreakdown {
        guard let myId = myMemberId else { return .zero }
        // FASE 4 Wave 4 Phase 3: prefer server-side breakdown
        // (`member_obligations_view`, mig 20260525230000). When the view
        // hasn't loaded yet — or the API failed — fall back to scanning
        // `recentEntries` (limit 200 — approximate but lets the surface
        // render something during the network round-trip).
        if let row = obligations.first(where: {
            $0.memberId == myId && $0.currency == group.currency
        }) {
            return PositionBreakdown(
                aportadoCents: row.stakeCents,
                aportadoInKindCents: row.stakeInKindCents,
                teDebenCents: row.receivableCents,
                multasPendientesCents: row.obligationCents
            )
        }
        // Fallback (approximate, pre-load) — kept for offline / first-
        // paint quality. Should match the server math closely.
        var aportadoCash: Int64 = 0
        var aportadoInKind: Int64 = 0
        var teDeben: Int64 = 0
        for e in recentEntries {
            switch e.type {
            case LedgerEntry.Kind.contribution:
                if e.fromMemberId == myId {
                    if e.isInKind { aportadoInKind += e.amountCents }
                    else { aportadoCash += e.amountCents }
                }
            case LedgerEntry.Kind.expense:
                if e.toMemberId == myId { teDeben += e.amountCents }
            case LedgerEntry.Kind.payout:
                if e.toMemberId == myId { teDeben -= e.amountCents }
            case LedgerEntry.Kind.reimbursement:
                if e.fromMemberId == myId || e.toMemberId == myId {
                    teDeben -= e.amountCents
                }
            default:
                break
            }
        }
        let multas = activeFines.reduce(Int64(0)) { acc, fine in
            acc + NSDecimalNumber(decimal: fine.amount * 100).int64Value
        }
        return PositionBreakdown(
            aportadoCents: aportadoCash,
            aportadoInKindCents: aportadoInKind,
            teDebenCents: max(0, teDeben),
            multasPendientesCents: multas
        )
    }

    /// FASE 4 Wave 4 polish: the "Tu posición" CTA opens the
    /// `SettlementSheet` pre-filled with the viewer's top greedy
    /// settlement pair (largest counterpart). Falls back to pushing
    /// the full plan view when no pair is computable yet (e.g., the
    /// balances haven't loaded the counterpart's row).
    private func openLiquidarFromPosition() {
        guard let top = settlementSuggestions(balances: visibleRows)
            .first(where: { $0.fromMemberId == myMemberId || $0.toMemberId == myMemberId })
        else {
            onOpenSettlementPlan?()
            return
        }
        let viewerIsPayer = (top.fromMemberId == myMemberId)
        let counterpartId = viewerIsPayer ? top.toMemberId : top.fromMemberId
        settlementContext = SettlementContext(
            toMemberId: counterpartId,
            amountCents: top.amountCents,
            suggestionKey: top.key,
            viewerIsPayer: viewerIsPayer
        )
    }

    // MARK: - Multas (FASE 4 Wave 4 PR B)

    /// Active fines surface — viewer's pending fines in this group.
    /// Status filter (officialized + proposed + inAppeal) is applied
    /// in `load()`. Hidden when empty.
    @ViewBuilder
    private var activeFinesSection: some View {
        if !activeFines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(
                    "Multas",
                    trailing: activeFines.count == 1
                        ? "1 pendiente"
                        : "\(activeFines.count) pendientes"
                )
                VStack(spacing: 0) {
                    ForEach(Array(activeFines.prefix(5).enumerated()), id: \.element.id) { idx, fine in
                        if idx > 0 { rowDivider }
                        fineRow(fine)
                    }
                }
                .ruulCardSurface(.solid)
                if let onOpenAllFines {
                    sectionLink("Ver todas las multas", action: onOpenAllFines)
                        .padding(.top, RuulSpacing.xs)
                }
            }
        }
    }

    @ViewBuilder
    private func fineRow(_ fine: Fine) -> some View {
        let formatted = fine.amount.formatted(.currency(code: group.currency))
        Button {
            onOpenFine?(fine)
        } label: {
            HStack(spacing: RuulSpacing.md) {
                ColoredIconBadge(
                    systemName: fine.status == .inAppeal
                        ? "exclamationmark.bubble"
                        : "exclamationmark.triangle.fill",
                    tint: fine.status == .inAppeal ? Color.ruulAccent : Color.ruulNegative
                )
                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    Text(fineLabel(fine))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(fine.status.displayLabel)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                Text(formatted)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.ruulNegative)
                if onOpenFine != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpenFine == nil)
    }

    /// One-line label for the fine. Falls back to "Multa" when there's
    /// no human-set `reason`.
    private func fineLabel(_ fine: Fine) -> String {
        let r = fine.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? "Multa" : r
    }

    // MARK: - Por contexto (FASE 4 Wave 4 PR C)

    /// Aggregate `recentEntries` by `sourceResourceId` and surface the
    /// top resources by absolute money attached. "Cena del jueves:
    /// $400 aportado · $350 gastado".
    @ViewBuilder
    private var byContextSection: some View {
        let summaries = contextSummaries
        if !summaries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Por contexto")
                VStack(spacing: 0) {
                    ForEach(Array(summaries.prefix(5).enumerated()), id: \.element.id) { idx, s in
                        if idx > 0 { rowDivider }
                        contextRow(s)
                    }
                }
                .ruulCardSurface(.solid)
            }
        }
    }

    /// Per-source-resource money rollup. Built client-side from the
    /// last 200 entries so the surface stays self-sufficient and
    /// reflects the actual ledger without drifting from a server view.
    private struct ContextSummary: Identifiable {
        let resourceId: UUID
        let name: String
        let contributedCents: Int64
        let spentCents: Int64
        var id: UUID { resourceId }
        var totalCents: Int64 { contributedCents + spentCents }
    }

    private var contextSummaries: [ContextSummary] {
        var dict: [UUID: (contributed: Int64, spent: Int64)] = [:]
        for e in recentEntries {
            guard let rid = e.sourceResourceId else { continue }
            switch e.type {
            case LedgerEntry.Kind.contribution:
                dict[rid, default: (0, 0)].contributed += e.amountCents
            case LedgerEntry.Kind.expense:
                dict[rid, default: (0, 0)].spent += e.amountCents
            default:
                break
            }
        }
        return dict
            .map { id, v in
                ContextSummary(
                    resourceId: id,
                    name: resourceNamesById[id] ?? "Recurso",
                    contributedCents: v.contributed,
                    spentCents: v.spent
                )
            }
            .filter { $0.totalCents > 0 }
            .sorted { $0.totalCents > $1.totalCents }
    }

    @ViewBuilder
    private func contextRow(_ s: ContextSummary) -> some View {
        Button {
            onOpenResource?(s.resourceId)
        } label: {
            HStack(spacing: RuulSpacing.md) {
                ColoredIconBadge(systemName: "tag", tint: Color.ruulAccent)
                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    Text(s.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(contextSubtitle(s))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if onOpenResource != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpenResource == nil)
    }

    private func contextSubtitle(_ s: ContextSummary) -> String {
        var parts: [String] = []
        if s.contributedCents > 0 {
            parts.append("\(formatCurrency(s.contributedCents, currency: group.currency)) aportado")
        }
        if s.spentCents > 0 {
            parts.append("\(formatCurrency(s.spentCents, currency: group.currency)) gastado")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Balances (member nets, demoted) — Apple minimal 1-line rows

    /// FASE 4 Wave 4 demotion: the per-member balances list moves below
    /// the actionable "Tu posición" + "Liquidar" + "Multas" sections.
    /// Collapsed by default — shows top 3 rows + "Ver todos los saldos"
    /// expand-inline button. Keeps the data accessible without making
    /// the hub feel like a ledger spreadsheet.
    @ViewBuilder
    private func balancesSection(rows: [MemberGroupBalance]) -> some View {
        // FASE 4 Wave 4 Phase 3 + Tier 1: prefer obligations view (Phase
        // 5 foundation) — it cleanly separates stake from peer debt so
        // the row labels don't mislead. Fall back to the legacy
        // `[MemberGroupBalance]` only when obligations haven't loaded
        // (first paint).
        let useObligations = !obligations.isEmpty
        let obligationRows = visibleObligationRows
        let totalCount = useObligations ? obligationRows.count : rows.count
        let displayed: [BalanceRowView] = useObligations
            ? (balancesExpanded
                ? obligationRows.map { .obligation($0) }
                : Array(obligationRows.prefix(3)).map { .obligation($0) })
            : (balancesExpanded
                ? rows.map { .balance($0) }
                : Array(rows.prefix(3)).map { .balance($0) })
        let hiddenCount = max(0, totalCount - displayed.count)
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Saldos por miembro")
            VStack(spacing: 0) {
                ForEach(Array(displayed.enumerated()), id: \.offset) { idx, row in
                    if idx > 0 { rowDivider }
                    dyadicBalanceRow(row)
                }
                if hiddenCount > 0 || balancesExpanded {
                    rowDivider
                    Button {
                        withAnimation(.snappy) { balancesExpanded.toggle() }
                    } label: {
                        HStack(spacing: RuulSpacing.xs) {
                            Text(balancesExpanded
                                 ? "Ver menos"
                                 : "Ver todos los saldos (\(totalCount))")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.ruulAccent)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.ruulAccent)
                                .rotationEffect(.degrees(balancesExpanded ? 180 : 0))
                        }
                        .padding(.horizontal, RuulSpacing.md)
                        .padding(.vertical, RuulSpacing.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .ruulCardSurface(.solid)
        }
    }

    /// Discriminated union so the rendered list can mix obligation rows
    /// (preferred, post-Phase 3) and legacy `MemberGroupBalance` rows
    /// (fallback during first paint).
    fileprivate enum BalanceRowView {
        case obligation(MemberObligationSummary)
        case balance(MemberGroupBalance)
    }

    /// FASE 4 Wave 4 Phase 3 (Tier 1): verb-first row driven by
    /// `netPeerPositionCents` — excludes stake/aportes so the label
    /// stops mintiendo when someone contributed capital. Stake (when
    /// non-zero peer = 0) surfaces as a secondary line "Aportó $X".
    @ViewBuilder
    private func dyadicBalanceRow(_ row: BalanceRowView) -> some View {
        switch row {
        case .obligation(let o):
            obligationBalanceRow(o)
        case .balance(let b):
            legacyBalanceRow(b)
        }
    }

    private func obligationBalanceRow(_ o: MemberObligationSummary) -> some View {
        let isMe = (o.memberId == myMemberId)
        let name = memberName(for: o.memberId) ?? "Este miembro"
        let net = o.netPeerPositionCents
        let stakeTotal = o.stakeTotalCents
        let formatted: (Int64) -> String = { cents in
            (Decimal(abs(cents)) / 100).formatted(.currency(code: o.currency))
        }
        let amountText: (Int64, Color) -> Text = { cents, color in
            Text(formatted(cents))
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
        let phrase: Text
        let secondary: String?
        switch (isMe, net) {
        case (true, let n) where n > 0:
            phrase = Text("Te deben \(amountText(n, .ruulPositive))")
            secondary = stakeTotal > 0 ? "Aportaste \(formatted(stakeTotal))" : nil
        case (true, let n) where n < 0:
            phrase = Text("Debes \(amountText(n, .ruulNegative))")
            secondary = stakeTotal > 0 ? "Aportaste \(formatted(stakeTotal))" : nil
        case (true, _):
            // Net 0 but you have stake or activity → factual line.
            if stakeTotal > 0 {
                phrase = Text("Aportaste \(amountText(stakeTotal, .ruulAccent))")
                secondary = "Estás al día"
            } else {
                phrase = Text("Estás al día")
                secondary = nil
            }
        case (false, let n) where n > 0:
            phrase = Text("Le deben \(amountText(n, .ruulPositive)) a \(name)")
            secondary = stakeTotal > 0 ? "\(name) aportó \(formatted(stakeTotal))" : nil
        case (false, let n) where n < 0:
            phrase = Text("\(name) debe \(amountText(n, .ruulNegative))")
            secondary = stakeTotal > 0 ? "Aportó \(formatted(stakeTotal))" : nil
        default:
            // Net 0 but stake > 0 → factual aporte line.
            if stakeTotal > 0 {
                phrase = Text("\(name) aportó \(amountText(stakeTotal, .ruulAccent))")
                secondary = nil
            } else {
                phrase = Text("\(name) está al día")
                secondary = nil
            }
        }
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                phrase
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    /// Legacy fallback when obligations view hasn't loaded yet. Same
    /// 4-phrase layout as before. Used only during first paint.
    private func legacyBalanceRow(_ row: MemberGroupBalance) -> some View {
        let isMe = (row.memberId == myMemberId)
        let amount = Decimal(abs(row.netCents)) / 100
        let formatted = amount.formatted(.currency(code: row.currency))
        let amountColor: Color = row.isOwed ? .ruulPositive : .ruulNegative
        let name = memberName(for: row.memberId) ?? "Este miembro"

        let amountText = Text(formatted)
            .font(.body.monospacedDigit().weight(.semibold))
            .foregroundStyle(amountColor)

        let phrase: Text
        switch (isMe, row.isOwed) {
        case (true, true):  phrase = Text("Te deben \(amountText)")
        case (true, false): phrase = Text("Debes \(amountText)")
        case (false, true): phrase = Text("Le deben \(amountText) a \(name)")
        case (false, false): phrase = Text("\(name) debe \(amountText)")
        }

        return HStack(spacing: 0) {
            phrase
                .font(.body)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, RuulSpacing.md)
    }

    /// Section header — uppercase tracked footnote, Apple Settings /
    /// Wallet style. Replaces the prior `.footnote.semibold.tertiary`
    /// inline labels each section was duplicating.
    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.bottom, RuulSpacing.xs)
    }

    /// Group-level settlement preview. Viewer-involved settlements live
    /// in "Tu posición"; this section only appears when the remaining
    /// plan has rows between other members, so the same action is not
    /// shown twice in the first scroll.
    @ViewBuilder
    private var settlementSuggestionsSection: some View {
        let all = settlementSuggestions(balances: visibleRows)
        let viewerInvolved = all.filter {
            $0.fromMemberId == myMemberId || $0.toMemberId == myMemberId
        }
        let otherMembers = all.filter {
            $0.fromMemberId != myMemberId && $0.toMemberId != myMemberId
        }
        let displayed = viewerInvolved.isEmpty
            ? Array(all.prefix(2))
            : Array(otherMembers.prefix(2))
        if !displayed.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(
                    "Plan del grupo",
                    trailing: all.count == 1
                        ? "1 pago para quedar al día"
                        : "\(all.count) pagos para quedar al día"
                )
                VStack(spacing: 0) {
                    if viewerInvolved.isEmpty {
                        Text("Tú estás al día. Estos pagos cierran saldos entre otros miembros.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, RuulSpacing.md)
                            .padding(.vertical, RuulSpacing.sm)
                        rowDivider
                    } else {
                        Text("Tus liquidaciones están arriba. Estos pagos son entre otros miembros.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, RuulSpacing.md)
                            .padding(.vertical, RuulSpacing.sm)
                        rowDivider
                    }
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { idx, s in
                        if idx > 0 { rowDivider }
                        settlementSuggestionRow(s)
                    }
                }
                .ruulCardSurface(.solid)
                if let onOpenSettlementPlan {
                    sectionLink("Ver plan completo", action: onOpenSettlementPlan)
                        .padding(.top, RuulSpacing.xs)
                }
            }
        }
    }

    @ViewBuilder
    private func settlementSuggestionRow(_ s: SettlementSuggestion) -> some View {
        let viewerIsPayer = (s.fromMemberId == myMemberId)
        let viewerIsCreditor = (s.toMemberId == myMemberId)
        let viewerInvolved = viewerIsPayer || viewerIsCreditor
        let isDismissed = (dismissedSuggestionKey == s.key)
        Group {
            if viewerInvolved {
                settlementActionableRow(s, viewerIsPayer: viewerIsPayer)
            } else {
                settlementInfoRow(s)
            }
        }
        .opacity(isDismissed ? 0 : 1)
        .scaleEffect(isDismissed ? 0.97 : 1, anchor: .center)
        .blur(radius: isDismissed ? 3 : 0)
    }

    /// Tappable row for suggestions that involve the viewer. Opens the
    /// `SettlementSheet` pre-filled with the counterpart + amount.
    private func settlementActionableRow(
        _ s: SettlementSuggestion,
        viewerIsPayer: Bool
    ) -> some View {
        let counterpartId = viewerIsPayer ? s.toMemberId : s.fromMemberId
        let counterpartName = memberName(for: counterpartId) ?? "Miembro"
        let verb = viewerIsPayer ? "Págale a" : "Cóbrale a"
        let amount = Decimal(s.amountCents) / 100
        return Button {
            settlementContext = SettlementContext(
                toMemberId: counterpartId,
                amountCents: s.amountCents,
                suggestionKey: s.key,
                viewerIsPayer: viewerIsPayer
            )
        } label: {
            HStack(spacing: RuulSpacing.md) {
                ColoredIconBadge(
                    systemName: viewerIsPayer ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill",
                    tint: viewerIsPayer ? Color.ruulNegative : Color.ruulPositive
                )
                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    Text("\(verb) \(counterpartName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text("Liquidación sugerida")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                RuulMoneyView(
                    amount: amount,
                    currency: group.currency,
                    size: .medium,
                    color: viewerIsPayer ? .negative : .positive
                )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Informational row for suggestions between two other members.
    /// Not tappable (viewer can't record a settlement on their behalf)
    /// but shows the recommended flow so the founder sees the full
    /// payment plan — answers 'cómo se relaciona el dinero entre
    /// miembros'. Visually muted so the actionable rows still stand out.
    private func settlementInfoRow(_ s: SettlementSuggestion) -> some View {
        let payerName = memberName(for: s.fromMemberId) ?? "Miembro"
        let creditorName = memberName(for: s.toMemberId) ?? "Miembro"
        let amount = Decimal(s.amountCents) / 100
        return HStack(spacing: RuulSpacing.md) {
            ColoredIconBadge(
                systemName: "arrow.right.circle",
                tint: Color.secondary
            )
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text("\(payerName) → \(creditorName)")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Text("Liquidación entre miembros")
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            Spacer(minLength: 0)
            RuulMoneyView(
                amount: amount,
                currency: group.currency,
                size: .small,
                color: .neutral
            )
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    /// Money 2.0 Phase 4.4 (2026-05-26): settlement suggestions now read
    /// the per-pair `obligations` table directly when available. Each
    /// outstanding dyad becomes one suggestion ("Bob debe $50 a Alice")
    /// — no greedy reshuffling of net positions. Greedy on per-member
    /// nets was misleading: when Alice was owed by Bob AND owed Carlos,
    /// the greedy could suggest unrelated pairs.
    ///
    /// Fallbacks (older → newer):
    ///   1. `peerObligations` (Phase 4.4) — table-direct dyads. Best.
    ///   2. `obligations` view (Phase 3) — greedy on `netPeerPositionCents`.
    ///   3. `MemberGroupBalance.netCents` (legacy) — greedy on raw nets.
    private func settlementSuggestions(balances rows: [MemberGroupBalance]) -> [SettlementSuggestion] {
        if !peerObligations.isEmpty {
            return dyadicSuggestions()
        }
        return greedySuggestions(balances: rows)
    }

    /// Phase 4.4 path: group active peer obligations by (owed_by, owed_to)
    /// and sum outstanding cents per dyad. One suggestion per dyad,
    /// largest first.
    private func dyadicSuggestions() -> [SettlementSuggestion] {
        struct DyadKey: Hashable {
            let from: UUID
            let to: UUID
        }
        var totals: [DyadKey: Int64] = [:]
        for o in peerObligations where o.currency == group.currency {
            // `isPeerObligation` (set when loaded) guarantees owedTo != nil,
            // but unwrap defensively so the compiler is happy.
            guard let to = o.owedToMemberId else { continue }
            let key = DyadKey(from: o.owedByMemberId, to: to)
            totals[key, default: 0] += o.amountCents
        }
        return totals
            .map { SettlementSuggestion(
                fromMemberId: $0.key.from,
                toMemberId:   $0.key.to,
                amountCents:  $0.value
            )}
            .filter { $0.amountCents > 0 }
            .sorted { $0.amountCents > $1.amountCents }
    }

    /// Legacy greedy path — kept for first-paint and groups with empty
    /// `peerObligations` (e.g. pre-Phase-4.1 backfill, or a brand-new
    /// group). Pairs largest creditor with largest debtor on per-member
    /// nets — approximate but always converges.
    private func greedySuggestions(balances rows: [MemberGroupBalance]) -> [SettlementSuggestion] {
        let pairs: [(memberId: UUID, net: Int64)]
        if !obligations.isEmpty {
            pairs = obligations
                .filter { $0.currency == group.currency }
                .map { (memberId: $0.memberId, net: $0.netPeerPositionCents) }
        } else {
            pairs = rows
                .filter { $0.currency == group.currency && !$0.isSettled }
                .map { (memberId: $0.memberId, net: $0.netCents) }
        }
        var creditors = pairs.filter { $0.net > 0 }
            .sorted { $0.net > $1.net }
        var debtors = pairs.filter { $0.net < 0 }
            .sorted { $0.net < $1.net }
        var out: [SettlementSuggestion] = []
        while let c = creditors.first, let d = debtors.first {
            let amount = min(c.net, -d.net)
            if amount <= 0 { break }
            out.append(SettlementSuggestion(
                fromMemberId: d.memberId,
                toMemberId: c.memberId,
                amountCents: amount
            ))
            let cRemaining = c.net - amount
            let dRemaining = d.net + amount  // closer to zero
            creditors.removeFirst()
            debtors.removeFirst()
            if cRemaining > 0 {
                creditors.insert((memberId: c.memberId, net: cRemaining), at: 0)
            }
            if dRemaining < 0 {
                debtors.insert((memberId: d.memberId, net: dRemaining), at: 0)
            }
        }
        return out
    }

    // MARK: - Movimientos recientes (FASE 4 Wave 4 PR D — filter chips)

    @ViewBuilder
    private var recentMovementsSection: some View {
        if !recentEntries.isEmpty {
            let filtered = filteredRecentEntries
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Movimientos recientes")
                movementFilterChips
                    .padding(.bottom, RuulSpacing.xs)
                // Dashboard preview: top 5 only. Full filterable list
                // lives behind "Ver todas →" → GroupTransactionsView.
                let displayed = Array(filtered.prefix(5))
                VStack(spacing: 0) {
                    if displayed.isEmpty {
                        Text("No hay movimientos con este filtro.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, RuulSpacing.md)
                            .padding(.vertical, RuulSpacing.sm)
                    } else {
                        ForEach(Array(displayed.enumerated()), id: \.element.id) { idx, entry in
                            if idx > 0 { rowDivider }
                            movementRow(entry)
                        }
                    }
                }
                .ruulCardSurface(.solid)
                if let onOpenAllTransactions {
                    sectionLink("Ver todas las transacciones", action: onOpenAllTransactions)
                        .padding(.top, RuulSpacing.xs)
                }
            }
        }
    }

    /// FASE 4 Wave 4 PR D: Mail-style horizontal chip strip filtering
    /// the movement list to a single ledger kind. Hidden when the
    /// entries are sparse (<6 — no real value in filtering 5 rows).
    @ViewBuilder
    private var movementFilterChips: some View {
        if recentEntries.count >= 6 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.xs) {
                    filterChip(label: "Todos", isActive: movementFilter == nil) {
                        withAnimation(.snappy) { movementFilter = nil }
                    }
                    ForEach(MovementFilter.allCases) { f in
                        filterChip(label: f.label, isActive: movementFilter == f) {
                            withAnimation(.snappy) {
                                movementFilter = (movementFilter == f) ? nil : f
                            }
                        }
                    }
                }
                .padding(.horizontal, RuulSpacing.md)
            }
            .padding(.horizontal, -RuulSpacing.md)
        }
    }

    @ViewBuilder
    private func filterChip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isActive ? Color.ruulTextInverse : Color.primary)
                .padding(.horizontal, RuulSpacing.sm)
                .padding(.vertical, RuulSpacing.xxs)
                .background(
                    Capsule().fill(isActive ? Color.ruulAccent : Color(.secondarySystemBackground))
                )
        }
        .buttonStyle(.plain)
    }

    private var filteredRecentEntries: [LedgerEntry] {
        guard let f = movementFilter else { return recentEntries }
        return recentEntries.filter { f.kinds.contains($0.type) }
    }

    /// Reusable section footer link ("Ver todas …"). Styled as a flat
    /// row matching the section cards' tone so the dashboard reads as
    /// one continuous surface.
    private func sectionLink(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.xs) {
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ruulAccent)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.ruulAccent)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func movementRow(_ entry: LedgerEntry) -> some View {
        let amount = Decimal(entry.amountCents) / 100
        let formatted = amount.formatted(.currency(code: entry.currency))
        let icon = movementIcon(entry)
        let primary = movementLabel(entry)
        let secondary = movementSubtitle(entry)
        let canEditNote = entry.recordedBy == app.session?.user.id
        let reversibleId = reversibleId(entry)
        return HStack(spacing: RuulSpacing.md) {
            ColoredIconBadge(systemName: icon, tint: Color.ruulAccent)
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(primary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(formatted)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .contentShape(Rectangle())
        .contextMenu {
            if canEditNote {
                Button {
                    entryEditingNote = NoteEditTarget(
                        entryId: entry.id,
                        initialNote: entry.note ?? ""
                    )
                } label: {
                    Label("Editar nota", systemImage: "pencil")
                }
            }
            if let id = reversibleId {
                Button(role: .destructive) {
                    entryToReverse = id
                } label: {
                    Label("Revertir operación", systemImage: "arrow.uturn.backward.circle")
                }
            }
        }
    }

    private func movementIcon(_ entry: LedgerEntry) -> String {
        switch entry.type {
        case LedgerEntry.Kind.contribution, LedgerEntry.Kind.reimbursement, LedgerEntry.Kind.finePaid:
            return "arrow.down.circle"
        case LedgerEntry.Kind.expense, LedgerEntry.Kind.payout, LedgerEntry.Kind.fineIssued:
            return "arrow.up.circle"
        case LedgerEntry.Kind.settlement:
            return "arrow.left.arrow.right.circle"
        default:
            return "circle"
        }
    }

    private func movementLabel(_ entry: LedgerEntry) -> String {
        if let note = entry.note { return note }
        switch entry.type {
        case LedgerEntry.Kind.contribution:  return "Aporte"
        case LedgerEntry.Kind.expense:       return "Gasto"
        case LedgerEntry.Kind.payout:        return "Pago del grupo"
        case LedgerEntry.Kind.settlement:    return "Liquidación"
        case LedgerEntry.Kind.reimbursement: return "Reembolso"
        case LedgerEntry.Kind.fineIssued:    return "Multa emitida"
        case LedgerEntry.Kind.finePaid:      return "Multa pagada"
        default:                             return entry.type.capitalized
        }
    }

    /// Secondary line: "Para X" when the entry was attributed to a
    /// resource (event/asset/space/fund), plus a "Compartido entre N"
    /// suffix when the entry has a split breakdown. nil keeps the row
    /// compact.
    private func movementSubtitle(_ entry: LedgerEntry) -> String? {
        var parts: [String] = []
        if let resourceId = entry.sourceResourceId,
           let name = resourceNamesById[resourceId] {
            parts.append("Para \(name)")
        }
        if let count = entry.participantCount {
            parts.append("Compartido entre \(count)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Info banner "Cómo funciona el dinero" (FASE 4 Wave 4)

    /// Collapsable explainer of the 3-dimensional money model. Founder
    /// audit 2026-05-25: users didn't know when money enters/exits the
    /// pool, what stake means, or that settlements don't touch the pool.
    /// The banner lives at the bottom of the detail (low-noise default)
    /// and expands on tap.
    @ViewBuilder
    private var moneyInfoBanner: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { moneyInfoExpanded.toggle() }
            } label: {
                HStack(spacing: RuulSpacing.sm) {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.ruulAccent)
                    Text("¿Cómo funciona el dinero aquí?")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.secondary)
                        .rotationEffect(.degrees(moneyInfoExpanded ? 180 : 0))
                }
                .padding(RuulSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if moneyInfoExpanded {
                Divider()
                    .background(Color(.separator))
                VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                    infoLine(
                        icon: "arrow.down.to.line.compact",
                        bold: "Aportar:",
                        body: "metes dinero (o un activo en especie) al grupo. El número del pool sube."
                    )
                    infoLine(
                        icon: "arrow.up.right.circle",
                        bold: "Registrar gasto:",
                        body: "alguien pagó algo del grupo. El pool baja y la persona que pagó queda con saldo a su favor."
                    )
                    infoLine(
                        icon: "arrow.left.arrow.right",
                        bold: "Liquidar:",
                        body: "le pagas o cobras directo a otro miembro. No toca el pool — solo ajusta entre ustedes dos."
                    )
                    infoLine(
                        icon: "exclamationmark.triangle",
                        bold: "Multas:",
                        body: "quedan registradas como deuda al grupo. No tocan el pool hasta que se pagan."
                    )
                    Text("Tu saldo en este grupo se compone de lo que aportaste (tu stake) + lo que el grupo te debe − lo que tú le debes.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .padding(.top, RuulSpacing.xxs)
                }
                .padding(RuulSpacing.md)
            }
        }
        .ruulCardSurface(.solid)
    }

    private func infoLine(icon: String, bold: String, body: String) -> some View {
        let boldText = Text(bold)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.primary)
        let bodyText = Text(body)
            .font(.caption)
            .foregroundStyle(Color.secondary)
        return HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ruulAccent)
                .frame(width: RuulSpacing.lg, alignment: .center)
                .padding(.top, 2)
            Text("\(boldText) \(bodyText)")
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Otros fondos (inline section — PR-A Money UX Consolidation)

    /// Inline section that lists legacy / protected funds (everything
    /// except the shared pool). Replaces the previous footer-link →
    /// separate-screen flow so the user sees ALL the group's money
    /// surfaces on one scroll. Hidden when the group has no other
    /// funds AND no fund-creation callback is wired.
    @ViewBuilder
    private var otherFundsSection: some View {
        if !otherFunds.isEmpty || onCreateFund != nil {
            VStack(alignment: .leading, spacing: 0) {
                otherFundsHeader
                VStack(spacing: 0) {
                    if otherFunds.isEmpty {
                        Text("No hay dineros protegidos. Todo el dinero está en el pool compartido.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, RuulSpacing.md)
                            .padding(.vertical, RuulSpacing.sm)
                    } else {
                        ForEach(Array(otherFunds.enumerated()), id: \.element.id) { idx, fund in
                            if idx > 0 { rowDivider }
                            otherFundRow(fund)
                        }
                    }
                }
                .ruulCardSurface(.solid)
            }
        }
    }

    private var otherFundsHeader: some View {
        HStack {
            Text("Dineros protegidos")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: 0)
            if let onCreateFund {
                Button(action: onCreateFund) {
                    Label("Crear", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.bottom, RuulSpacing.xs)
    }

    @ViewBuilder
    private func otherFundRow(_ fund: Fund) -> some View {
        let formatted = formatCurrency(fund.balanceCents, currency: fund.currency)
        Button {
            onOpenFund?(fund)
        } label: {
            HStack(spacing: RuulSpacing.md) {
                ColoredIconBadge(
                    systemName: "banknote",
                    tint: Color.ruulPositive
                )
                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    Text(fund.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(otherFundSubtitle(fund))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(formatted)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(fund.balanceCents >= 0 ? Color.primary : Color.ruulNegative)
                if onOpenFund != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpenFund == nil)
    }

    private func otherFundSubtitle(_ fund: Fund) -> String {
        let contribs = fund.contributionCount
        let expenses = fund.expenseCount
        switch (contribs, expenses) {
        case (0, 0): return "Sin movimientos"
        default:     return "\(contribs) aportes · \(expenses) gastos"
        }
    }

    private func formatCurrency(_ cents: Int64, currency: String) -> String {
        let units = Double(cents) / 100.0
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: units)) ?? "\(currency) \(Int(units))"
    }

    private var myMemberId: UUID? {
        guard let userId = app.session?.user.id else { return nil }
        return members.first(where: { $0.member.userId == userId })?.member.id
    }

    private func memberName(for memberId: UUID) -> String? {
        members.first(where: { $0.member.id == memberId })?.displayName
    }

    // MARK: - Pool charges section (Phase 4.4)

    /// Active pool charges grouped visually so the viewer sees their
    /// own pending cuotas on top, then everyone else's. Auto-hides
    /// when there are no active charges.
    @ViewBuilder
    private var pendingPoolChargesSection: some View {
        if !poolCharges.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack {
                    Text("Cuotas pendientes")
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text("\(poolCharges.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }
                let viewer = myMemberId
                let mine = viewer.map { v in poolCharges.filter { $0.owedByMemberId == v } } ?? []
                let others = viewer.map { v in poolCharges.filter { $0.owedByMemberId != v } } ?? poolCharges
                if !mine.isEmpty {
                    VStack(spacing: RuulSpacing.xs) {
                        ForEach(mine, id: \.id) { poolChargeRow($0, isMine: true) }
                    }
                }
                if !others.isEmpty {
                    if !mine.isEmpty {
                        Text("De otros miembros")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                            .padding(.top, RuulSpacing.xs)
                    }
                    VStack(spacing: RuulSpacing.xs) {
                        ForEach(others, id: \.id) { poolChargeRow($0, isMine: false) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func poolChargeRow(_ charge: Obligation, isMine: Bool) -> some View {
        let name = memberName(for: charge.owedByMemberId) ?? "Miembro"
        let amount = formattedPoolChargeAmount(charge)
        let canVoid = viewerCanVoid(charge)
        Button {
            if isMine {
                payingPoolCharge = charge
            } else {
                // Anyone in the group can cover someone else's cuota
                // via the tri-role payer (paid_by ≠ owed_by). The pay
                // sheet picker defaults to the debtor but flips with
                // one tap.
                payingPoolCharge = charge
            }
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: charge.isOverdue ? "exclamationmark.circle.fill" : "person.2.badge.minus")
                    .font(.title3)
                    .foregroundStyle(charge.isOverdue ? Color.ruulNegative : Color.ruulAccent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: RuulSpacing.xs) {
                        Text(isMine ? "Debes" : "\(name) debe")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text(amount)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .monospacedDigit()
                    }
                    if let reason = charge.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                    if let due = charge.dueAt {
                        Text(charge.isOverdue ? "Venció el \(formattedDate(due))" : "Vence \(formattedDate(due))")
                            .font(.caption2)
                            .foregroundStyle(charge.isOverdue ? Color.ruulNegative : Color.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(RuulSpacing.md)
            .ruulCardSurface(.solid)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canVoid {
                Button(role: .destructive) {
                    voidingPoolChargeId = charge.id
                } label: {
                    Label("Anular", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func viewerCanVoid(_ charge: Obligation) -> Bool {
        guard let viewerUserId = app.session?.user.id else { return false }
        // Original issuer can always void.
        if let issuer = charge.metadata["issued_by"]?.stringValue,
           let issuerUUID = UUID(uuidString: issuer),
           issuerUUID == viewerUserId {
            return true
        }
        // Admin / founder roles (mirror of the void_pool_charge RPC
        // check). MemberWithProfile.member.roles holds the role array.
        if let me = members.first(where: { $0.member.userId == viewerUserId }) {
            let roles = me.member.roles
            return roles.contains(.admin) || roles.contains(.founder)
        }
        return false
    }

    private func formattedPoolChargeAmount(_ charge: Obligation) -> String {
        let amount = Decimal(charge.amountCents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = charge.currency
        f.locale = Locale(identifier: "es_MX")
        f.maximumFractionDigits = 0
        return f.string(from: amount as NSDecimalNumber) ?? "\(charge.currency) \(charge.amountCents / 100)"
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateStyle = .medium
        return f.string(from: date)
    }

    @MainActor
    private func performVoidPoolCharge(_ id: UUID) async {
        voidingPoolChargeId = nil
        do {
            _ = try await app.ledgerRepo.voidPoolCharge(
                obligationId: id,
                reason: nil
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// FASE 4 Wave 4: viewer's fines across all groups (best-effort).
    /// `load()` filters this down to the active ones in this group.
    private func fetchMyActiveFines() async -> [Fine] {
        guard let userId = app.session?.user.id else { return [] }
        return (try? await app.fineRepo.myFines(userId: userId)) ?? []
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        // Load members + balances + entries + other-funds + fines in
        // parallel. Members + other-funds + entries + fines are
        // best-effort. Entries limit is 200 so the "Por contexto"
        // aggregation has enough material; the "Movimientos recientes"
        // section still caps display to 5.
        async let membersTask = (try? await app.groupsRepo.membersWithProfiles(of: group.id)) ?? []
        async let balancesTask = app.ledgerRepo.balancesForGroup(group.id)
        async let entriesTask = (try? await app.ledgerRepo.list(groupId: group.id, limit: 200)) ?? []
        async let otherFundsTask = otherFundsForGroup()
        async let summaryTask = (try? await app.fundRepo.summaryForGroup(
            group.id, preferredCurrency: group.currency
        )) ?? nil
        async let finesTask = fetchMyActiveFines()
        async let obligationsTask: [MemberObligationSummary] =
            (try? await app.ledgerRepo.obligationsForGroup(group.id)) ?? []
        // Phase 4.4: per-pair obligations for direct dyad allocation.
        async let peerObligationsTask: [Obligation] =
            (try? await app.ledgerRepo.obligationsTable(group.id)) ?? []
        do {
            members = await membersTask
            balances = try await balancesTask
            obligations = await obligationsTask
            let allObligations = await peerObligationsTask
            peerObligations = allObligations
                .filter { $0.isActive && $0.isPeerObligation }
            // Phase 4.4: surface active pool charges separately. Newest
            // first; overdue ones bubble up via row styling, not sort
            // order (so payment history stays predictable).
            poolCharges = allObligations
                .filter { $0.isActive && $0.isPoolCharge }
                .sorted { $0.createdAt > $1.createdAt }
            recentEntries = await entriesTask
            otherFunds = await otherFundsTask
            // FASE 4 Wave 4: filter the cross-group list to this group
            // + active statuses (pending, in-appeal, proposed). Paid /
            // voided fines don't surface — historial vive en MyFines.
            let active: Set<FineStatus> = [.officialized, .proposed, .inAppeal]
            activeFines = (await finesTask)
                .filter { $0.groupId == group.id && active.contains($0.status) }
                .sorted { $0.createdAt > $1.createdAt }
            sharedPoolSummary = await summaryTask
            await loadResourceNames()
        } catch {
            errorMessage = "No pudimos cargar los balances."
        }
    }

    /// Resolve resource names for the entries' `source_resource_id`
    /// values so the "Para X" subtitle can render. Looks up one
    /// `ResourceRepository.resource(_:)` per distinct id; failures
    /// soft-skip — the row falls back to its primary label.
    private func loadResourceNames() async {
        let ids = Set(recentEntries.compactMap { $0.sourceResourceId })
        guard !ids.isEmpty else { return }
        var resolved: [UUID: String] = resourceNamesById
        for id in ids where resolved[id] == nil {
            if let row = try? await app.resourceRepo.resource(id) {
                let name = row.metadata["name"]?.stringValue
                    ?? row.metadata["title"]?.stringValue
                    ?? row.resourceType.humanLabel
                resolved[id] = name
            }
        }
        resourceNamesById = resolved
    }

    /// Legacy / protected funds for this group — the canonical shared
    /// pool is filtered out via `summaryForGroup.sharedPoolId`,
    /// mirroring the (now-deprecated for primary nav) `GroupFundsListView`
    /// resolution policy. Best-effort: returns empty on repo failure.
    private func otherFundsForGroup() async -> [Fund] {
        async let allFundsTask = (try? await app.fundRepo.listForGroup(group.id)) ?? []
        async let sharedPoolTask = (try? await app.fundRepo.summaryForGroup(
            group.id, preferredCurrency: group.currency
        ))?.sharedPoolId
        let allFunds = await allFundsTask
        let sharedPoolId = await sharedPoolTask
        return allFunds.filter { $0.fundId != sharedPoolId }
    }
}

// MARK: - MemberGroupBalance helpers

private extension MemberGroupBalance {
    /// Returns a copy with the given netCents — used by the greedy
    /// settlement algorithm to recompute remainders without mutating
    /// the stored array.
    func with(netCents newNet: Int64) -> MemberGroupBalance {
        MemberGroupBalance(
            groupId: groupId,
            memberId: memberId,
            currency: currency,
            sentCents: sentCents,
            receivedCents: receivedCents,
            netCents: newNet
        )
    }
}
