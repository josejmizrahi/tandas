import SwiftUI
import RuulCore
import RuulUI

/// Fund-specific balance card. Renders inside `UniversalResourceDetailView`
/// when the resource is a fund. Reads from `fundRepo.get(fundId)` which
/// hits `public.fund_balance_view` (mig 00202) — a per-fund, per-currency
/// projection over `ledger_entries`.
///
/// Shows:
///   - Current balance (cents → pesos)
///   - Target progress bar (only when `target_amount_cents` is set)
///   - Contribution / expense counts
///   - Last activity date
///   - Lock indicator (when `locked_at` is set)
///
/// Multi-currency funds surface multiple snapshots (one per currency)
/// stacked vertically. V1 single-currency groups see one row.
///
/// Refresh contract: the parent passes `refreshToken` from a `@State`
/// counter that bumps after every successful contribute / record-expense
/// / lock action. `.task(id:)` re-runs whenever that token changes so
/// the card stays in sync without manual reload.
public struct FundBalanceSection: View {
    @Environment(AppState.self) private var app
    public let fundId: UUID
    public let refreshToken: Int

    @State private var snapshots: [Fund] = []
    @State private var loadError: String?

    public init(fundId: UUID, refreshToken: Int) {
        self.fundId = fundId
        self.refreshToken = refreshToken
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            sectionHeader("FONDO")
            if snapshots.isEmpty {
                emptyCard
            } else {
                ForEach(snapshots) { snapshot in
                    snapshotCard(snapshot)
                }
            }
        }
        .task(id: refreshToken) { await reload() }
    }

    // MARK: - Cards

    @ViewBuilder
    private func snapshotCard(_ snapshot: Fund) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            balanceRow(snapshot)
            if let target = snapshot.targetAmountCents, target > 0 {
                targetProgress(snapshot, target: target)
            }
            countsRow(snapshot)
            if let lastActivity = snapshot.lastActivityAt {
                Text("Última actividad: \(lastActivity.ruulShortDate)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            // Lock state is rendered higher up by `typeSpecificRows`
            // (the "Estado: Bloqueado" row in INFORMACIÓN) and the
            // admin-only lock toggle lives in MoneySectionView. The
            // balance card stays focused on the money projection.
        }
        .padding(RuulSpacing.md)
        .cardBackground()
    }

    @ViewBuilder
    private func balanceRow(_ snapshot: Fund) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(formatCents(snapshot.balanceCents, currency: snapshot.currency))
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Text(snapshot.currency)
                .ruulTextStyle(RuulTypography.captionBold)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }

    @ViewBuilder
    private func targetProgress(_ snapshot: Fund, target: Int64) -> some View {
        let progress = max(0, min(1, Double(snapshot.balanceCents) / Double(target)))
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            ProgressView(value: progress)
                .tint(snapshot.balanceCents >= target ? Color.ruulPositive : Color.ruulAccent)
            HStack {
                Text("Meta: \(formatCents(target, currency: snapshot.currency))")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .ruulTextStyle(RuulTypography.captionBold)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }

    @ViewBuilder
    private func countsRow(_ snapshot: Fund) -> some View {
        HStack(spacing: RuulSpacing.md) {
            countChip(systemName: "arrow.down.circle",
                      label: "\(snapshot.contributionCount)",
                      caption: pluralize(snapshot.contributionCount, "aportación", "aportaciones"))
            countChip(systemName: "arrow.up.circle",
                      label: "\(snapshot.expenseCount)",
                      caption: pluralize(snapshot.expenseCount, "gasto", "gastos"))
            Spacer()
        }
    }

    @ViewBuilder
    private func countChip(systemName: String, label: String, caption: String) -> some View {
        HStack(spacing: RuulSpacing.xs) {
            Image(systemName: systemName)
                .ruulTextStyle(RuulTypography.subheadSemibold)
                .foregroundStyle(Color.ruulTextSecondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(caption)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            if let loadError {
                Text(loadError)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
            } else {
                Text("Sin balance todavía")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Cuando alguien aporte o haya un gasto, aparecerá aquí.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
        .padding(RuulSpacing.md)
        .cardBackground()
    }

    // MARK: - Section header (mirrors MoneySectionView style)

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .ruulTextStyle(RuulTypography.captionBold)
            .foregroundStyle(Color.ruulTextSecondary)
            .padding(.horizontal, RuulSpacing.xs)
    }

    // MARK: - Data + formatting

    @MainActor
    private func reload() async {
        do {
            snapshots = try await app.fundRepo.get(fundId)
            loadError = nil
        } catch {
            snapshots = []
            loadError = error.localizedDescription
        }
    }

    private func formatCents(_ cents: Int64, currency: String) -> String {
        let pesos = Double(cents) / 100.0
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.maximumFractionDigits = pesos.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return nf.string(from: NSNumber(value: pesos)) ?? "\(currency) \(pesos)"
    }

    private func pluralize(_ count: Int64, _ singular: String, _ plural: String) -> String {
        count == 1 ? singular : plural
    }
}
