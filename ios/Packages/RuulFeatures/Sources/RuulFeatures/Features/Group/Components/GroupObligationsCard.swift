import SwiftUI
import RuulCore
import RuulUI

/// SharedMoney P3 (mig 00136): the viewer's net position in the group,
/// surfaced as a compact card on `GroupSpaceView` between the shared
/// pool and pendings sections.
///
/// Visibility: hides entirely when the viewer is settled (`netCents ==
/// 0`) — Apple convention: zero state is no noise. Only renders when
/// money is moving between this user and the group's pool flows.
///
/// Tap → opens `GroupBalancesView` (all members + their nets) so the
/// user can see who else is up / down and act on it via the
/// per-resource settle CTA in the Money Block.
///
/// Composed entirely from existing RuulUI primitives. No new RuulUI
/// pieces per `feedback_dont_touch_ruului_base.md`.
@MainActor
struct GroupObligationsCard: View {
    let balance: MemberGroupBalance
    let onOpenDetail: () -> Void

    var body: some View {
        Button(action: onOpenDetail) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                HStack(spacing: RuulSpacing.xs) {
                    Image(systemName: balance.isOwed ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(toneColor)
                    Text(headline)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
                RuulMoneyView(
                    amount: absoluteAmount,
                    currency: balance.currency,
                    size: .large,
                    color: balance.isOwed ? .positive : .negative
                )
                Text(caption)
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
        .buttonStyle(.plain)
    }

    private var absoluteAmount: Decimal {
        Decimal(abs(balance.netCents)) / 100
    }

    private var toneColor: Color {
        balance.isOwed ? Color.ruulPositive : Color.ruulNegative
    }

    private var headline: String {
        if balance.isOwed { return "Te deben" }
        if balance.isInDebt { return "Debes" }
        return "Estás al día"
    }

    private var caption: String {
        if balance.isOwed {
            return "Suma neta a tu favor en este grupo."
        }
        if balance.isInDebt {
            return "Suma neta pendiente con el grupo."
        }
        return "Tus aportes y reembolsos están parejos."
    }
}
