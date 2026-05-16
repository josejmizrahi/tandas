import SwiftUI
import RuulCore
import RuulUI

// MARK: - Chip definition

enum InboxChip: String, CaseIterable, Identifiable {
    case all          = "Todos"
    case urgente      = "Urgente"
    case aprobaciones = "Aprobaciones"
    case votos        = "Votos"
    case pagos        = "Pagos"
    case solicitudes  = "Solicitudes"
    case confirmar    = "Confirmar"
    case recordatorios = "Recordatorios"
    case resueltas     = "Resueltas"

    var id: String { rawValue }

    var label: String { rawValue }

    var systemImage: String {
        switch self {
        case .all:           return "tray.fill"
        case .urgente:       return "exclamationmark.triangle.fill"
        case .aprobaciones:  return "doc.text.magnifyingglass"
        case .votos:         return "hand.raised.fill"
        case .pagos:         return "dollarsign.circle.fill"
        case .solicitudes:   return "arrow.2.squarepath"
        case .confirmar:     return "checkmark.circle.fill"
        case .recordatorios: return "bell.fill"
        case .resueltas:     return "checkmark.circle"
        }
    }

    /// Returns true when the given action should appear under this chip.
    /// NOTE: .solicitudes has no direct ActionType mapping today (swap_request
    /// is not yet an ActionType case). It always returns false until that
    /// case is added.
    func matches(_ action: UserAction) -> Bool {
        switch self {
        case .all:
            return true
        case .urgente:
            return action.priority == .urgent
        case .aprobaciones:
            return action.actionType == .fineProposalReview
                || action.actionType == .ruleChangeApplyPending
        case .votos:
            return action.actionType == .appealVotePending
                || action.actionType == .votePending
        case .pagos:
            return action.actionType == .finePending
                || action.actionType == .fineVoided
        case .solicitudes:
            // No ActionType maps here yet (swap_request pending).
            return false
        case .confirmar:
            return action.actionType == .rsvpPending
        case .recordatorios:
            return action.actionType == .hostAssigned
        case .resueltas:
            // Resolved actions come from a separate fetch (coordinator.resolvedActions),
            // not from the pending pool. This chip never matches a pending action.
            return false
        }
    }

    func count(in actions: [UserAction]) -> Int {
        actions.filter { matches($0) }.count
    }
}

// MARK: - InboxView

/// Inbox tab body: horizontal filter chips + ActionInboxView.
/// The coordinator is passed through unchanged; filtering is applied
/// on top via a computed subset rendered by a local ForEach-based
/// override below the chips strip.
@MainActor
public struct InboxView: View {
    @Bindable var coordinator: InboxCoordinator
    public let onOpenAction: (UserAction) -> Void

    @State private var selectedChip: InboxChip = .all
    @State private var showBulkAlert = false
    @State private var toastMessage: String?

    public init(coordinator: InboxCoordinator, onOpenAction: @escaping (UserAction) -> Void) {
        self.coordinator = coordinator
        self.onOpenAction = onOpenAction
    }

    public var body: some View {
        VStack(spacing: 0) {
            chipsStrip
            Divider()
            filteredInbox
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.large)
        .task(id: selectedChip) {
            if selectedChip == .resueltas {
                await coordinator.loadResolved()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selectedChip != .resueltas && coordinator.actions.count > 1 {
                    Button("Marcar todas") { showBulkAlert = true }
                }
            }
        }
        .alert(
            "¿Marcar las \(coordinator.actions.count) acciones como hechas?",
            isPresented: $showBulkAlert
        ) {
            Button("Marcar", role: .destructive) {
                Task {
                    let count = await coordinator.resolveAll()
                    showToast(count: count)
                }
            }
            Button("Cancelar", role: .cancel) {}
        }
    }

    // MARK: - Chips strip

    private var chipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.xs) {
                ForEach(InboxChip.allCases) { chip in
                    let count = chip.count(in: coordinator.actions)
                    RuulChip(
                        chip.label,
                        systemImage: chip.systemImage,
                        style: chip == selectedChip
                            ? .selectable(isSelected: true)
                            : (count > 0 ? .count(count) : .selectable(isSelected: false))
                    ) {
                        selectedChip = chip
                    }
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.sm)
        }
        .background(Color.ruulBackground)
    }

    // MARK: - Filtered content

    /// ActionInboxView renders coordinator.actions directly. To support
    /// chip filtering we build a filtered coordinator proxy approach below:
    /// we pass the coordinator as-is and overlay an empty-state when the
    /// filter yields zero results. For the non-.all chips we use a dedicated
    /// filtered list instead of ActionInboxView so we can inject a subset.
    // MARK: - Toast

    /// Displays a bottom toast for `count` resolved actions, auto-dismissing after 5 s.
    func showToast(count: Int) {
        toastMessage = count == 1 ? "1 acción resuelta" : "\(count) acciones resueltas"
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run { toastMessage = nil }
        }
    }

    // MARK: - Filtered content

    @ViewBuilder
    private var filteredInbox: some View {
        if selectedChip == .all {
            ActionInboxView(coordinator: coordinator, onOpenAction: onOpenAction)
        } else if selectedChip == .resueltas {
            ResolvedInboxList(
                actions: coordinator.resolvedActions,
                isLoading: coordinator.isLoading
            )
        } else {
            let filtered = coordinator.actions.filter { selectedChip.matches($0) }
            FilteredInboxList(
                actions: filtered,
                isLoading: coordinator.isLoading,
                onOpenAction: onOpenAction,
                onRefresh: { await coordinator.refresh() }
            )
        }
    }
}

// MARK: - FilteredInboxList

/// Lightweight list used when a chip narrows the action set.
/// Mirrors ActionInboxView's layout without the coordinator dependency.
@MainActor
private struct FilteredInboxList: View {
    @Environment(AppState.self) private var app
    let actions: [UserAction]
    let isLoading: Bool
    let onOpenAction: (UserAction) -> Void
    let onRefresh: () async -> Void

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            if actions.isEmpty && isLoading {
                RuulLoadingState()
                    .transition(.opacity)
            } else if actions.isEmpty {
                EmptyStateView(
                    systemImage: "tray",
                    title: "Sin pendientes",
                    message: "No hay acciones en esta categoria."
                )
                .transition(.opacity)
            } else {
                ScrollView {
                    VStack(spacing: RuulSpacing.sm) {
                        ForEach(actions) { action in
                            ActionCard(
                                icon: icon(for: action.actionType),
                                meta: nil,
                                title: action.title,
                                subtitle: action.body,
                                priority: priority(for: action.priority),
                                timeRemaining: nil,
                                onTap: { onOpenAction(action) }
                            )
                        }
                    }
                    .padding(.horizontal, RuulSpacing.lg)
                    .padding(.top, RuulSpacing.md)
                    .padding(.bottom, RuulSpacing.s12)
                }
                .scrollIndicators(.hidden)
                .refreshable { await onRefresh() }
                .transition(.opacity)
            }
        }
        .animation(.linear(duration: RuulDuration.fast), value: actions.isEmpty)
        .animation(.linear(duration: RuulDuration.fast), value: isLoading)
    }

    private func icon(for type: ActionType) -> String {
        switch type {
        case .finePending:            return "exclamationmark.triangle.fill"
        case .fineVoided:             return "xmark.circle"
        case .appealVotePending:      return "hand.raised.fill"
        case .rsvpPending:            return "checkmark.circle.fill"
        case .fineProposalReview:     return "doc.text.magnifyingglass"
        case .ruleChangeApplyPending: return "slider.horizontal.3"
        case .votePending:            return "hand.raised.fill"
        case .hostAssigned:           return "person.badge.plus"
        case .slotPending:            return "calendar.badge.plus"
        case .contributionDue:        return "dollarsign.circle"
        case .compensationDue:        return "dollarsign.arrow.circlepath"
        case .assetActionApproval:    return "checkmark.shield"
        }
    }

    private func priority(for p: ActionPriority) -> ActionCard.Priority {
        switch p {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        case .urgent: return .urgent
        }
    }
}

// MARK: - ResolvedInboxList

/// Read-only history of resolved actions. Each row is greyed out and shows
/// a relative "Resuelta hace X" trailing label in lieu of a navigation
/// chevron. Tapping does nothing — resolved rows are informational only.
@MainActor
private struct ResolvedInboxList: View {
    let actions: [UserAction]
    let isLoading: Bool

    private let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "es_MX")
        return f
    }()

    var body: some View {
        ZStack {
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            if actions.isEmpty && isLoading {
                RuulLoadingState()
                    .transition(.opacity)
            } else if actions.isEmpty {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "Sin resueltas",
                    message: "Cuando completes acciones aparecerán aquí."
                )
                .transition(.opacity)
            } else {
                ScrollView {
                    VStack(spacing: RuulSpacing.sm) {
                        ForEach(actions) { action in
                            resolvedRow(action)
                        }
                    }
                    .padding(.horizontal, RuulSpacing.lg)
                    .padding(.top, RuulSpacing.md)
                    .padding(.bottom, RuulSpacing.s12)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity)
            }
        }
        .animation(.linear(duration: RuulDuration.fast), value: actions.isEmpty)
        .animation(.linear(duration: RuulDuration.fast), value: isLoading)
    }

    @ViewBuilder
    private func resolvedRow(_ action: UserAction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: RuulSpacing.s1) {
                Text(action.title)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(.primary)
                if let body = action.body {
                    Text(body)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let resolvedAt = action.resolvedAt {
                Text("Resuelta \(formatter.localizedString(for: resolvedAt, relativeTo: .now))")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        .opacity(0.6)
    }
}
