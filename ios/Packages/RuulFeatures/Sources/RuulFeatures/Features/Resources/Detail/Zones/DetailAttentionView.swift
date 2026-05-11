import SwiftUI
import RuulUI
import RuulCore

/// "Necesita atención" zone — the most habit-forming part of the
/// detail. Surfaces inbox actions whose `referenceId` matches this
/// resource: an unsigned RSVP, a fine that's due, a vote that closes
/// soon, a booking awaiting approval.
///
/// Hidden when there's nothing pending — empty space here is the
/// right default, not a placeholder.
public struct DetailAttentionView: View {
    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        if !context.attentionActions.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                sectionHeader("NECESITA ATENCIÓN", count: context.attentionActions.count)
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(context.attentionActions.prefix(4)) { action in
                        ActionCard(
                            icon: icon(for: action.actionType),
                            meta: action.createdAt.ruulRelativeDescription,
                            title: action.title,
                            subtitle: action.body,
                            priority: priority(for: action.priority),
                            timeRemaining: nil,
                            onTap: {
                                Task { await context.onOpenInboxAction(action) }
                            }
                        )
                    }
                }
            }
        }
    }

    private func icon(for type: ActionType) -> String {
        switch type {
        case .finePending:             return "exclamationmark.triangle.fill"
        case .fineVoided:              return "xmark.circle"
        case .appealVotePending:       return "hand.raised.fill"
        case .rsvpPending:             return "checkmark.circle.fill"
        case .fineProposalReview:      return "doc.text.magnifyingglass"
        case .ruleChangeApplyPending:  return "list.bullet.clipboard.fill"
        case .slotPending:             return "ticket.fill"
        case .votePending:             return "hand.raised.fill"
        case .contributionDue:         return "banknote.fill"
        case .compensationDue:         return "arrow.up.right"
        }
    }

    private func priority(for raw: ActionPriority) -> ActionCard.Priority {
        switch raw {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        case .urgent: return .urgent
        }
    }
}
