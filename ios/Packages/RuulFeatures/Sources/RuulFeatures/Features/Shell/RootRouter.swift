import Foundation
import Observation
import RuulCore

/// Owns navigation intent for the post-auth shell. Views and the inbox
/// hand intent to the router (`present`, `selectTab`, `handle(deeplink:)`);
/// the router mutates `RootShellState`; SwiftUI rebuilds from observation.
///
/// One responsibility: convert intent → state. No data fetching, no
/// business rules, no RPC calls. Coordinators do that.
///
/// ## Rule-change deep links
///
/// `RuleChangeDeepLink` carries only `ruleId` + `proposedAmount` — the
/// full `GroupRule` and `Group` must be fetched before routing. For this
/// reason there is NO `handle(ruleChangeDeepLink:)` method. Instead,
/// `AuthGate` / `RootShell` observes `AppState.pendingRuleChangeDeepLink`,
/// fetches the rule, and calls `handleRuleChange(rule:group:proposedAmount:
/// pendingActionId:)` directly (mirroring the MainTabView pattern).
@MainActor
@Observable
public final class RootRouter {
    public let state: RootShellState

    public init(state: RootShellState) {
        self.state = state
    }

    // MARK: - Tab selection

    public func selectTab(_ tab: RootTab) {
        state.selectedTab = tab
    }

    /// Handles the raw tab selection from `TabView`, intercepting the
    /// `.create` tap to present the wizard cover without actually moving
    /// to a "create" tab (which has no content of its own).
    public func handleTabSelection(_ tab: RootTab, hasActiveGroup: Bool) {
        guard tab == .create else {
            selectTab(tab)
            return
        }
        // Intercept: don't change selectedTab, just present the cover.
        if hasActiveGroup {
            present(.createCover)
        } else {
            present(.createGroup)
        }
    }

    // MARK: - Routes

    public func present(_ route: RootRoute) {
        state.push(route)
    }

    public func dismissTop() {
        state.dismissTop()
    }

    public func dismissAll() {
        state.dismissAll()
    }

    // MARK: - Deep links

    /// Routes an event notification / URL tap to `.eventDetail`.
    /// Only `link.eventId` is used; any additional fields in `EventDeepLink`
    /// (e.g. section anchors) are reserved for Pass 2.
    public func handle(eventDeepLink link: EventDeepLink) {
        present(.eventDetail(link.eventId))
    }

    /// Routes a rule-change deep link after the caller has fetched the
    /// required `GroupRule` and `Group` (async — the router is sync-only).
    ///
    /// Call site pattern (mirrors legacy `MainTabView.handleRuleChangeDeepLink`):
    /// ```swift
    /// let link = app.pendingRuleChangeDeepLink
    /// defer { app.consumeRuleChangeDeepLink() }
    /// guard let rule = try? await ruleRepo.list(groupId: group.id)
    ///         .first(where: { $0.id == link.ruleId }) else { return }
    /// router.handleRuleChange(
    ///     rule: rule, group: group,
    ///     proposedAmount: link.proposedAmount,
    ///     pendingActionId: nil
    /// )
    /// ```
    public func handleRuleChange(
        rule: GroupRule,
        group: Group,
        proposedAmount: Int?,
        pendingActionId: UUID?
    ) {
        present(.ruleEdit(RuleEditRouteContext(
            rule: rule,
            group: group,
            proposedAmount: proposedAmount,
            pendingActionId: pendingActionId
        )))
    }

    // MARK: - Resource navigation (payload + route push pairs)

    /// Polymorphic detail entry: pushes a `RootRoute.eventDetail` for now
    /// (Pass 1 keeps the route name event-shaped for compatibility with
    /// EventDeepLink). Future passes can fork on resource_type.
    ///
    /// Note: this does NOT set `state.activeEvent`. Use this only when
    /// you have just the resource id and the detail view can hydrate
    /// itself; otherwise call `openEvent(_:)` which carries the full model.
    public func openResource(id: UUID) {
        state.push(.eventDetail(id))
    }

    /// Opens an event in the detail cover. Stores the full Event on
    /// shellState (so RootShellSheets can read it) and pushes the route.
    public func openEvent(_ event: Event) {
        state.activeEvent = event
        state.push(.eventDetail(event.id))
    }

    public func openEditEvent(_ event: Event) {
        state.activeEditEvent = event
        state.push(.editEvent)
    }

    public func openScanner(_ coordinator: CheckInScannerCoordinator) {
        state.activeScannerCoordinator = coordinator
        state.push(.scanner(coordinator.event.id))
    }

    /// Opens a fine in the detail cover. Stores the full Fine on
    /// `state.activeFine` (so `RootShellSheets` can build the coordinator
    /// synchronously) and pushes the route. Mirrors `openEvent(_:)`.
    public func openFine(_ fine: Fine) {
        state.activeFine = fine
        state.push(.fineDetail(fine.id))
    }

    /// Pushes the `.fineDetail` route by id. Callers that only have a fine
    /// id (deep links, push notifications) use this; the `RootShellSheets`
    /// `activeFineItem` binding ignores the route when `state.activeFine`
    /// is nil, so most call sites should prefer `openFine(_:)` with the
    /// fetched model.
    public func openFineDetail(_ fineId: UUID) {
        state.push(.fineDetail(fineId))
    }

    public func openPastEvents() {
        state.push(.past)
    }

    public func openFeed() {
        state.push(.feed)
    }

    public func openGroupHistory() {
        state.push(.groupHistory)
    }

    public func openAcuerdos() {
        state.push(.acuerdos)
    }

    public func openSanciones() {
        state.push(.sanciones)
    }

    public func openGroupRulesSettings() {
        state.push(.groupRulesSettings)
    }

    public func openGroupSwitcher() {
        state.push(.groupSwitcher)
    }

    public func openGroupHome() {
        present(.groupHome)
    }

    public func openInviteShare() {
        state.push(.inviteShare)
    }

    public func openEditProfile() {
        state.push(.editProfile)
    }

    public func openMembersList() {
        state.push(.membersList)
    }

    public func openMembersAdmin() {
        state.push(.membersAdmin)
    }

    public func openOpenVotes(_ ctx: OpenVotesRouteContext) {
        state.push(.openVotes(ctx))
    }

    public func openVoteDetail(_ ctx: VoteDetailRouteContext) {
        state.push(.voteDetail(ctx))
    }

    public func openVoteOnAppeal(_ ctx: AppealRouteContext) {
        state.push(.voteOnAppeal(ctx))
    }

    public func openCreateVotePicker() {
        state.push(.createVotePicker)
    }

    public func openCreateGeneralProposal() {
        state.push(.createGeneralProposal)
    }

    public func openCreateRuleChange(initialRule: GroupRule? = nil) {
        state.push(.createRuleChange(initialRule))
    }
}
