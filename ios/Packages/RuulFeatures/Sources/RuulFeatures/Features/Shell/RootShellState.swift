import Foundation
import Observation
import RuulCore

/// Shell-scope `@Observable` state for the post-auth root. Owns:
/// - which tab is currently selected
/// - the stack of active sheet/cover routes (centralized so RootShellSheets
///   ViewModifier can drive every presentation from a single source)
/// - coordinator handles that `RootShellSheets` branches need to construct
///   or invoke callbacks on (populated by `RootShell.rebuildCoordinators`
///   and consumed read-only by the ViewModifier)
/// - object payloads for presentations that require a full model (Event,
///   CheckInScannerCoordinator) rather than a plain UUID in `activeRoutes`
///
/// Lives ABOVE feature coordinators (which own their own data) and BELOW
/// `AppState` (which owns cross-group session + repos).
@MainActor
@Observable
public final class RootShellState {
    public var selectedTab: RootTab = .home
    public private(set) var activeRoutes: [RootRoute] = []

    // MARK: - Coordinator handles (populated by RootShell.rebuildCoordinators)
    // Writable so RootShell can set them; RootShellSheets reads them.

    public var inboxCoordinator: InboxCoordinator?
    public var rulesCoordinator: RulesCoordinator?
    public var profileCoordinator: ProfileCoordinator?
    public var homeCoordinator: HomeCoordinator?
    public var myFinesCoordinator: MyFinesCoordinator?

    // MARK: - Object payloads for fullScreenCover(item:) presentations
    // These parallel the route-stack signal for presentations that need a
    // full model object (not just a UUID) as the SwiftUI `item` binding.

    /// Active event shown in the detail cover. Set before pushing
    /// `.eventDetail` so the cover has the full `Event`.
    public var activeEvent: Event?

    /// Event being edited in the edit cover. Set before pushing `.editEvent`.
    public var activeEditEvent: Event?

    /// QR scanner coordinator. Set before pushing `.scanner`.
    public var activeScannerCoordinator: CheckInScannerCoordinator?

    /// Member directory snapshot — used by `VoteOnAppealSheet` (appellant
    /// name) and `ruleEditSheet` (currentMember governance check).
    public var memberDirectory: [UUID: MemberWithProfile] = [:]

    /// Calendar export service instance reused across event detail openings.
    public var calendarService: CalendarExportService = CalendarExportService()

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

/// Tab inventory matching `AppShell.md` canonical 5-tab layout.
/// Pass 2 renames .group → .inbox and .decisions → .activity.
public enum RootTab: String, Sendable, Hashable, CaseIterable {
    case home
    case inbox
    case create
    case activity
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
    case eventDetail(UUID)      // event.id — full Event in state.activeEvent; Pass 2 may polymorphize
    case editEvent              // full Event in state.activeEditEvent
    case fineDetail(UUID)       // fine.id
    case ruleEdit(RuleEditRouteContext)
    case voteDetail(VoteDetailRouteContext)
    case openVotes(OpenVotesRouteContext)
    case voteOnAppeal(AppealRouteContext)
    case scanner(UUID)          // event.id — full coord in state.activeScannerCoordinator
    case past
    case feed
    case groupHistory
    case acuerdos
    case sanciones
    case createVotePicker
    case createGeneralProposal
    case createRuleChange(GroupRule?)
    case settings               // SettingsSheet (global account settings)
    case editProfile            // EditProfileSheet (profile editor)
    case members                // EditMembersSheet (group member management)
}
