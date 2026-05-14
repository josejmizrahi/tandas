import SwiftUI
import RuulCore

/// Thin tab wrapper for the Group hub. Embeds GroupTabView inside a
/// NavigationStack. Requires both `rulesCoordinator` and an active group
/// from AppState; shows a ProgressView placeholder while either is absent.
///
/// All navigation callbacks are no-op stubs for Pass 1 — they will be
/// wired to RootRouter actions when RootShell is assembled in Task 9.
@MainActor
public struct GroupTab: View {
    @Environment(AppState.self) private var app
    let rulesCoordinator: RulesCoordinator?
    let myFinesCoordinator: MyFinesCoordinator?
    let inboxCoordinator: InboxCoordinator?
    let homeCoordinator: HomeCoordinator?

    public init(
        rules: RulesCoordinator?,
        myFines: MyFinesCoordinator?,
        inbox: InboxCoordinator?,
        home: HomeCoordinator?
    ) {
        self.rulesCoordinator = rules
        self.myFinesCoordinator = myFines
        self.inboxCoordinator = inbox
        self.homeCoordinator = home
    }

    public var body: some View {
        NavigationStack {
            if let rulesCoord = rulesCoordinator,
               let group = app.activeGroup {
                GroupTabView(
                    activeGroup: group,
                    userId: app.session?.user.id ?? UUID(),
                    rulesCoordinator: rulesCoord,
                    myFinesCoordinator: myFinesCoordinator,
                    inboxCoordinator: inboxCoordinator,
                    upcomingEvents: homeCoordinator?.upcomingEvents ?? [],
                    myRSVPs: homeCoordinator?.myRSVPs ?? [:],
                    onSwitchGroup: {},
                    onOpenEvent: { _ in },
                    onOpenFine: { _ in },
                    onOpenInboxAction: { _ in },
                    onCreateResource: {},
                    onOpenAcuerdos: {},
                    onOpenDecisiones: {},
                    onOpenSanciones: {},
                    onOpenGroupRules: {}
                )
                .environment(app)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
