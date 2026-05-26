import SwiftUI
import RuulUI
import RuulCore

/// "Deudas" — cluster #3 de la doctrina situacional (founder reframe
/// 2026-05-25). Reemplaza "Dinero reciente": el stream debe surfacear
/// tensión social actionable (pares dyadic pendientes), no historial.
/// El historial vive en GroupBalancesView.recentMovementsSection,
/// JustHappenedCluster ("Acabó de pasar") y MyMovementsView.
///
/// Cada row = una pair greedy del viewer ("Pagale a Linda · $200" /
/// "Cobrale a Carlos · $300"). Tap → SettlementSheet pre-filled.
/// El header conserva las CTAs de compose (Registrar gasto / Aportar
/// / Liquidar pendiente) — siguen siendo el punto de entrada canónico
/// para crear movimientos.
///
/// Cap a 5 rows. Auto-oculta si `debts.isEmpty` (decisión en
/// `GroupClusterStream`).
@MainActor
struct DebtsCluster: View {
    let debts: [PendingSettlementHint]
    let locale: String
    var onRegisterExpense: () -> Void
    var onContribute: () -> Void
    var onSettle: () -> Void
    /// Phase 4.4 (2026-05-26): open the "cobrar cuota al grupo" sheet
    /// (poker buy-in / tanda / cuota mensual). Nil → option hidden.
    var onPoolCharge: (() -> Void)?
    var onSeeAll: (() -> Void)?
    var onTapDebt: ((PendingSettlementHint) -> Void)?
    /// FASE 4 Wave 4 Phase 3 Tier 2 (2026-05-25): pool→member capital
    /// outflow (dividendo, retorno, stipend). Nil → option hidden.
    var onPayout: (() -> Void)?

    private var visible: [PendingSettlementHint] {
        Array(debts.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: RuulSpacing.sm) {
                Text("Deudas")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                Spacer()
                if let onSeeAll {
                    Button("Ver todo", action: onSeeAll)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulAccent)
                }
                composeMenu
            }
            .padding(.horizontal, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { idx, hint in
                    debtRow(hint)
                    if idx < visible.count - 1 {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, RuulSpacing.md)
                    }
                }
            }
            .ruulCardSurface(.solid)
        }
    }

    @ViewBuilder
    private func debtRow(_ hint: PendingSettlementHint) -> some View {
        let verb = hint.viewerIsPayer ? "Pagale a" : "Cobrale a"
        let tint: Color = hint.viewerIsPayer ? .ruulNegative : .ruulPositive
        Button {
            onTapDebt?(hint)
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: hint.viewerIsPayer
                      ? "arrow.up.right.circle.fill"
                      : "arrow.down.left.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(verb) \(hint.counterpartName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text("Liquidación sugerida")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                Text(formattedAmount(hint))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTapDebt == nil)
    }

    private func formattedAmount(_ hint: PendingSettlementHint) -> String {
        let amount = Decimal(hint.amountCents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = hint.currency
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: locale)
        return f.string(from: amount as NSDecimalNumber)
            ?? "\(hint.currency) \(hint.amountCents / 100)"
    }

    private var composeMenu: some View {
        Menu {
            Button {
                onRegisterExpense()
            } label: {
                Label("Registrar gasto", systemImage: "arrow.up.right.circle")
            }
            Button {
                onContribute()
            } label: {
                Label("Aportar", systemImage: "plus.circle")
            }
            Button {
                onSettle()
            } label: {
                Label("Liquidar pendiente", systemImage: "checkmark.circle")
            }
            if let onPayout {
                Button {
                    onPayout()
                } label: {
                    Label("Pagar desde el pool", systemImage: "banknote")
                }
            }
            if let onPoolCharge {
                Button {
                    onPoolCharge()
                } label: {
                    Label("Cobrar cuota al grupo", systemImage: "person.2.badge.minus")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.ruulAccent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Registrar movimiento")
    }
}

/// Hint payload for the debts cluster. Parent (GroupSpaceView) computes
/// the greedy settlement pairs involving the viewer (founder clarified
/// 2026-05-25 — "solo las mías"). Third-party pairs live in
/// GroupSettlementPlanView with its opt-in toggle, not here.
struct PendingSettlementHint: Hashable {
    let toMemberId: UUID
    let counterpartName: String
    let amountCents: Int64
    let currency: String
    let viewerIsPayer: Bool
}
