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

            Label(dispute.status.label, systemImage: statusSymbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.quaternary))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var statusSymbol: String {
        switch dispute.status {
        case .open:       return "circle"
        case .inReview:   return "magnifyingglass.circle.fill"
        case .mediation:  return "person.2.fill"
        case .escalated:  return "exclamationmark.triangle.fill"
        case .resolved:   return "checkmark.circle.fill"
        case .dismissed:  return "minus.circle"
        case .closed:     return "lock.fill"
        }
    }
}
