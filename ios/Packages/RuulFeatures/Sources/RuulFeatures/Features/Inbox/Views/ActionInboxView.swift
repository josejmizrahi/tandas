import SwiftUI
import RuulUI
import RuulCore

/// Unified inbox of pending UserActions: multas pendientes, apelaciones por
/// votar, RSVPs por contestar, multas para revisar (host). Each row taps to
/// the matching detail screen — the ActionType → route map lives in the
/// caller so this view stays template-agnostic.
public struct ActionInboxView: View {
    @Bindable var coordinator: InboxCoordinator
    @Environment(AppState.self) private var app
    public let onOpenAction: (UserAction) -> Void

    public init(coordinator: InboxCoordinator, onOpenAction: @escaping (UserAction) -> Void) {
        self.coordinator = coordinator
        self.onOpenAction = onOpenAction
    }

    public var body: some View {
        contentLayer
            .ruulAmbientScreen(palette: nil)
            .task { await coordinator.refresh() }
    }

    @ViewBuilder
    private var contentLayer: some View {
        SwiftUI.Group {
            if let error = coordinator.error, coordinator.actions.isEmpty {
                ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                    .padding(.horizontal, RuulSpacing.lg)
                    .padding(.top, RuulSpacing.lg)
                    .transition(.opacity)
            } else if coordinator.actions.isEmpty && coordinator.isLoading {
                RuulLoadingState()
                    .transition(.opacity)
            } else if coordinator.actions.isEmpty {
                emptyState
                    .transition(.opacity)
            } else {
                ScrollView {
                    RuulSeparatedRows(items: coordinator.actions) { action in
                        ActionCard(
                            icon: icon(for: action.actionType),
                            meta: meta(for: action),
                            title: action.title,
                            subtitle: action.body,
                            priority: priority(for: action.priority),
                            timeRemaining: nil,
                            onTap: { onOpenAction(action) }
                        )
                        .scrollTransition(.animated.threshold(.visible(0.2))) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1.0 : 0.96)
                        }
                    }
                    .padding(.horizontal, RuulSpacing.lg)
                    .padding(.top, RuulSpacing.md)
                    .padding(.bottom, RuulSpacing.s12)
                }
                .scrollIndicators(.hidden)
                .contentMargins(RuulSpacing.md, for: .scrollIndicators)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .refreshable { await coordinator.refresh() }
                .transition(.opacity)
            }
        }
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.actions.isEmpty)
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
        case .finePending:             return "exclamationmark.triangle.fill"
        case .fineVoided:              return "xmark.circle"
        case .appealVotePending:       return "hand.raised.fill"
        case .rsvpPending:             return "checkmark.circle.fill"
        case .fineProposalReview:      return "doc.text.magnifyingglass"
        case .ruleChangeApplyPending:  return "list.bullet.clipboard.fill"
        case .hostAssigned:            return "person.crop.circle.badge.checkmark"
        case .slotPending:             return "ticket.fill"
        case .votePending:             return "hand.raised.fill"
        case .contributionDue:         return "banknote.fill"
        case .compensationDue:         return "arrow.up.right"
        }
    }

    /// Most action types show the group name as meta; rule-change apply
    /// rows replace that with the vote-resolved timestamp ("votado [fecha]")
    /// so the host immediately sees how recent the approval is.
    private func meta(for action: UserAction) -> String? {
        switch action.actionType {
        case .ruleChangeApplyPending:
            return "Votado \(action.createdAt.ruulRelativeDescription)"
        default:
            return coordinator.groupName(for: action)
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
