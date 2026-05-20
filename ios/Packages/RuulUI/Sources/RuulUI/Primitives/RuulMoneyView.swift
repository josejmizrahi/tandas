import SwiftUI

/// Display de monto con tabular digits + currency formatter + accessibility.
/// Per DS doc §3.8.
public struct RuulMoneyView: View {
    public enum Size: Sendable, Hashable {
        case small, medium, large
        var font: Font {
            switch self {
            case .small:  return .body.weight(.semibold).monospacedDigit()
            case .medium: return .title3.weight(.semibold).monospacedDigit()
            case .large:  return .title.weight(.semibold).monospacedDigit()
            }
        }
    }

    public enum SemanticColor: Sendable, Hashable {
        case neutral, positive, negative
        var color: Color {
            switch self {
            case .neutral:  return .primary
            case .positive: return .green
            case .negative: return .red
            }
        }
    }

    private let amount: Decimal
    private let currency: String
    private let size: Size
    private let showSign: Bool
    private let color: SemanticColor

    public init(
        amount: Decimal,
        currency: String = "MXN",
        size: Size = .medium,
        showSign: Bool = false,
        color: SemanticColor = .neutral
    ) {
        self.amount = amount
        self.currency = currency
        self.size = size
        self.showSign = showSign
        self.color = color
    }

    public var body: some View {
        Text(formatted)
            .font(size.font)
            .foregroundStyle(color.color)
            .accessibilityLabel(accessibleLabel)
    }

    private var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let prefix = (showSign && amount > 0) ? "+" : ""
        return prefix + (formatter.string(from: amount as NSDecimalNumber) ?? "")
    }

    private var accessibleLabel: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "es_MX")
        let words = formatter.string(from: amount as NSDecimalNumber) ?? ""
        return "\(words) \(currency)"
    }
}

#if DEBUG
#Preview("RuulMoneyView") {
    VStack(alignment: .leading, spacing: RuulSpacing.md) {
        RuulMoneyView(amount: 250, size: .large, color: .negative)
        RuulMoneyView(amount: 1500, size: .medium)
        RuulMoneyView(amount: 50, size: .small, showSign: true, color: .positive)
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
