import SwiftUI
import RuulCore

/// Single row inside the disputes list. Neutral copy — solo nombra
/// quién la abrió, contra quién, y el estado actual.
public struct DisputeRowView: View {
    let dispute: GroupDispute

    public init(dispute: GroupDispute) {
        self.dispute = dispute
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: dispute.subjectKind.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(dispute.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(dispute.subjectKind.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let opened = dispute.openedByDisplayName {
                    Text("Abierta por \(opened)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let description = dispute.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }

                if let opened = dispute.openedAt {
                    Text(opened, format: .dateTime.day().month().year())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(dispute.status.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(statusBackground)
                )
                .foregroundStyle(statusForeground)
        }
        .padding(.vertical, 4)
    }

    private var statusBackground: Color {
        switch dispute.status {
        case .mediation, .inReview: return Color.blue.opacity(0.15)
        case .escalated:            return Color.orange.opacity(0.18)
        case .open:                 return Color.gray.opacity(0.12)
        default:                    return Color.gray.opacity(0.08)
        }
    }

    private var statusForeground: AnyShapeStyle {
        switch dispute.status {
        case .mediation, .inReview: return AnyShapeStyle(.blue)
        case .escalated:            return AnyShapeStyle(.orange)
        default:                    return AnyShapeStyle(.secondary)
        }
    }
}
