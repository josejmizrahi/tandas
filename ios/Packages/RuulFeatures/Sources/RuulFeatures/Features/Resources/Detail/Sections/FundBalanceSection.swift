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
/// Refresh contract: the parent calls `context.onResourceMutated()`
/// after every successful contribute / record-expense / lock action,
/// which re-fetches the resource row server-side. The new row carries
/// a fresh `updatedAt` (touched by every fund mutation RPC), so
/// `.task(id: fund.updatedAt)` re-runs and the projection re-reads.
/// No external refresh-token plumbing needed — the row's timestamp IS
/// the refresh signal. Per Plans/Active/UniversalRuleTemplates.md §14
/// catalog migration pattern.
public struct FundBalanceSection: View {
    @Environment(AppState.self) private var app
    public let fund: ResourceRow

    @State private var snapshots: [Fund] = []
    @State private var loadError: String?

    public init(fund: ResourceRow) {
        self.fund = fund
    }

    /// Catalog registration — fund-only via isVisibleFor. No capability
    /// gate (fund is the resource type, the balance card is intrinsic).
    public static let definition = CapabilitySection(
        id: "fund.balance",
        priority: 167,
        isEnabledFor: { _ in true },
        isVisibleFor: { ctx in ctx.resource.resourceType == .fund },
        render: { ctx in AnyView(FundBalanceSection(fund: ctx.resource)) }
    )

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
        .task(id: fund.updatedAt) { await reload() }
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
            snapshots = try await app.fundRepo.get(fund.id)
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

/// Fund-specific INFORMACIÓN rows. Extracted from
/// `UniversalResourceDetailView.typeSpecificRows` per ontology
/// constitution Rule 6. Registered with `ResourceInfoRegistry` at boot.
@MainActor
public enum FundInfoProvider {
    public static func register() {
        ResourceInfoRegistry.shared.register(type: .fund, provider: rows)
    }

    public static func rows(for ctx: ResourceDetailContext) -> [ResourceInfoRow] {
        var out: [ResourceInfoRow] = []
        if let currency = ctx.resource.metadata["currency"]?.stringValue {
            out.append(ResourceInfoRow(label: "Moneda", value: currency))
        }
        if let goalCents = targetAmountCents(ctx) {
            out.append(ResourceInfoRow(
                label: "Meta",
                value: formatCurrencyCents(goalCents, currency: ctx.resource.metadata["currency"]?.stringValue ?? "MXN")
            ))
        }
        // Lock state — fund_lock writes locked_at/locked_by/locked_reason
        // into metadata + emits fundLocked. Surface it so admins know
        // whether the fund is locked without querying the DB.
        if let lockedAt = ctx.resource.metadata["locked_at"]?.stringValue, !lockedAt.isEmpty {
            let reason = ctx.resource.metadata["locked_reason"]?.stringValue
            let suffix = (reason?.isEmpty == false) ? " (\(reason!))" : ""
            out.append(ResourceInfoRow(label: "Estado", value: "Bloqueado\(suffix)"))
        }
        return out
    }

    /// `create_fund` (mig 00139) stores target as `target_amount_cents`.
    /// Falls back to legacy `goal_amount` (pesos) for any pre-mig rows.
    private static func targetAmountCents(_ ctx: ResourceDetailContext) -> Int64? {
        if case .int(let i)? = ctx.resource.metadata["target_amount_cents"] {
            return Int64(i)
        }
        if case .double(let d)? = ctx.resource.metadata["goal_amount"] {
            return Int64(d * 100)
        }
        if case .int(let i)? = ctx.resource.metadata["goal_amount"] {
            return Int64(i) * 100
        }
        return nil
    }

    private static func formatCurrencyCents(_ cents: Int64, currency: String) -> String {
        let pesos = Double(cents) / 100.0
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.maximumFractionDigits = pesos.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return nf.string(from: NSNumber(value: pesos)) ?? "\(pesos)"
    }
}
