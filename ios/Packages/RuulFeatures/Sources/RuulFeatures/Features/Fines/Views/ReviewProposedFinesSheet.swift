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
///   - Both call sites can now `.sheet(item: $event) { ReviewProposedFinesSheet(event:...) }`
///     without duplicating the loading scaffolding.
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
    let onClose: () -> Void
    let onSelectFine: (Fine) -> Void

    @State private var members: [MemberWithProfile] = []

    var body: some View {
        NavigationStack {
            ReviewProposedFinesView(
                coordinator: ReviewProposedFinesCoordinator(
                    event: event,
                    fineRepo: app.fineRepo,
                    changeFeed: app.multiDeviceChangeFeed
                ),
                memberLookup: memberLookup,
                onSelectFine: onSelectFine
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo", action: onClose)
                }
            }
        }
        .task(id: event.groupId) {
            members = (try? await app.groupsRepo.membersWithProfiles(of: event.groupId)) ?? []
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
