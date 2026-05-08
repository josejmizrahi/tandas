import SwiftUI
import RuulUI

/// Single fine row — Apple Sports flat: monochrome surface, status via 8pt
/// dot + uppercase tracked label, monospaced amount on the right. Tappable
/// to open FineDetailView. Used in MyFinesView, ReviewProposedFinesView,
/// and inside FineDetailView itself for cross-references.
struct FineCard: View {
    let fine: Fine
    let ruleName: String?           // resolved by parent (denormalized)
    let eventTitle: String?         // resolved by parent
    /// Optional cross-group label. Set by MyFinesView when caller has 2+
    /// groups; rendered as a small uppercase tracked chip above the
    /// status row so the user knows which group this fine belongs to.
    var groupName: String? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                if let groupName {
                    Text(groupName)
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextAccent)
                        .textCase(.uppercase)
                }
                statusRow
                Divider().background(Color.ruulSeparator)
                contentRow
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity)
            .background(Color.ruulSurface, in: shape)
            .overlay(shape.stroke(Color.ruulSeparator, lineWidth: 0.5))
        }
        .buttonStyle(.ruulPress)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ruleName ?? fine.reason), \(fine.amountFormatted), \(fine.status.displayLabel)")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
    }

    private var statusRow: some View {
        HStack(spacing: RuulSpacing.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(fine.status.displayLabel)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            if let createdAgo {
                Text(createdAgo)
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
    }

    private var contentRow: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ruleName ?? fine.reason)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let eventTitle {
                    Text(eventTitle)
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            RuulMoneyView(
                amount: fine.amount,
                currency: "MXN",
                size: .medium,
                color: amountSemanticColor
            )
        }
    }

    private var amountSemanticColor: RuulMoneyView.SemanticColor {
        switch fine.status {
        case .officialized:        return .negative
        case .paid:                return .positive
        case .voided:              return .neutral
        case .proposed, .inAppeal: return .neutral
        }
    }

    private var statusColor: Color {
        switch fine.status {
        case .proposed:     return .ruulWarning
        case .officialized: return .ruulNegative
        case .paid:         return .ruulPositive
        case .voided:       return .ruulTextTertiary
        case .inAppeal:     return .ruulInfo
        }
    }

    private var createdAgo: String? {
        let interval = Date.now.timeIntervalSince(fine.createdAt)
        guard interval >= 0 else { return nil }
        let days = Int(interval / 86_400)
        let hours = Int(interval / 3600)
        if days >= 1 { return "HACE \(days) D" }
        if hours >= 1 { return "HACE \(hours) H" }
        return "AHORA"
    }
}
