import SwiftUI
import RuulUI

/// FASE 4 Wave 2 (2026-05-25): the warmth payoff after a settle.
/// When the viewer resolves a dyadic position, this card surfaces the
/// social consequence ("Ya quedaste a mano con Linda") instead of
/// leaving the user staring at a silently refreshed list.
///
/// Two-state shape:
///   - `.closed`  → "Ya quedaste a mano con \(name)"
///   - `.partial` → "Le pagaste \(amount) a \(name)" / "\(name) te pagó \(amount)"
///
/// The caller owns the timer + `@State` slot. Card is built at the
/// feature layer with `.ruulCardSurface(.solid)` + Ruul tokens — no
/// new primitives.
struct DyadicClosureCard: View {
    enum Outcome {
        case closed
        case partial
    }

    enum ViewerSide {
        case payer
        case creditor
    }

    let counterpartName: String
    let amount: Decimal
    let currency: String
    let viewerSide: ViewerSide
    let outcome: Outcome
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: outcome == .closed
                  ? "checkmark.circle.fill"
                  : "checkmark.circle")
                .font(.title3)
                .foregroundStyle(Color.ruulPositive)
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(primary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
        }
        .padding(RuulSpacing.md)
        .ruulCardSurface(.solid)
    }

    private var formattedAmount: String {
        amount.formatted(.currency(code: currency))
    }

    private var primary: String {
        switch outcome {
        case .closed:
            return "Ya quedaste a mano con \(counterpartName)"
        case .partial:
            switch viewerSide {
            case .payer:
                return "Le pagaste \(formattedAmount) a \(counterpartName)"
            case .creditor:
                return "\(counterpartName) te pagó \(formattedAmount)"
            }
        }
    }

    private var secondary: String {
        switch outcome {
        case .closed:
            return "Ya no tienen cuentas pendientes en este grupo."
        case .partial:
            return "Aún queda un saldo entre ustedes."
        }
    }
}

/// Lightweight wrapper a parent surface can hold in `@State` to drive
/// the closure card lifecycle (insert / auto-dismiss / manual dismiss).
struct DyadicClosureState: Identifiable {
    let id = UUID()
    let counterpartName: String
    let amount: Decimal
    let currency: String
    let viewerSide: DyadicClosureCard.ViewerSide
    let outcome: DyadicClosureCard.Outcome
}
