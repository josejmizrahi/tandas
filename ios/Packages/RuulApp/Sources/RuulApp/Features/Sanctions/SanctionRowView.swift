import SwiftUI
import RuulCore

/// Single row inside the sanctions list. Renders kind/target/status
/// and, when the kind is monetary, the amount + currency. Doctrina
/// (Plan §B5): tipos no monetarios renderizan distinto.
public struct SanctionRowView: View {
    let sanction: GroupSanction

    public init(sanction: GroupSanction) {
        self.sanction = sanction
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: sanction.kind.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(sanction.isDisputed ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(sanction.kind.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(sanction.targetDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !sanction.reason.isEmpty {
                    Text(sanction.reason)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }

                if sanction.isMonetary, let amount = sanction.amount, let unit = sanction.unit {
                    Text("\(amount.formatted()) \(unit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let ends = sanction.endsAt {
                    Text("Vence \(ends.formatted(.dateTime.day().month().year()))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(sanction.status.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(sanction.isDisputed ? Color.orange.opacity(0.18) : Color.gray.opacity(0.12))
                )
                .foregroundStyle(sanction.isDisputed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .padding(.vertical, 4)
    }
}
