import SwiftUI
import RuulUI
import RuulCore

/// "Pendiente del grupo" — UserAction rows inside the canonical
/// section card chrome (`Color.ruulSurface` + separator stroke).
/// Each row = tinted icon + title + subtitle + CTA capsule. Urgent /
/// high-priority items get a red badge dot. No gradients.
@MainActor
struct GroupPendingsBlock: View {
    let items: [UserAction]
    let onSelect: (UserAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Pendiente del grupo")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                    if item.id != items.last?.id {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, 64)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
    }

    private func row(_ item: UserAction) -> some View {
        HStack(spacing: RuulSpacing.md) {
            iconBadge(item)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button(Self.cta(for: item.actionType)) { onSelect(item) }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ruulTextInverse)
                .padding(.horizontal, RuulSpacing.sm)
                .padding(.vertical, RuulSpacing.xxs)
                .background(Self.tint(for: item.actionType), in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(RuulSpacing.md)
    }

    private func iconBadge(_ item: UserAction) -> some View {
        let tint = Self.tint(for: item.actionType)
        return ZStack(alignment: .topTrailing) {
            Image(systemName: Self.icon(for: item.actionType))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: Circle())

            if item.priority == .urgent || item.priority == .high {
                Circle()
                    .fill(Color.ruulNegative)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle().strokeBorder(Color.ruulSurface, lineWidth: 2)
                    )
                    .offset(x: 2, y: -2)
            }
        }
    }

    // MARK: - Per-action decoding

    static func icon(for type: ActionType) -> String {
        switch type {
        case .finePending, .fineVoided:                  return "exclamationmark.triangle.fill"
        case .fineProposalReview:                        return "doc.text.magnifyingglass"
        case .appealVotePending, .votePending,
             .ruleChangeApplyPending:                    return "checkmark.square"
        case .rsvpPending:                               return "calendar.badge.checkmark"
        case .hostAssigned:                              return "star.circle.fill"
        case .slotPending:                               return "person.crop.circle.badge.questionmark"
        case .contributionDue, .compensationDue:         return "creditcard.fill"
        case .assetActionApproval:                       return "checkmark.shield.fill"
        }
    }

    static func tint(for type: ActionType) -> Color {
        switch type {
        case .finePending, .fineVoided, .fineProposalReview: return Color.ruulWarning
        case .appealVotePending, .votePending,
             .ruleChangeApplyPending:                        return GroupColorRamp.blue.accent
        case .rsvpPending:                                   return Color.ruulWarning
        case .hostAssigned:                                  return GroupColorRamp.purple.accent
        case .slotPending:                                   return Color.ruulInfo
        case .contributionDue, .compensationDue:             return Color.ruulPositive
        case .assetActionApproval:                           return Color.ruulInfo
        }
    }

    static func cta(for type: ActionType) -> String {
        switch type {
        case .finePending:                  return "Pagar"
        case .fineVoided:                   return "Ver"
        case .fineProposalReview:           return "Revisar"
        case .appealVotePending,
             .votePending,
             .ruleChangeApplyPending:       return "Votar"
        case .rsvpPending:                  return "Confirmar"
        case .hostAssigned:                 return "Ver"
        case .slotPending:                  return "Elegir"
        case .contributionDue:              return "Aportar"
        case .compensationDue:              return "Pagar"
        case .assetActionApproval:          return "Revisar"
        }
    }
}
