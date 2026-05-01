import SwiftUI

/// Generic data shape for a fine card.
public struct FineCardData: Identifiable, Sendable, Hashable {
    public enum Status: Sendable, Hashable { case pending, paid, appealed, waived }

    public let id: String
    public let reason: String
    public let amount: Int
    public let currencyCode: String
    public let dateText: String
    public let status: Status

    public init(id: String, reason: String, amount: Int, currencyCode: String = "MXN", dateText: String, status: Status) {
        self.id = id
        self.reason = reason
        self.amount = amount
        self.currencyCode = currencyCode
        self.dateText = dateText
        self.status = status
    }
}

/// Standard fine card with status, amount, and pay/appeal CTAs.
public struct FineCardStub: View {
    private let data: FineCardData
    private let onPay: (() -> Void)?
    private let onAppeal: (() -> Void)?

    public init(_ data: FineCardData, onPay: (() -> Void)? = nil, onAppeal: (() -> Void)? = nil) {
        self.data = data
        self.onPay = onPay
        self.onAppeal = onAppeal
    }

    public var body: some View {
        RuulCard(.glass) {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(data.reason)
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text(data.dateText)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Spacer()
                    statusChip
                }
                Text(formattedAmount)
                    .ruulTextStyle(RuulTypography.displayMedium)
                    .foregroundStyle(Color.ruulTextPrimary)
                if data.status == .pending {
                    HStack(spacing: RuulSpacing.s2) {
                        if onPay != nil {
                            RuulButton("Pagar", style: .primary, size: .medium, fillsWidth: true) { onPay?() }
                        }
                        if onAppeal != nil {
                            RuulButton("Apelar", style: .secondary, size: .medium) { onAppeal?() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch data.status {
        case .pending:
            chip("Pendiente", tint: .ruulSemanticWarning)
        case .paid:
            chip("Pagada", tint: .ruulSemanticSuccess)
        case .appealed:
            chip("Apelada", tint: .ruulSemanticInfo)
        case .waived:
            chip("Condonada", tint: .ruulTextTertiary)
        }
    }

    private func chip(_ label: String, tint: Color) -> some View {
        Text(label)
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, RuulSpacing.s2)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
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
#Preview("FineCardStub") {
    ScrollView {
        VStack(spacing: RuulSpacing.s3) {
            FineCardStub(
                .init(id: "1", reason: "Llegaste 30 min tarde a la cena", amount: 50, dateText: "Mié 7 may", status: .pending),
                onPay: { },
                onAppeal: { }
            )
            FineCardStub(.init(id: "2", reason: "No avisaste que no venías", amount: 100, dateText: "Vie 2 may", status: .paid))
            FineCardStub(.init(id: "3", reason: "RSVP cambiado tarde", amount: 75, dateText: "Lun 28 abr", status: .appealed))
            FineCardStub(.init(id: "4", reason: "Multa condonada (amnesty)", amount: 50, dateText: "Lun 21 abr", status: .waived))
        }
        .padding(RuulSpacing.s5)
    }
    .background(Color.ruulBackgroundCanvas)
}
#endif
