import SwiftUI
import RuulUI
import RuulCore

/// Full greedy settlement plan for the group. Pushed from the "Dinero
/// del grupo" dashboard's "Liquidar" section "Ver plan completo →"
/// CTA after the Money UX Consolidation 2026-05-24 refactor.
///
/// Same algorithm + row shapes as the hub preview, but uncapped: shows
/// every pair (debtor → creditor) the greedy algorithm produces, with
/// viewer-involved rows actionable and the rest informational. Header
/// tracks "N pagos para quedar al día".
@MainActor
public struct GroupSettlementPlanView: View {
    public let group: RuulCore.Group

    @Environment(AppState.self) private var app

    @State private var members: [MemberWithProfile] = []
    @State private var balances: [MemberGroupBalance] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var settlementContext: SettlementContext?
    /// FASE 4 Wave 2 (2026-05-25): hide third-party suggestions by
    /// default. Showing everyone's debts on first land reads like
    /// ledger surveillance; the viewer should only see pairs they're
    /// involved in unless they opt in via the footer toggle.
    @State private var showThirdParty = false

    public init(group: RuulCore.Group) {
        self.group = group
    }

    private struct SettlementContext: Identifiable {
        let id = UUID()
        let toMemberId: UUID
        let amountCents: Int64
        /// Stable key for the suggestion the user just resolved, so the
        /// matching row can be animated out post-dismiss.
        let suggestionKey: String
        /// Which side of the dyad the viewer was on. Drives the
        /// closure-card phrasing ("Le pagaste" vs "X te pagó").
        let viewerIsPayer: Bool
    }

    private struct SettlementSuggestion: Identifiable {
        let id = UUID()
        let fromMemberId: UUID
        let toMemberId: UUID
        let amountCents: Int64

        var key: String {
            "\(fromMemberId.uuidString)|\(toMemberId.uuidString)|\(amountCents)"
        }
    }

    /// FASE 4 Wave 2 (2026-05-25): which row to fade after dismiss.
    @State private var dismissedSuggestionKey: String?
    /// FASE 4 Wave 2 (2026-05-25): closure banner post-settle.
    @State private var recentClosure: DyadicClosureState?

    private var visibleBalances: [MemberGroupBalance] {
        balances
            .filter { $0.currency == group.currency && !$0.isSettled }
            .sorted { abs($0.netCents) > abs($1.netCents) }
    }

    private var suggestions: [SettlementSuggestion] {
        settlementSuggestions(balances: visibleBalances)
    }

    public var body: some View {
        let all = suggestions
        let viewerOnly = all.filter {
            $0.fromMemberId == myMemberId || $0.toMemberId == myMemberId
        }
        let displayed = showThirdParty ? all : viewerOnly
        let hiddenCount = all.count - viewerOnly.count
        return ScrollView {
            LazyVStack(spacing: RuulSpacing.sm) {
                closureBanner
                headerCard
                if hasLoaded && all.isEmpty {
                    emptyState
                } else if hasLoaded && displayed.isEmpty {
                    viewerSettledPrompt(hiddenCount: hiddenCount)
                } else {
                    ForEach(displayed) { s in
                        suggestionRow(s)
                    }
                }
                if hiddenCount > 0 && !displayed.isEmpty {
                    thirdPartyToggle(hiddenCount: hiddenCount)
                }
            }
            .padding(RuulSpacing.lg)
            .animation(.snappy, value: showThirdParty)
        }
        .refreshable { await load() }
        .background(Color.ruulBackgroundRecessed.ignoresSafeArea())
        .navigationTitle("Liquidación del grupo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $settlementContext) { ctx in
            SettlementSheet(
                groupId: group.id,
                resourceId: nil,
                currency: group.currency,
                members: members,
                suggestedToMemberId: ctx.toMemberId,
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
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Plan de pagos sugerido")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
            if suggestions.isEmpty {
                Text("Todos los miembros están al día.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            } else {
                Text(suggestions.count == 1
                     ? "1 pago para que todos queden al día."
                     : "\(suggestions.count) pagos para que todos queden al día.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Text("Toca un pago en el que estés involucrado para registrarlo.")
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(.top, RuulSpacing.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.md)
        .ruulCardSurface(.solid)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Todos al día", systemImage: "checkmark.circle.fill")
        } description: {
            Text("Nadie tiene posiciones pendientes en \(group.currency).")
        }
        .padding(.top, RuulSpacing.xl)
    }

    /// Shown when the viewer has no pending pairs but other members
    /// still owe each other. Keeps the screen calm + on-message instead
    /// of feeling broken / empty.
    private func viewerSettledPrompt(hiddenCount: Int) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Label("Estás al día", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ruulPositive)
            if hiddenCount > 0 {
                Text(hiddenCount == 1
                     ? "Queda 1 pago sugerido entre otros miembros."
                     : "Quedan \(hiddenCount) pagos sugeridos entre otros miembros.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Button {
                    withAnimation(.snappy) { showThirdParty = true }
                } label: {
                    Text("Verlos")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulAccent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.md)
        .ruulCardSurface(.solid)
    }

    /// Footer link to reveal / hide settlement rows between members
    /// the viewer is not involved in. Subtle accent-only treatment so
    /// it reads as opt-in detail, not a primary action.
    private func thirdPartyToggle(hiddenCount: Int) -> some View {
        Button {
            withAnimation(.snappy) { showThirdParty.toggle() }
        } label: {
            Label(
                showThirdParty
                    ? "Ocultar pagos entre otros miembros"
                    : "Mostrar pagos entre otros miembros (\(hiddenCount))",
                systemImage: showThirdParty ? "eye.slash" : "eye"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.ruulAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    @ViewBuilder
    private func suggestionRow(_ s: SettlementSuggestion) -> some View {
        let viewerIsPayer = (s.fromMemberId == myMemberId)
        let viewerIsCreditor = (s.toMemberId == myMemberId)
        let isDismissed = (dismissedSuggestionKey == s.key)
        Group {
            if viewerIsPayer || viewerIsCreditor {
                actionableRow(s, viewerIsPayer: viewerIsPayer)
            } else {
                infoRow(s)
            }
        }
        .opacity(isDismissed ? 0 : 1)
        .scaleEffect(isDismissed ? 0.97 : 1, anchor: .center)
        .blur(radius: isDismissed ? 3 : 0)
    }

    private func actionableRow(_ s: SettlementSuggestion, viewerIsPayer: Bool) -> some View {
        let counterpartId = viewerIsPayer ? s.toMemberId : s.fromMemberId
        let counterpartName = memberName(for: counterpartId) ?? "Miembro"
        let verb = viewerIsPayer ? "Pagale a" : "Cobrale a"
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
                    Text("Te toca a ti")
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
            .ruulCardSurface(.solid)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func infoRow(_ s: SettlementSuggestion) -> some View {
        let payerName = memberName(for: s.fromMemberId) ?? "Miembro"
        let creditorName = memberName(for: s.toMemberId) ?? "Miembro"
        let amount = Decimal(s.amountCents) / 100
        return HStack(spacing: RuulSpacing.md) {
            ColoredIconBadge(systemName: "arrow.right.circle", tint: Color.secondary)
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text("\(payerName) → \(creditorName)")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Text("Entre miembros")
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

    @MainActor
    private func presentClosure(
        counterpartId: UUID,
        amount: Decimal,
        viewerSide: DyadicClosureCard.ViewerSide
    ) async {
        let stillSuggested = settlementSuggestions(balances: visibleBalances).contains { s in
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

    // MARK: - Algorithm

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
            let cRemaining = c.netCents - amount
            let dRemaining = d.netCents + amount
            creditors.removeFirst()
            debtors.removeFirst()
            if cRemaining > 0 {
                creditors.insert(rebalance(c, netCents: cRemaining), at: 0)
            }
            if dRemaining < 0 {
                debtors.insert(rebalance(d, netCents: dRemaining), at: 0)
            }
        }
        return out
    }

    /// Local clone of `MemberGroupBalance` with a new netCents. The
    /// `with(netCents:)` extension in `GroupBalancesView` is file-private
    /// — duplicated here rather than promoting to a public helper since
    /// both uses are presentation-only and tied to the greedy algorithm.
    private func rebalance(_ b: MemberGroupBalance, netCents: Int64) -> MemberGroupBalance {
        MemberGroupBalance(
            groupId: b.groupId,
            memberId: b.memberId,
            currency: b.currency,
            sentCents: b.sentCents,
            receivedCents: b.receivedCents,
            netCents: netCents
        )
    }

    // MARK: - Helpers

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
        async let membersTask = (try? await app.groupsRepo.membersWithProfiles(of: group.id)) ?? []
        async let balancesTask = (try? await app.ledgerRepo.balancesForGroup(group.id)) ?? []
        members = await membersTask
        balances = await balancesTask
    }
}
