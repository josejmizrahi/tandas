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
            .task { await coordinator.refresh() }
    }

    @ViewBuilder
    private var contentLayer: some View {
        AsyncContentView(
            phase: coordinator.phase,
            onRetry: { await coordinator.refresh() },
            empty: { emptyState },
            loaded: { actions in
                List {
                    ForEach(prioritizedBuckets(actions), id: \.label) { bucket in
                        Section {
                            ForEach(bucket.actions) { action in
                                InboxActionRow(
                                    icon: icon(for: action.actionType),
                                    meta: meta(for: action),
                                    title: action.title,
                                    subtitle: action.body,
                                    priorityDot: dotColor(for: action.priority),
                                    timeRemaining: UserActionExpiry.remainingDescription(for: action),
                                    onTap: { onOpenAction(action) }
                                )
                                .contextMenu {
                                    Button {
                                        Task { await coordinator.resolveQuick(action.id) }
                                    } label: {
                                        Label("Marcar como hecho", systemImage: "checkmark.circle.fill")
                                    }
                                }
                            }
                        } header: {
                            Text(bucket.label)
                        }
                    }
                }
                .listStyle(.insetGrouped)
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

    private func dotColor(for raw: ActionPriority) -> Color {
        switch raw {
        case .low:    return Color(.tertiaryLabel)
        case .medium: return .blue
        case .high:   return .orange
        case .urgent: return .red
        }
    }
}

/// Pending-action row inside the inbox List. Native list row chrome
/// (List provides separators + insetGrouped background); the row body
/// composes icon + meta line + title with priority dot + subtitle +
/// trailing time-remaining. Replaces `ActionCard` per Plan §2.5 +
/// Component Map §10 (Activity Feed pattern).
private struct InboxActionRow: View {
    let icon: String
    let meta: String?
    let title: String
    let subtitle: String?
    let priorityDot: Color
    let timeRemaining: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(Color(.tertiarySystemFill), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    if let meta {
                        Text(meta.uppercased())
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(priorityDot)
                            .frame(width: 8, height: 8)
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if let timeRemaining {
                    Text(timeRemaining)
                        .font(.footnote.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
