import SwiftUI

/// Generic data shape for a rule card.
public struct RuleCardData: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let description: String?
    public let amount: Int            // currency-agnostic, in cents or units (caller's choice)
    public let currencyCode: String   // ISO 4217 — for display formatting
    public let isActive: Bool

    public init(id: String, name: String, description: String? = nil, amount: Int, currencyCode: String = "MXN", isActive: Bool = true) {
        self.id = id
        self.name = name
        self.description = description
        self.amount = amount
        self.currencyCode = currencyCode
        self.isActive = isActive
    }
}

/// Editable rule card. Amount is editable inline. Toggle pauses/resumes.
public struct RuleCardStub: View {
    private let data: RuleCardData
    private let onAmountChange: ((Int) -> Void)?
    private let onToggleActive: ((Bool) -> Void)?
    private let onInfo: (() -> Void)?

    public init(
        _ data: RuleCardData,
        onAmountChange: ((Int) -> Void)? = nil,
        onToggleActive: ((Bool) -> Void)? = nil,
        onInfo: (() -> Void)? = nil
    ) {
        self.data = data
        self.onAmountChange = onAmountChange
        self.onToggleActive = onToggleActive
        self.onInfo = onInfo
    }

    public var body: some View {
        RuulCard(.glass) {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                HStack {
                    Text(data.name)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if onInfo != nil {
                        Button { onInfo?() } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Color.ruulTextSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { data.isActive },
                        set: { onToggleActive?($0) }
                    ))
                    .labelsHidden()
                    .tint(Color.ruulAccentPrimary)
                }
                if let description = data.description {
                    Text(description)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                HStack {
                    Text("Multa")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Spacer()
                    Text(formattedAmount)
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextAccent)
                }
            }
        }
        .opacity(data.isActive ? 1.0 : 0.55)
        .animation(.ruulSnappy, value: data.isActive)
    }

    private var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = data.currencyCode
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: data.amount)) ?? "\(data.amount)"
    }
}

#if DEBUG
#Preview("RuleCardStub") {
    ScrollView {
        VStack(spacing: RuulSpacing.s3) {
            RuleCardStub(.init(id: "1", name: "Llegar tarde", description: "Si llegas más de 15 min después.", amount: 50))
            RuleCardStub(.init(id: "2", name: "No avisar", description: "Si cancelas el mismo día.", amount: 100))
            RuleCardStub(.init(id: "3", name: "Pausada", amount: 25, isActive: false))
        }
        .padding(RuulSpacing.s5)
    }
    .background(Color.ruulBackgroundCanvas)
}
#endif
