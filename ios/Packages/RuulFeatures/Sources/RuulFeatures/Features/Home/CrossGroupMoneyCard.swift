import SwiftUI
import RuulCore
import RuulUI

/// SharedMoney P9: aggregated "Te deben / Debes" roll-up surfaced on
/// the Home tab. Reads `HomeCoordinator.crossGroupBalances` — one row
/// per (group, member, currency) from `member_balances_per_group`,
/// already filtered to the viewer (`LedgerRepository.myBalancesAcrossGroups`).
///
/// Visibility: hides entirely when every row is settled — Apple
/// convention: the steady state ("you owe no one, no one owes you")
/// produces zero chrome. Renders when at least one row has
/// `netCents != 0`.
///
/// Currency: positions are summed per-currency so a user with groups
/// in MXN + USD doesn't see a meaningless `$420 MXN+USD`. In the
/// common single-currency case, only one summary row is shown.
///
/// Tap a per-group row → caller deep-links to that group's space (see
/// `onOpenGroup`). The card itself is non-interactive; only the rows
/// are.
@MainActor
struct CrossGroupMoneyCard: View {
    let balances: [MemberGroupBalance]
    /// Resolves a `groupId` to its display name (for per-group rows).
    let groupName: (UUID) -> String
    /// Deep-link handler — caller routes to the group's space.
    let onOpenGroup: (UUID) -> Void

    /// Per-currency aggregate. Each entry shows the user's total
    /// "owed-to-me" and "I-owe" amounts for that currency, computed
    /// from the constituent balance rows.
    private struct CurrencyTotals: Identifiable {
        let currency: String
        let owedToMeCents: Int64
        let iOweCents: Int64
        var id: String { currency }
    }

    private var activeRows: [MemberGroupBalance] {
        balances.filter { !$0.isSettled }
    }

    private var totalsByCurrency: [CurrencyTotals] {
        let grouped = Dictionary(grouping: activeRows, by: \.currency)
        return grouped
            .map { currency, rows in
                let owed = rows.filter(\.isOwed).map(\.netCents).reduce(0, +)
                let iOwe = rows.filter(\.isInDebt).map { abs($0.netCents) }.reduce(0, +)
                return CurrencyTotals(
                    currency: currency,
                    owedToMeCents: owed,
                    iOweCents: iOwe
                )
            }
            .sorted { $0.currency < $1.currency }
    }

    var body: some View {
        if !activeRows.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                Text("Dinero")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)

                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    ForEach(totalsByCurrency) { totals in
                        totalsRow(totals)
                    }
                }

                DisclosureGroup("Ver por grupo") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedRows.enumerated()), id: \.element.id) { idx, row in
                            perGroupRow(row)
                            if idx < sortedRows.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(.top, RuulSpacing.xs)
                }
                .font(.subheadline.weight(.medium))
                .tint(Color.ruulAccent)
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ruulCardSurface(.solid)
        }
    }

    @ViewBuilder
    private func totalsRow(_ totals: CurrencyTotals) -> some View {
        if totals.owedToMeCents > 0 {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "arrow.down.left.circle.fill")
                    .foregroundStyle(Color.ruulPositive)
                Text("Te deben")
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
                RuulMoneyView(
                    amount: Decimal(totals.owedToMeCents) / 100,
                    currency: totals.currency,
                    size: .medium,
                    color: .positive
                )
            }
            .font(.subheadline.weight(.semibold))
        }
        if totals.iOweCents > 0 {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .foregroundStyle(Color.ruulNegative)
                Text("Debes")
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
                RuulMoneyView(
                    amount: Decimal(totals.iOweCents) / 100,
                    currency: totals.currency,
                    size: .medium,
                    color: .negative
                )
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    /// Sort: largest absolute net first (most relevant), preserving
    /// currency mixing. Drives the per-group disclosure rows.
    private var sortedRows: [MemberGroupBalance] {
        activeRows.sorted { abs($0.netCents) > abs($1.netCents) }
    }

    private func perGroupRow(_ row: MemberGroupBalance) -> some View {
        Button {
            onOpenGroup(row.groupId)
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: row.isOwed
                      ? "arrow.down.left.circle.fill"
                      : "arrow.up.right.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(row.isOwed ? Color.ruulPositive : Color.ruulNegative)
                Text(groupName(row.groupId))
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                RuulMoneyView(
                    amount: Decimal(abs(row.netCents)) / 100,
                    currency: row.currency,
                    size: .small,
                    color: row.isOwed ? .positive : .negative
                )
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.vertical, RuulSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
