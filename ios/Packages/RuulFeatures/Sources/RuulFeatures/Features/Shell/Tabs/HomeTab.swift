import SwiftUI
import RuulCore

/// Thin tab wrapper for Home. Embeds HomeView inside a NavigationStack.
/// Coordinators flow in from RootShell; when nil, shows a ProgressView
/// placeholder (bootstrap hasn't populated them yet).
///
/// All navigation callbacks are no-op stubs for Pass 1 — they will be
/// wired to RootRouter actions when RootShell is assembled in Task 9.
@MainActor
public struct HomeTab: View {
    @Environment(AppState.self) private var app
    let homeCoordinator: HomeCoordinator?
    let inboxCoordinator: InboxCoordinator?

    public init(home: HomeCoordinator?, inbox: InboxCoordinator?) {
        self.homeCoordinator = home
        self.inboxCoordinator = inbox
    }

    public var body: some View {
        NavigationStack {
            if let coord = homeCoordinator {
                HomeView(
                    coordinator: coord,
                    inboxCoordinator: inboxCoordinator,
                    onInboxActionTap: { _ in },
                    userId: app.session?.user.id ?? UUID(),
                    onCreateEvent: {},
                    onOpenEvent: { _ in },
                    onOpenPastEvents: {},
                    onInvitePeople: nil,
                    onSwitchGroup: {}
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
