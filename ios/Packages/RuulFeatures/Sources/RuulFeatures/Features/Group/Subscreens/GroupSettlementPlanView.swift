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

    public init(group: RuulCore.Group) {
        self.group = group
    }

    private struct SettlementContext: Identifiable {
        let id = UUID()
        let toMemberId: UUID
        let amountCents: Int64
    }

    private struct SettlementSuggestion: Identifiable {
        let id = UUID()
        let fromMemberId: UUID
        let toMemberId: UUID
        let amountCents: Int64
    }

    private var visibleBalances: [MemberGroupBalance] {
        balances
            .filter { $0.currency == group.currency && !$0.isSettled }
            .sorted { abs($0.netCents) > abs($1.netCents) }
    }

    private var suggestions: [SettlementSuggestion] {
        settlementSuggestions(balances: visibleBalances)
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: RuulSpacing.sm) {
                headerCard
                if suggestions.isEmpty && hasLoaded {
                    emptyState
                } else {
                    ForEach(suggestions) { s in
                        suggestionRow(s)
                    }
                }
            }
            .padding(RuulSpacing.lg)
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
                onDidSettle: { Task { await load() } }
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
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Todos al día", systemImage: "checkmark.circle.fill")
        } description: {
            Text("Nadie tiene posiciones pendientes en \(group.currency).")
        }
        .padding(.top, RuulSpacing.xl)
    }

    // MARK: - Rows

    @ViewBuilder
    private func suggestionRow(_ s: SettlementSuggestion) -> some View {
        let viewerIsPayer = (s.fromMemberId == myMemberId)
        let viewerIsCreditor = (s.toMemberId == myMemberId)
        if viewerIsPayer || viewerIsCreditor {
            actionableRow(s, viewerIsPayer: viewerIsPayer)
        } else {
            infoRow(s)
        }
    }

    private func actionableRow(_ s: SettlementSuggestion, viewerIsPayer: Bool) -> some View {
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
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
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
