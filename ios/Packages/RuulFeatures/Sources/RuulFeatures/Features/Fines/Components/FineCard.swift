import SwiftUI
import RuulUI
import RuulCore

/// Single fine row — Apple Sports flat: monochrome surface, status via 8pt
/// dot + uppercase tracked label, monospaced amount on the right. Tappable
/// to open FineDetailView. Used in MyFinesView, ReviewProposedFinesView,
/// and inside FineDetailView itself for cross-references.
public struct FineCard: View {
    public let fine: Fine
    public let ruleName: String?           // resolved by parent (denormalized)
    public let eventTitle: String?         // resolved by parent
    /// Optional cross-group label. Set by MyFinesView when caller has 2+
    /// groups; rendered as a small uppercase tracked chip above the
    /// status row so the user knows which group this fine belongs to.
    public var groupName: String? = nil
    /// Compact mode para listas históricas (resolved section). Esconde
    /// el divider + status row + reduce padding — la fila queda como
    /// "nombre · monto · fecha" en una línea, similar a EventRow vs
    /// EventCard hero (DS v3 "two card densities only" §2).
    public var compact: Bool = false
    public let onTap: () -> Void

    public init(fine: Fine, ruleName: String?, eventTitle: String?, groupName: String? = nil, compact: Bool = false, onTap: @escaping () -> Void) {
        self.fine = fine
        self.ruleName = ruleName
        self.eventTitle = eventTitle
        self.groupName = groupName
        self.compact = compact
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .buttonStyle(.ruulPress)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ruleName ?? fine.reason), \(fine.amountFormatted), \(fine.status.displayLabel)")
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            if let groupName {
                Text(groupName)
                    .font(.footnote.weight(.semibold))
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

    /// Wallet-style compact row para historial. Status dot leading,
    /// nombre + grupo opcional middle, monto monospaced right.
    /// Sin divider ni hero padding — el contexto es "vista archivo".
    private var compactBody: some View {
        HStack(spacing: RuulSpacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(ruleName ?? fine.reason)
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(1)
                if let groupName {
                    Text(groupName)
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .textCase(.uppercase)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            RuulMoneyView(
                amount: fine.amount,
                currency: "MXN",
                size: .small,
                color: .neutral
            )
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            if let createdAgo {
                Text(createdAgo)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
    }

    private var contentRow: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ruleName ?? fine.reason)
                    .font(.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let eventTitle {
                    Text(eventTitle)
                        .font(.footnote)
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
