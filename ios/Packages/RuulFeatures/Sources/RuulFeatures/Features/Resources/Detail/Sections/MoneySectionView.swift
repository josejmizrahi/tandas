import SwiftUI
import RuulUI
import RuulCore

/// Money primitive renderer. Tap the card → caller opens the
/// `ResourceLedgerSheet` (delegated via context.onPresentLedger).
/// V1 doesn't inline-render a balance summary; the sheet shows
/// the full per-member breakdown. Future: render top-3 balances
/// inline so the user sees state without tapping in.
public struct MoneySectionView: View {
    public let context: ResourceDetailContext

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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .padding(RuulSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardBackground()
        }
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ruulAccent)
        }
    }
}
