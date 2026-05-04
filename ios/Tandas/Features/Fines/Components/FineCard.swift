import SwiftUI

/// Single fine row — Apple Sports flat: monochrome surface, status via 8pt
/// dot + uppercase tracked label, monospaced amount on the right. Tappable
/// to open FineDetailView. Used in MyFinesView, ReviewProposedFinesView,
/// and inside FineDetailView itself for cross-references.
struct FineCard: View {
    let fine: Fine
    let ruleName: String?           // resolved by parent (denormalized)
    let eventTitle: String?         // resolved by parent
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                statusRow
                Divider().background(Color.ruulBorderSubtle)
                contentRow
            }
            .padding(RuulSpacing.s4)
            .frame(maxWidth: .infinity)
            .background(Color.ruulBackgroundElevated, in: shape)
            .overlay(shape.stroke(Color.ruulBorderSubtle, lineWidth: 0.5))
        }
        .buttonStyle(.ruulPress)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ruleName ?? fine.reason), \(fine.amountFormatted), \(fine.status.displayLabel)")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
    }

    private var statusRow: some View {
        HStack(spacing: RuulSpacing.s2) {
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
        HStack(alignment: .top, spacing: RuulSpacing.s3) {
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
            Text(fine.amountFormatted)
                .ruulTextStyle(RuulTypography.statMedium)
                .foregroundStyle(Color.ruulTextPrimary)
        }
    }

    private var statusColor: Color {
        switch fine.status {
        case .proposed:     return .ruulSemanticWarning
        case .officialized: return .ruulSemanticError
        case .paid:         return .ruulSemanticSuccess
        case .voided:       return .ruulTextTertiary
        case .inAppeal:     return .ruulSemanticInfo
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
