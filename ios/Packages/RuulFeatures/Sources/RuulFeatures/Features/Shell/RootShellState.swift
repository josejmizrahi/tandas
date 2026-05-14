import Foundation
import Observation
import RuulCore

/// Shell-scope `@Observable` state for the post-auth root. Owns:
/// - which tab is currently selected
/// - the stack of active sheet/cover routes (centralized so RootShellSheets
///   ViewModifier can drive every presentation from a single source)
///
/// Lives ABOVE feature coordinators (which own their own data) and BELOW
/// `AppState` (which owns cross-group session + repos).
@MainActor
@Observable
public final class RootShellState {
    public var selectedTab: RootTab = .home
    public private(set) var activeRoutes: [RootRoute] = []

    public init() {}

    public func push(_ route: RootRoute) {
        activeRoutes.append(route)
    }

    public func dismissTop() {
        guard !activeRoutes.isEmpty else { return }
        activeRoutes.removeLast()
    }

    public func dismissAll() {
        activeRoutes.removeAll()
    }

    public func contains(_ route: RootRoute) -> Bool {
        activeRoutes.contains(route)
    }
}

/// Tab inventory preserved 1:1 from legacy `MainTabView` so Pass 1 is
/// pure refactor. Pass 2 changes the inventory to match `AppShell.md`.
public enum RootTab: String, Sendable, Hashable, CaseIterable {
    case home
    case group
    case create
    case decisions
    case profile
}

/// Sheet / cover routes presented above the tab content. Each case maps to
/// one `.sheet(...)` or `.fullScreenCover(...)` slot inside
/// `RootShellSheets`. Cases that carry context use small Hashable
/// payload types (defined as public structs at the bottom of MainTabView.swift).
public enum RootRoute: Sendable, Hashable {
    case createGroup
    case joinGroup
    case groupSwitcher
    case inviteShare
    case groupRulesSettings
    case createCover            // ResourceWizard cover
    case eventDetail(UUID)      // event.id — typed as UUID for now; Pass 2 may polymorphize
    case fineDetail(UUID)       // fine.id
    case ruleEdit(RuleEditRouteContext)
    case voteDetail(VoteDetailRouteContext)
    case openVotes(OpenVotesRouteContext)
    case voteOnAppeal(AppealRouteContext)
    case scanner(UUID)          // event.id we are scanning into (placeholder; refine in Task 9)
    case past
    case feed
    case groupHistory
    case acuerdos
    case sanciones
    case createVotePicker
    case createGeneralProposal
    case createRuleChange(GroupRule?)
}
