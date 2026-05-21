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

    /// Trampolines the raw `TabView` tap to `selectTab(_:)`. The legacy
    /// 5-tab layout intercepted `.create` here to present the wizard
    /// cover; the 3-tab layout (2026-05-20) replaces that with a `+`
    /// toolbar item on Home that pushes `.createCover` directly, so this
    /// method is just a thin trampoline now.
    public func handleTabSelection(_ tab: RootTab, hasActiveGroup: Bool) {
        selectTab(tab)
    }

    /// Single entry point used by Home's toolbar `+` button. Pushes the
    /// wizard cover when the user has an active group; otherwise it
    /// drops them into "Crear grupo" instead (preserves the previous
    /// 5-tab `.create` intercept behavior).
    public func presentCreate(hasActiveGroup: Bool) {
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

    /// Same as `openEvent(_:)` but also stashes an initial-action hint
    /// so the EventDetailHost auto-presents a follow-up surface as soon
    /// as bootstrap finishes. Used by the post-create intent screen to
    /// land the user directly on an actionable surface (share for
    /// "Invitar gente", scanner for "Pasar lista") instead of dumping
    /// them on the default Overview tab.
    public func openEvent(_ event: Event, initialAction: PendingEventInitialAction) {
        state.pendingEventInitialAction = initialAction
        openEvent(event)
    }

    /// Opens a polymorphic resource (fund/asset/space/slot/right) in
    /// the universal detail cover. Sets `state.activeResource` so the
    /// `RootShellSheets` handler can build `ResourceDetailSheet`
    /// synchronously. Events use `openEvent(_:)` instead — EventDetailHost
    /// needs the full `Event` for RSVP / check-in adapters which a
    /// bare `ResourceRow` can't satisfy.
    public func openResource(_ row: ResourceRow) {
        state.activeResource = row
        state.push(.resourceDetail(row.id))
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

    // V2 Slice 4C: openAcuerdos() removed. Acuerdos now lives as a
    // Group sheet NavigationStack push (GroupNav.acuerdos), the
    // canonical entry the original Pass-1 plan called for.

    /// V2 Slice 4D: cross-tab deep link into Profile's local Mis multas
    /// cover. Switches to the `.profile` tab and raises a flag that
    /// `ProfileTab` observes to present its local `MyFinesScreenHost`.
    /// Replaces the prior `openSanciones()` which presented a root cover
    /// (modal depth 3 from Group sheet); the new flow caps depth at 2.
    public func requestOpenMyFines() {
        selectTab(.profile)
        state.pendingOpenMyFines = true
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

    // V2 Slice 4B: openMembersList / openMembersAdmin removed. Both
    // root routes were orphaned — the canonical entry is the Group
    // sheet NavigationStack push (GroupNav.membersList / .membersAdmin).

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
