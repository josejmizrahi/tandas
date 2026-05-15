import SwiftUI
import RuulUI
import RuulCore

/// Money primitive renderer. Tap the card → caller opens the
/// `ResourceLedgerSheet` (delegated via context.onPresentLedger).
///
/// Tier 6 slice 18 (mig 00136): renders top-3 non-zero balances inline
/// above the "Movimientos" button so the user sees who's owed / owes
/// without tapping into the sheet. Balances come from the
/// `member_balances_per_resource` SQL view via `BalanceRepository`.
/// Degrades to the legacy button-only layout when the resource has no
/// ledger entries yet.
public struct MoneySectionView: View {
    @Environment(AppState.self) private var app
    public let context: ResourceDetailContext

    @State private var topBalances: [MemberBalance] = []
    @State private var hasLoaded: Bool = false
    @State private var settlementSheetPresented: Bool = false

    public static let definition = CapabilitySection(
        id: "money",
        priority: 400,
        isEnabledFor: { caps in
            // `ledger` is the canonical block name basic_fines (V1) and
            // future common_fund modules provide. The narrower
            // expenses/contributions/payouts cases hook in once their
            // Phase 2 modules ship dedicated providedCapabilityBlocks.
            // Keep `money` as a forward-compat synonym so a future
            // catalog rename doesn't need a migration.
            caps.contains("ledger") ||
            caps.contains("money") ||
            caps.contains("expenses") ||
            caps.contains("contributions") ||
            caps.contains("payouts")
        },
        render: { ctx in AnyView(MoneySectionView(context: ctx)) }
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            sectionHeader("DINERO")
            if !topBalances.isEmpty {
                balancesCard
            }
            // Tier 6 final: "Registrar pago" surfaces when the current
            // user owes someone (any negative-net row that's theirs).
            // Tapping opens SettlementSheet → record_settlement RPC.
            if currentUserOwes {
                Button {
                    settlementSheetPresented = true
                } label: {
                    HStack(spacing: RuulSpacing.sm) {
                        iconBadge(systemName: "checkmark.circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Registrar pago")
                                .ruulTextStyle(RuulTypography.headline)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Text("Salda parte o todo de lo que debes")
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .ruulTextStyle(RuulTypography.captionBold)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .padding(RuulSpacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cardBackground()
            }
            Button(action: context.onPresentLedger) {
                HStack(spacing: RuulSpacing.sm) {
                    iconBadge(systemName: "arrow.left.arrow.right")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Movimientos")
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text(subtitle)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .ruulTextStyle(RuulTypography.captionBold)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .padding(RuulSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardBackground()
        }
        .task { await loadBalances() }
        .sheet(isPresented: $settlementSheetPresented) {
            SettlementSheet(
                groupId: context.group.id,
                resourceId: context.resource.id,
                currency: settlementCurrency,
                members: Array(context.memberDirectory.values),
                suggestedToMemberId: largestPositiveMemberId,
                onDidSettle: {
                    // Force re-fetch so the inline rows reflect the
                    // settlement immediately. Without the reset
                    // .task wouldn't re-run.
                    hasLoaded = false
                    topBalances = []
                    Task { await loadBalances() }
                }
            )
        }
    }

    /// True when one of the inline balance rows belongs to the current
    /// user AND has net < 0. Used to surface the "Registrar pago"
    /// button only when there's something to settle.
    private var currentUserOwes: Bool {
        topBalances.contains { balance in
            balance.netCents < 0 && isCurrentUserMember(balance.memberId)
        }
    }

    /// Member with the largest positive net (the canonical "to" target
    /// of a settlement). nil when there's no positive row in scope.
    private var largestPositiveMemberId: UUID? {
        topBalances
            .filter { $0.netCents > 0 }
            .sorted { $0.netCents > $1.netCents }
            .first?.memberId
    }

    /// Currency to settle in. We prefer the currency of the row the
    /// current user owes (multi-currency groups can have different
    /// debts in different currencies). Fallback to MXN.
    private var settlementCurrency: String {
        topBalances.first { balance in
            balance.netCents < 0 && isCurrentUserMember(balance.memberId)
        }?.currency ?? "MXN"
    }

    /// Top 3 non-zero balances sorted by `|netCents|` descending. The
    /// user sees the most lopsided positions first ("X debe $500, Y
    /// recibe $300"). Even / zero rows are filtered out — they're
    /// noise, the user doesn't need to know they're square.
    @ViewBuilder
    private var balancesCard: some View {
        VStack(spacing: 1) {
            ForEach(topBalances) { balance in
                balanceRow(balance)
            }
        }
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
        )
    }

    @ViewBuilder
    private func balanceRow(_ balance: MemberBalance) -> some View {
        let isCurrentUser = isCurrentUserMember(balance.memberId)
        let displayName = memberDisplayName(balance.memberId)
        let prefix = isCurrentUser ? "Tú" : displayName
        let amountText = formattedAmount(abs(balance.netCents), currency: balance.currency)
        let owesGroup = balance.netCents < 0
        let labelText: String = owesGroup
            ? "\(prefix) \(isCurrentUser ? "debes" : "debe") \(amountText)"
            : "\(prefix) \(isCurrentUser ? "recibes" : "recibe") \(amountText)"

        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: owesGroup ? "arrow.up.right.circle" : "arrow.down.left.circle")
                .ruulTextStyle(RuulTypography.labelSemibold)
                .foregroundStyle(owesGroup ? Color.ruulTextSecondary : Color.ruulAccent)
                .frame(width: 22)
            Text(labelText)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    // MARK: - Data + helpers

    private func loadBalances() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            let raw = try await app.balanceRepo.balancesForResource(context.resource.id)
            // Filter out zero rows, sort by absolute net descending,
            // take top 3.
            let nonZero = raw.filter { $0.netCents != 0 }
            let sorted = nonZero.sorted { abs($0.netCents) > abs($1.netCents) }
            await MainActor.run { topBalances = Array(sorted.prefix(3)) }
        } catch {
            // Balance projection is decorative — failing silently keeps
            // the rest of the section usable. The Movimientos button
            // still works.
            await MainActor.run { topBalances = [] }
        }
    }

    /// True when this `member_id` (from group_members.id) corresponds
    /// to the currently-authed user. memberDirectory keys by user_id,
    /// so we walk the values looking for member.id == balance.memberId.
    private func isCurrentUserMember(_ memberId: UUID) -> Bool {
        guard let currentUserId = context.currentUserId else { return false }
        for (_, m) in context.memberDirectory {
            if m.member.id == memberId && m.member.userId == currentUserId {
                return true
            }
        }
        return false
    }

    private func memberDisplayName(_ memberId: UUID) -> String {
        for (_, m) in context.memberDirectory {
            if m.member.id == memberId {
                return m.displayName
            }
        }
        return "Alguien"
    }

    private func formattedAmount(_ cents: Int64, currency: String) -> String {
        let pesos = Double(cents) / 100.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = pesos.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return formatter.string(from: NSNumber(value: pesos)) ?? "\(currency) \(pesos)"
    }

    private var subtitle: String {
        var parts: [String] = []
        if context.enabledCapabilities.contains("expenses")      { parts.append("Gastos") }
        if context.enabledCapabilities.contains("contributions") { parts.append("Aportaciones") }
        if context.enabledCapabilities.contains("payouts")       { parts.append("Payouts") }
        if parts.isEmpty { parts.append("Pagos y balances") }
        return parts.joined(separator: " · ")
    }

    private func iconBadge(systemName: String) -> some View {
        ZStack {
            Circle().fill(Color.ruulAccent.opacity(0.15)).frame(width: 36, height: 36)
            Image(systemName: systemName)
                .ruulTextStyle(RuulTypography.subheadSemibold)
                .foregroundStyle(Color.ruulAccent)
        }
    }
}
