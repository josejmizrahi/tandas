import SwiftUI
import RuulUI
import RuulCore

/// SharedMoney P3 (consolidated 2026-05-24): the single "Dinero del
/// grupo" detail hub — pushed from the inline "Te deben / Debes" strip
/// inside `SharedMoneyCard` and from anywhere else the user wants the
/// full money picture for the group.
///
/// Sections:
///   - Per-member nets (the "Te deben / Debes" breakdown)
///   - Other funds (legacy / protected) footer link — keeps the
///     shared-money doctrine ("ONE pool por defecto") on top while
///     surfacing exception funds without giving them peer status.
///
/// Each balance row shows the member's display name + their `netCents`.
/// Sorted by absolute net descending so the largest debtors/creditors
/// lead. Current viewer's row is labeled "Tú" (consistent with the
/// Money Block's per-member breakdown convention).
///
/// V1 simple — no pairwise "X le debe a Y" breakdown. The view's net
/// per member is the canonical answer; Splitwise-style settlement
/// routing is a future brick.
@MainActor
public struct GroupBalancesView: View {
    public let group: RuulCore.Group
    /// Optional callback that pushes the legacy "Otros fondos" list.
    /// Nil → the footer link is hidden (no funds OR no nav available).
    public let onOpenOtherFunds: (() -> Void)?

    @Environment(AppState.self) private var app

    @State private var members: [MemberWithProfile] = []
    @State private var balances: [MemberGroupBalance] = []
    @State private var otherFundsCount: Int = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    public init(group: RuulCore.Group, onOpenOtherFunds: (() -> Void)? = nil) {
        self.group = group
        self.onOpenOtherFunds = onOpenOtherFunds
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
                        otherFundsFooter
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
    }

    /// Footer link that pushes the legacy "Otros fondos" list. Hidden
    /// when there are no other funds or no nav callback was provided.
    @ViewBuilder
    private var otherFundsFooter: some View {
        if otherFundsCount > 0, let onOpenOtherFunds {
            Button(action: onOpenOtherFunds) {
                HStack(spacing: RuulSpacing.md) {
                    ColoredIconBadge(
                        systemName: "banknote",
                        tint: Color.ruulPositive
                    )
                    VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                        Text("Otros fondos")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text(otherFundsCount == 1
                             ? "1 fondo separado"
                             : "\(otherFundsCount) fondos separados")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 0)
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
            .padding(.top, RuulSpacing.md)
        }
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
        // Load members + balances + other-funds count in parallel.
        // Members + other-funds are best-effort: if either fails, rows
        // still render with the "Miembro" fallback label and the
        // footer link is hidden.
        async let membersTask = (try? await app.groupsRepo.membersWithProfiles(of: group.id)) ?? []
        async let balancesTask = app.ledgerRepo.balancesForGroup(group.id)
        async let otherFundsTask = otherFundsCountForGroup()
        do {
            members = await membersTask
            balances = try await balancesTask
            otherFundsCount = await otherFundsTask
        } catch {
            errorMessage = "No pudimos cargar los balances."
        }
    }

    /// Count of legacy / protected funds for this group — the canonical
    /// shared pool is filtered out via `summaryForGroup.sharedPoolId`,
    /// mirroring the `GroupFundsListView` resolution policy. Best-effort:
    /// returns 0 on any repo failure.
    private func otherFundsCountForGroup() async -> Int {
        async let allFundsTask = (try? await app.fundRepo.listForGroup(group.id)) ?? []
        async let sharedPoolTask = (try? await app.fundRepo.summaryForGroup(
            group.id, preferredCurrency: group.currency
        ))?.sharedPoolId
        let allFunds = await allFundsTask
        let sharedPoolId = await sharedPoolTask
        return allFunds.filter { $0.fundId != sharedPoolId }.count
    }
}
