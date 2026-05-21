import SwiftUI
import RuulUI
import RuulCore

/// SharedMoney Phase 3 (brick 2): the group's canonical shared pool
/// surfaced high in `GroupSpaceView` — balance + two quick-action CTAs.
///
/// Composed entirely from existing RuulUI primitives
/// (`RuulMoneyView`, `RuulButton`) inside the canonical section card
/// chrome (`.ruulCardSurface(.solid)` + hairline stroke), per
/// `feedback_dont_touch_ruului_base.md`. No new RuulUI primitive.
///
/// Always rendered (even at $0 balance) so the layout doesn't shift as
/// pendings/activity come and go. Three visual states keyed off the
/// `SharedPoolSummary` helpers:
///   - empty   (`!hasActivity`)  → "$0", footer "Aún sin movimientos"
///   - positive (`balance >= 0`) → neutral money, footer last activity
///   - negative (`isOverSpent`)  → red money, footer over-spent notice
///
/// `RuulMoneyView` exposes only neutral/positive/negative tones (no
/// `.warning`), so an over-spent pool uses `.negative` — the closest
/// existing semantic — rather than adding a primitive variant.
@MainActor
struct SharedMoneyCard: View {
    let summary: SharedPoolSummary
    let onContribute: () -> Void
    let onRecordExpense: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Dinero compartido")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)

            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                RuulMoneyView(
                    amount: balanceAmount,
                    currency: summary.currency,
                    size: .large,
                    color: summary.isOverSpent ? .negative : .neutral
                )
                Text("Saldo disponible")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            HStack(spacing: RuulSpacing.sm) {
                RuulButton("Aportar", style: .secondary, size: .medium, action: onContribute)
                RuulButton("Registrar gasto", style: .secondary, size: .medium, action: onRecordExpense)
            }

            Text(footerText)
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ruulCardSurface(.solid)
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var balanceAmount: Decimal {
        Decimal(summary.balanceCents) / 100
    }

    private var footerText: String {
        if summary.isOverSpent {
            return "El fondo está en saldo negativo"
        }
        guard summary.hasActivity, let last = summary.lastActivityAt else {
            return "Aún sin movimientos"
        }
        return "Última actividad: \(last.ruulRelative)"
    }
}

#if DEBUG
#Preview("SharedMoneyCard") {
    let base = UUID()
    return VStack(spacing: RuulSpacing.lg) {
        SharedMoneyCard(
            summary: SharedPoolSummary(
                groupId: base, currency: "MXN", sharedPoolId: UUID(),
                inCents: 0, outCents: 0, balanceCents: 0,
                entryCount: 0, lastActivityAt: nil
            ),
            onContribute: {}, onRecordExpense: {}
        )
        SharedMoneyCard(
            summary: SharedPoolSummary(
                groupId: base, currency: "MXN", sharedPoolId: UUID(),
                inCents: 500_000, outCents: 80_000, balanceCents: 420_000,
                entryCount: 7, lastActivityAt: Date().addingTimeInterval(-3 * 86_400)
            ),
            onContribute: {}, onRecordExpense: {}
        )
        SharedMoneyCard(
            summary: SharedPoolSummary(
                groupId: base, currency: "MXN", sharedPoolId: UUID(),
                inCents: 100_000, outCents: 250_000, balanceCents: -150_000,
                entryCount: 5, lastActivityAt: Date().addingTimeInterval(-86_400)
            ),
            onContribute: {}, onRecordExpense: {}
        )
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackgroundRecessed)
}
#endif
