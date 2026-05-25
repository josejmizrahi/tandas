import SwiftUI
import RuulUI
import RuulCore

/// The group's canonical "Dinero del grupo" card on `GroupSpaceView`.
///
/// Rewritten 2026-05-24 (Money UX — Apple minimal pass): the previous
/// shape stacked a section header, a `.title` balance, a footer
/// caption, a divider, and two CTAs vertically inside the same card
/// — it read busy. This version follows the Apple Wallet / Finance
/// card pattern instead:
///
///   • a micro label at the top sets context without competing with
///     the amount,
///   • a HUGE balance using the system rounded face + monospaced
///     digits is the only thing the eye lands on first,
///   • a single caption ("Última actividad …" / "El grupo debe …")
///     adds tone without chrome,
///   • obligation / detail navigation is a single tappable strip
///     instead of a button — preserves discoverability without
///     adding visual weight,
///   • the lone CTA at the bottom is the unified "Registrar
///     movimiento" entry (Money UX Consolidation 2026-05-24).
///
/// Composes at the feature layer using existing RuulUI tokens — no
/// new primitives, no hardcoded colors. Big amount uses `Color.primary`
/// or `Color.ruulNegative` (over-spent) to stay token-aligned.
@MainActor
struct SharedMoneyCard: View {
    let summary: SharedPoolSummary
    /// Viewer's net position. When non-nil and not settled, an inline
    /// row replaces the generic "Ver detalle" link so the obligation
    /// is the first thing the viewer sees after the amount.
    let viewerObligation: MemberGroupBalance?
    /// Money UX Consolidation 2026-05-24: single "Registrar movimiento"
    /// entry that opens `RegisterMovementSheet`. Replaces the prior
    /// dual Aportar / Registrar gasto CTAs.
    let onRegisterMovement: () -> Void
    /// Opens the canonical "Dinero del grupo" detail surface. Used by
    /// both the obligation strip (when present) and the always-shown
    /// "Ver detalle →" link.
    let onOpenDetail: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            label
            amount
                .padding(.top, 6)
            footer
                .padding(.top, RuulSpacing.xxs)

            secondaryRow
                .padding(.top, RuulSpacing.md)

            RuulButton(
                "Registrar movimiento",
                style: .secondary,
                size: .medium,
                fillsWidth: true,
                action: onRegisterMovement
            )
            .padding(.top, RuulSpacing.md)
        }
        .padding(RuulSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ruulCardSurface(.solid)
    }

    // MARK: - Label

    private var label: some View {
        Text("Dinero del grupo")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    // MARK: - Hero amount

    /// Apple-style large numeral. Composed at feature level (not via
    /// `RuulMoneyView`) because `.title` from RuulMoneyView is too
    /// small for the hero role — the card's whole job is to make the
    /// balance the first thing the eye lands on. Currency code lives
    /// to the side as a subtle suffix so the number breathes.
    private var amount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(formattedAmount)
                .font(.system(size: 40, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(amountColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(summary.currency)
                .font(.body)
                .foregroundStyle(Color.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleAmount)
    }

    // MARK: - Footer

    private var footer: some View {
        Text(footerText)
            .font(.caption)
            .foregroundStyle(Color.secondary)
    }

    // MARK: - Secondary row (obligation strip OR detail link)

    @ViewBuilder
    private var secondaryRow: some View {
        if let obligation = viewerObligation, !obligation.isSettled {
            obligationStrip(obligation)
        } else if onOpenDetail != nil {
            seeDetailLink
        }
    }

    private func obligationStrip(_ obligation: MemberGroupBalance) -> some View {
        Button {
            onOpenDetail?()
        } label: {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: obligation.isOwed
                      ? "arrow.down.left"
                      : "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(obligation.isOwed ? Color.ruulPositive : Color.ruulNegative)
                Text(obligation.isOwed ? "Te deben" : "Debes")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(formatted(obligation.netCents))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(obligation.isOwed ? Color.ruulPositive : Color.ruulNegative)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.vertical, RuulSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpenDetail == nil)
    }

    private var seeDetailLink: some View {
        Button {
            onOpenDetail?()
        } label: {
            HStack(spacing: RuulSpacing.xs) {
                Text("Ver detalle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.vertical, RuulSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived

    private var balanceDecimal: Decimal {
        Decimal(summary.balanceCents) / 100
    }

    /// Currency-formatted amount WITHOUT the code (we render `MXN` as
    /// a separate caption to the right so the number stands alone).
    /// Locale is `es_MX` by default; for non-MXN groups the formatter
    /// still produces a sensible "$4,300" — the visible code clarifies.
    private var formattedAmount: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = summary.currency
        f.currencySymbol = "$"
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "es_MX")
        return f.string(from: balanceDecimal as NSDecimalNumber) ?? "$\(summary.balanceCents / 100)"
    }

    private var amountColor: Color {
        summary.isOverSpent ? Color.ruulNegative : Color.primary
    }

    private var footerText: String {
        if summary.isOverSpent {
            return "El grupo está gastando más de lo aportado"
        }
        guard summary.hasActivity, let last = summary.lastActivityAt else {
            return "Aún sin movimientos"
        }
        return "Última actividad \(last.ruulRelative)"
    }

    private var accessibleAmount: String {
        "\(formattedAmount) \(summary.currency)"
    }

    private func formatted(_ cents: Int64) -> String {
        let amount = Decimal(abs(cents)) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = summary.currency
        f.currencySymbol = "$"
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "es_MX")
        return f.string(from: amount as NSDecimalNumber) ?? "$\(abs(cents) / 100)"
    }
}

#if DEBUG
#Preview("SharedMoneyCard — Apple minimal") {
    let base = UUID()
    return ScrollView {
        VStack(spacing: RuulSpacing.lg) {
            SharedMoneyCard(
                summary: SharedPoolSummary(
                    groupId: base, currency: "MXN", sharedPoolId: UUID(),
                    inCents: 0, outCents: 0, balanceCents: 0,
                    entryCount: 0, lastActivityAt: nil
                ),
                viewerObligation: nil,
                onRegisterMovement: {},
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
                onRegisterMovement: {},
                onOpenDetail: {}
            )
            SharedMoneyCard(
                summary: SharedPoolSummary(
                    groupId: base, currency: "MXN", sharedPoolId: UUID(),
                    inCents: 100_000, outCents: 250_000, balanceCents: -150_000,
                    entryCount: 5, lastActivityAt: Date().addingTimeInterval(-86_400)
                ),
                viewerObligation: nil,
                onRegisterMovement: {},
                onOpenDetail: {}
            )
        }
        .padding(RuulSpacing.lg)
    }
    .background(Color.ruulBackgroundRecessed)
}
#endif
