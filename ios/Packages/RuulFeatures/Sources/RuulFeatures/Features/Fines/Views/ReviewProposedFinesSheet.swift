import SwiftUI
import RuulUI
import RuulCore

/// Self-contained sheet wrapper around `ReviewProposedFinesView`.
///
/// Why this exists:
///   - The review view needs a `memberLookup: (UUID) -> String`, but
///     callers (HomeTab, MyGroupsTab) only have an `Event` in hand from
///     the inbox action.
///   - This wrapper loads the event's group members lazily via
///     `GroupsRepository.membersWithProfiles` and resolves names from
///     the loaded directory. Falls back gracefully to "Miembro" until
///     the directory loads.
///   - Auto-resolves stale `.fineProposalReview` actions: when the
///     coordinator loads and the event has zero fines (proposed or
///     resolved), the originating UserAction is marked resolved
///     server-side so the inbox doesn't keep showing a dead row. This
///     covers the legacy/race case where mig 00044's auto-resolve
///     trigger didn't fire (e.g., fines voided + action survived).
///
/// Wired from:
///   - `HomeTab.handleInboxAction(.fineProposalReview)`
///   - `MyGroupsTab.handleInboxAction(.fineProposalReview)`
///
/// Per mig 00044: `fineProposalReview.reference_id == event_id`. Caller
/// is responsible for fetching the `Event` from `EventRepository` before
/// presenting this sheet.
@MainActor
struct ReviewProposedFinesSheet: View {
    @Environment(AppState.self) private var app
    let event: Event
    /// Optional id of the originating UserAction. When passed, the sheet
    /// auto-resolves it server-side if the event has zero fines on load
    /// (stale-action cleanup).
    let pendingActionId: UUID?
    let onClose: () -> Void
    let onSelectFine: (Fine) -> Void

    @State private var members: [MemberWithProfile] = []
    @State private var coordinator: ReviewProposedFinesCoordinator?
    @State private var didAttemptStaleResolve = false

    var body: some View {
        NavigationStack {
            Group {
                if let coordinator {
                    ReviewProposedFinesView(
                        coordinator: coordinator,
                        memberLookup: memberLookup,
                        onSelectFine: onSelectFine
                    )
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo", action: onClose)
                }
            }
        }
        .task(id: event.id) {
            if coordinator == nil {
                coordinator = ReviewProposedFinesCoordinator(
                    event: event,
                    fineRepo: app.fineRepo,
                    changeFeed: app.multiDeviceChangeFeed
                )
            }
        }
        .task(id: event.groupId) {
            members = (try? await app.groupsRepo.membersWithProfiles(of: event.groupId)) ?? []
        }
        .onChange(of: coordinator?.isLoading) { _, isLoading in
            // Stale-action cleanup: when the load completes with zero
            // fines AND a UserAction id was passed in, mark it resolved
            // so the inbox stops surfacing this dead row. Idempotent —
            // the repo's resolve() is a no-op for already-resolved
            // actions. Only attempts once per sheet open.
            guard
                let coordinator,
                isLoading == false,
                !didAttemptStaleResolve,
                coordinator.error == nil,
                coordinator.fines.isEmpty,
                let actionId = pendingActionId
            else { return }
            didAttemptStaleResolve = true
            Task {
                try? await app.userActionRepo.resolve(actionId: actionId)
            }
        }
    }

    /// Resolves a member's display name from the loaded directory.
    /// Keyed by `auth.users.id` because `Fine.userId` carries the
    /// user id (not group_members.id) — same pattern as
    /// `FineDetailHost.membersByUserId`.
    private func memberLookup(_ userId: UUID) -> String {
        members.first(where: { $0.member.userId == userId })?.displayName ?? "Miembro"
    }
}
