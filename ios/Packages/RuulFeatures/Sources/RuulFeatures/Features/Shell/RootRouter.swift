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
}
