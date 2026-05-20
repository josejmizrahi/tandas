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
        AsyncContentView(
            phase: coordinator.phase,
            onRetry: { await coordinator.refresh() },
            empty: { emptyState },
            loaded: { actions in
                ScrollView {
                    VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                        ForEach(prioritizedBuckets(actions), id: \.label) { bucket in
                            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                                RuulListSectionHeader(bucket.label.uppercased(), count: bucket.actions.count)
                                RuulSeparatedRows(items: bucket.actions) { action in
                                    actionRow(action)
                                }
                            }
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
            }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Sin pendientes", systemImage: "tray")
        } description: {
            Text("No hay multas, apelaciones ni RSVPs por atender. Todo al corriente.")
        }
    }

    /// Agrupa actions en 3 buckets de urgencia (Apple Mail / Linear
    /// pattern). El usuario escanea por prioridad sin leer cada row.
    /// Solo se renderizan buckets no vacíos para evitar headers huecos.
    private struct ActionBucket {
        let label: String
        let actions: [UserAction]
    }

    private func prioritizedBuckets(_ actions: [UserAction]) -> [ActionBucket] {
        let urgent  = actions.filter { $0.priority == .urgent || $0.priority == .high }
        let pending = actions.filter { $0.priority == .medium }
        let later   = actions.filter { $0.priority == .low }
        var out: [ActionBucket] = []
        if !urgent.isEmpty  { out.append(ActionBucket(label: "Urgentes",  actions: urgent)) }
        if !pending.isEmpty { out.append(ActionBucket(label: "Pendientes", actions: pending)) }
        if !later.isEmpty   { out.append(ActionBucket(label: "Después",   actions: later)) }
        return out
    }

    @ViewBuilder
    private func actionRow(_ action: UserAction) -> some View {
        ActionCard(
            icon: icon(for: action.actionType),
            meta: meta(for: action),
            title: action.title,
            subtitle: action.body,
            priority: priority(for: action.priority),
            timeRemaining: UserActionExpiry.remainingDescription(for: action),
            onTap: { onOpenAction(action) }
        )
        .scrollTransition(.animated.threshold(.visible(0.2))) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1.0 : 0.96)
        }
        .contextMenu {
            Button {
                Task { await coordinator.resolveQuick(action.id) }
            } label: {
                Label("Marcar como hecho", systemImage: "checkmark.circle.fill")
            }
        }
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
        case .assetActionApproval:     return "checkmark.shield.fill"
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
