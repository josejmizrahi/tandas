import SwiftUI
import RuulUI
import RuulCore

/// Fallback body para vote_types sin UI dedicada (V1: rule_repeal,
/// member_removal, fund_withdrawal, role_assignment, slot_dispute).
/// Renderiza title + description + payload as JSON in monospace card.
/// Cuando esos vote_types tengan feature shipped, cada uno gana su
/// body dedicado y este queda solo para `unknown` enum case.
public struct GenericVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            if let desc = coordinator.vote.description, !desc.isEmpty {
                Text(desc)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }

            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                Text("PAYLOAD")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(payloadJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(RuulSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.small, style: .continuous))
            }
        }
    }

    private var payloadJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(coordinator.vote.payload),
              let str = String(data: data, encoding: .utf8) else {
            return "(unable to render payload)"
        }
        return str
    }
}
