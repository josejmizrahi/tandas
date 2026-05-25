import SwiftUI
import RuulUI
import RuulCore

/// SharedMoney P3 (consolidated 2026-05-24): the single "Dinero del
/// grupo" detail hub — pushed from the inline "Te deben / Debes" strip
/// inside `SharedMoneyCard` and from anywhere else the user wants the
/// full money picture for the group.
///
/// Sections (top → bottom):
///   - Per-member nets (the "Te deben / Debes" breakdown)
///   - Liquidar ahora — greedy settlement suggestions involving the
///     current viewer (paired debtor ↔ creditor amounts). Each tap
///     opens `SettlementSheet` pre-filled with the pair.
///   - Movimientos recientes — last 15 ledger entries for the group,
///     with `Para X` association when the entry was attributed to a
///     specific resource (event/asset/fund) via `source_resource_id`.
///   - Otros fondos — INLINE list (Money UX Consolidation PR-A,
///     2026-05-24). Legacy `GroupFundsListView` separate screen is no
///     longer in the primary flow; fund rows render here and tap
///     opens the fund resource detail directly.
///
/// V1 simple — the suggestions are a greedy "pair largest debtor with
/// largest creditor" algorithm, not full multi-currency optimum
/// matching. Splitwise-style global optimization is deferred to a
/// future brick (would shorten chains but adds backend support).
@MainActor
public struct GroupBalancesView: View {
    public let group: RuulCore.Group
    /// Callback that opens a fund detail. Routed by the host (typically
    /// MyGroupsTab via `router.openResource`) so this view stays
    /// presentation-only. Nil → fund rows render as labels without tap.
    public let onOpenFund: ((Fund) -> Void)?
    /// Callback to launch the fund-creation flow (resource wizard
    /// pre-selected to `.fund`). Nil → "Crear fondo" CTA hidden.
    public let onCreateFund: (() -> Void)?

    @Environment(AppState.self) private var app

    @State private var members: [MemberWithProfile] = []
    @State private var balances: [MemberGroupBalance] = []
    @State private var otherFunds: [Fund] = []
    @State private var recentEntries: [LedgerEntry] = []
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
        onCreateFund: (() -> Void)? = nil
    ) {
        self.group = group
        self.onOpenFund = onOpenFund
        self.onCreateFund = onCreateFund
    }

    private struct NoteEditTarget: Identifiable {
        let id = UUID()
        let entryId: UUID
        let initialNote: String
    }

    /// Identifiable wrapper for the `.sheet(item:)` presentation of
    /// the settlement sheet. Carries the pre-filled (from, to, amount)
    /// from a tapped suggestion.
    private struct SettlementContext: Identifiable {
        let id = UUID()
        let toMemberId: UUID
        let amountCents: Int64
    }

    /// One greedy settlement suggestion: `from` owes `amountCents` to
    /// `to`. Built by `settlementSuggestions()` from the per-member nets.
    private struct SettlementSuggestion: Identifiable {
        let id = UUID()
        let fromMemberId: UUID
        let toMemberId: UUID
        let amountCents: Int64
    }

    private var phase: LoadPhase<[MemberGroupBalance]> {
        let coordError: CoordinatorError? = errorMessage.map {
            CoordinatorError(title: "No pudimos cargar los balances", message: $0, isRetryable: true)
        }
        return LoadPhase.fromCollection(
            value: visibleRows,
            hasLoaded: hasLoaded,
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

    public var body: some View {
        AsyncContentView(
            phase: phase,
            onRetry: { await load() },
            empty: {
                ContentUnavailableView {
                    Label("Todos están al día", systemImage: "checkmark.circle")
                } description: {
                    Text("Nadie tiene una posición pendiente con el grupo en \(group.currency).")
                }
            },
            loaded: { rows in
                ScrollView {
                    LazyVStack(spacing: RuulSpacing.sm) {
                        ForEach(rows) { row in
                            balanceRow(row)
                        }
                        settlementSuggestionsSection
                        recentMovementsSection
                        otherFundsSection
                    }
                    .padding(RuulSpacing.lg)
                }
                .refreshable { await load() }
            }
        )
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Dinero del grupo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $settlementContext) { ctx in
            SettlementSheet(
                groupId: group.id,
                resourceId: nil,
                currency: group.currency,
                members: members,
                suggestedToMemberId: ctx.toMemberId,
                onDidSettle: { Task { await load() } }
            )
            .environment(app)
            .presentationDetents([.medium, .large])
            .presentationBackground(.regularMaterial)
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

    // MARK: - Liquidar ahora

    /// Settlement suggestions section — PR-E (2026-05-24): shows the
    /// FULL settlement plan for the group (greedy pairing), not only
    /// suggestions involving the viewer. Rows where the viewer is
    /// either payer or recipient are tappable and open `SettlementSheet`
    /// pre-filled. Rows between two other members render as informational
    /// so the founder can see "how money flows" across the group — the
    /// 'cómo se relaciona' clarity they asked for.
    @ViewBuilder
    private var settlementSuggestionsSection: some View {
        let all = settlementSuggestions(balances: visibleRows)
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                HStack {
                    Text("Liquidar ahora")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Spacer(minLength: 0)
                    Text(all.count == 1
                         ? "1 pago para quedar al día"
                         : "\(all.count) pagos para quedar al día")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
                .padding(.top, RuulSpacing.md)
                ForEach(Array(all.prefix(5))) { s in
                    settlementSuggestionRow(s)
                }
                if all.count > 5 {
                    Text("+ \(all.count - 5) más")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .padding(.leading, RuulSpacing.md)
                }
            }
        }
    }

    @ViewBuilder
    private func settlementSuggestionRow(_ s: SettlementSuggestion) -> some View {
        let viewerIsPayer = (s.fromMemberId == myMemberId)
        let viewerIsCreditor = (s.toMemberId == myMemberId)
        let viewerInvolved = viewerIsPayer || viewerIsCreditor
        if viewerInvolved {
            settlementActionableRow(s, viewerIsPayer: viewerIsPayer)
        } else {
            settlementInfoRow(s)
        }
    }

    /// Tappable row for suggestions that involve the viewer. Opens the
    /// `SettlementSheet` pre-filled with the counterpart + amount.
    private func settlementActionableRow(
        _ s: SettlementSuggestion,
        viewerIsPayer: Bool
    ) -> some View {
        let counterpartId = viewerIsPayer ? s.toMemberId : s.fromMemberId
        let counterpartName = memberName(for: counterpartId) ?? "Miembro"
        let verb = viewerIsPayer ? "Pagale a" : "Cobrale a"
        let amount = Decimal(s.amountCents) / 100
        return Button {
            settlementContext = SettlementContext(
                toMemberId: counterpartId,
                amountCents: s.amountCents
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
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
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
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg)
                .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
    }

    /// Pure function: pair off largest debtor with largest creditor
    /// until one side runs out. Doesn't mutate `balances` — works on a
    /// local copy of the nets.
    private func settlementSuggestions(balances rows: [MemberGroupBalance]) -> [SettlementSuggestion] {
        var creditors = rows.filter { $0.netCents > 0 }
            .sorted { $0.netCents > $1.netCents }
        var debtors = rows.filter { $0.netCents < 0 }
            .sorted { $0.netCents < $1.netCents }
        var out: [SettlementSuggestion] = []
        while let c = creditors.first, let d = debtors.first {
            let amount = min(c.netCents, -d.netCents)
            if amount <= 0 { break }
            out.append(SettlementSuggestion(
                fromMemberId: d.memberId,
                toMemberId: c.memberId,
                amountCents: amount
            ))
            // Recompute remainders. We need a way to construct an
            // updated MemberGroupBalance — easiest path is to drop the
            // settled side(s) and re-enqueue with reduced amount.
            let cRemaining = c.netCents - amount
            let dRemaining = d.netCents + amount  // closer to zero
            creditors.removeFirst()
            debtors.removeFirst()
            if cRemaining > 0 {
                creditors.insert(c.with(netCents: cRemaining), at: 0)
            }
            if dRemaining < 0 {
                debtors.insert(d.with(netCents: dRemaining), at: 0)
            }
        }
        return out
    }

    // MARK: - Movimientos recientes

    @ViewBuilder
    private var recentMovementsSection: some View {
        if !recentEntries.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Movimientos recientes")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(.top, RuulSpacing.md)
                ForEach(recentEntries) { entry in
                    movementRow(entry)
                }
            }
        }
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
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
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

    // MARK: - Otros fondos (inline section — PR-A Money UX Consolidation)

    /// Inline section that lists legacy / protected funds (everything
    /// except the shared pool). Replaces the previous footer-link →
    /// separate-screen flow so the user sees ALL the group's money
    /// surfaces on one scroll. Hidden when the group has no other
    /// funds AND no fund-creation callback is wired.
    @ViewBuilder
    private var otherFundsSection: some View {
        if !otherFunds.isEmpty || onCreateFund != nil {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                HStack {
                    Text("Otros fondos")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
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
                .padding(.top, RuulSpacing.md)

                if otherFunds.isEmpty {
                    Text("No hay fondos separados. Todo el dinero está en el pool compartido.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .padding(.vertical, RuulSpacing.sm)
                } else {
                    ForEach(otherFunds, id: \.id) { fund in
                        otherFundRow(fund)
                    }
                }
            }
        }
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
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
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

    private func balanceRow(_ row: MemberGroupBalance) -> some View {
        let isMe = (row.memberId == myMemberId)
        let name = isMe ? "Tú" : (memberName(for: row.memberId) ?? "Miembro")
        let amount = Decimal(abs(row.netCents)) / 100
        return HStack(spacing: RuulSpacing.md) {
            ColoredIconBadge(
                systemName: row.isOwed ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill",
                tint: row.isOwed ? Color.ruulPositive : Color.ruulNegative
            )

            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(row.isOwed ? "Le deben" : "Debe al grupo")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 0)

            RuulMoneyView(
                amount: amount,
                currency: row.currency,
                size: .medium,
                color: row.isOwed ? .positive : .negative
            )
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var myMemberId: UUID? {
        guard let userId = app.session?.user.id else { return nil }
        return members.first(where: { $0.member.userId == userId })?.member.id
    }

    private func memberName(for memberId: UUID) -> String? {
        members.first(where: { $0.member.id == memberId })?.displayName
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        // Load members + balances + entries + other-funds in parallel.
        // Members + other-funds + entries are best-effort.
        async let membersTask = (try? await app.groupsRepo.membersWithProfiles(of: group.id)) ?? []
        async let balancesTask = app.ledgerRepo.balancesForGroup(group.id)
        async let entriesTask = (try? await app.ledgerRepo.list(groupId: group.id, limit: 15)) ?? []
        async let otherFundsTask = otherFundsForGroup()
        do {
            members = await membersTask
            balances = try await balancesTask
            recentEntries = await entriesTask
            otherFunds = await otherFundsTask
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
