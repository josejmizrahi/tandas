import SwiftUI

/// Unified inbox of pending UserActions: multas pendientes, apelaciones por
/// votar, RSVPs por contestar, multas para revisar (host). Each row taps to
/// the matching detail screen — the ActionType → route map lives in the
/// caller so this view stays template-agnostic.
struct ActionInboxView: View {
    @Bindable var coordinator: InboxCoordinator
    let onOpenAction: (UserAction) -> Void

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            if coordinator.actions.isEmpty && !coordinator.isLoading {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: RuulSpacing.s3) {
                        ForEach(coordinator.actions) { action in
                            ActionCard(
                                icon: icon(for: action.actionType),
                                title: action.title,
                                subtitle: action.body,
                                priority: priority(for: action.priority),
                                timeRemaining: nil,
                                onTap: { onOpenAction(action) }
                            )
                        }
                    }
                    .padding(.horizontal, RuulSpacing.s5)
                    .padding(.top, RuulSpacing.s4)
                    .padding(.bottom, RuulSpacing.s12)
                }
                .scrollIndicators(.hidden)
                .refreshable { await coordinator.refresh() }
            }
        }
        .task { await coordinator.refresh() }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.large)
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "tray",
            title: "Sin pendientes",
            message: "No hay multas, apelaciones ni RSVPs por atender. Todo al corriente."
        )
    }

    // MARK: - Mapping (template-aware in V1; future templates will plug their own)

    private func icon(for type: ActionType) -> String {
        switch type {
        case .finePending:        return "exclamationmark.triangle.fill"
        case .appealVotePending:  return "hand.raised.fill"
        case .rsvpPending:        return "checkmark.circle.fill"
        case .fineProposalReview: return "doc.text.magnifyingglass"
        case .slotPending:        return "ticket.fill"
        case .votePending:        return "checkmark.square.fill"
        case .contributionDue:    return "banknote.fill"
        case .compensationDue:    return "arrow.up.right"
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
