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
    /// Viewer's net position in this group. When non-nil and not
    /// settled, an inline "Te deben / Debes" strip renders below the
    /// footer — formerly its own `GroupObligationsCard`, merged here
    /// (P8) so the group home has one consolidated "Dinero" card.
    let viewerObligation: MemberGroupBalance?
    let onContribute: () -> Void
    let onRecordExpense: () -> Void
    /// Opens the canonical "Dinero del grupo" detail surface (saldos
    /// per-miembro + "Otros fondos" footer). Used by BOTH the
    /// obligation strip (when the viewer has a non-zero net) and the
    /// always-visible "Ver detalle" footer link (when they don't) —
    /// every user gets one consistent entry into the money hub.
    let onOpenDetail: (() -> Void)?

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

            if let obligation = viewerObligation, !obligation.isSettled {
                obligationStrip(obligation)
            } else if onOpenDetail != nil {
                seeDetailLink
            }
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ruulCardSurface(.solid)
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func obligationStrip(_ obligation: MemberGroupBalance) -> some View {
        Divider()
        Button {
            onOpenDetail?()
        } label: {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: obligation.isOwed
                      ? "arrow.down.left.circle.fill"
                      : "arrow.up.right.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(obligation.isOwed ? Color.ruulPositive : Color.ruulNegative)
                Text(obligation.isOwed ? "Te deben" : "Debes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                RuulMoneyView(
                    amount: Decimal(abs(obligation.netCents)) / 100,
                    currency: obligation.currency,
                    size: .small,
                    color: obligation.isOwed ? .positive : .negative
                )
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpenDetail == nil)
    }

    /// Footer link rendered when the viewer has no outstanding net
    /// (so the obligation strip is hidden). Keeps a consistent entry
    /// point into the "Dinero del grupo" hub regardless of obligation
    /// state — without it, settled users had no path to the detail
    /// surface other than the legacy "Otros fondos" tile.
    @ViewBuilder
    private var seeDetailLink: some View {
        Divider()
        Button {
            onOpenDetail?()
        } label: {
            HStack(spacing: RuulSpacing.xs) {
                Text("Ver dinero del grupo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            viewerObligation: nil,
            onContribute: {}, onRecordExpense: {},
            onOpenDetail: {}
        )
        SharedMoneyCard(
            summary: SharedPoolSummary(
                groupId: base, currency: "MXN", sharedPoolId: UUID(),
                inCents: 500_000, outCents: 80_000, balanceCents: 420_000,
                entryCount: 7, lastActivityAt: Date().addingTimeInterval(-3 * 86_400)
            ),
            viewerObligation: MemberGroupBalance(
                groupId: base, memberId: UUID(), currency: "MXN",
                sentCents: 30_000, receivedCents: 0, netCents: 30_000
            ),
            onContribute: {}, onRecordExpense: {},
            onOpenDetail: {}
        )
        SharedMoneyCard(
            summary: SharedPoolSummary(
                groupId: base, currency: "MXN", sharedPoolId: UUID(),
                inCents: 100_000, outCents: 250_000, balanceCents: -150_000,
                entryCount: 5, lastActivityAt: Date().addingTimeInterval(-86_400)
            ),
            viewerObligation: nil,
            onContribute: {}, onRecordExpense: {},
            onOpenDetail: {}
        )
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackgroundRecessed)
}
#endif
