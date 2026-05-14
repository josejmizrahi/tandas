import SwiftUI
import RuulCore

/// Thin tab wrapper for Decisions (Rules). Embeds RulesView inside a
/// NavigationStack. `voteRepo`, `policyRepo`, and `userActionRepo` are
/// read directly from the AppState environment — they are already wired
/// at app boot, so this avoids threading them through RootShell.
///
/// All navigation callbacks are no-op stubs for Pass 1 — they will be
/// wired to RootRouter actions when RootShell is assembled in Task 9.
@MainActor
public struct DecisionsTab: View {
    @Environment(AppState.self) private var app
    let rulesCoordinator: RulesCoordinator?

    public init(rules: RulesCoordinator?) {
        self.rulesCoordinator = rules
    }

    public var body: some View {
        NavigationStack {
            if let coord = rulesCoordinator {
                RulesView(
                    coordinator: coord,
                    voteRepo: app.voteRepo,
                    policyRepo: app.policyRepo,
                    actorUserId: app.session?.user.id ?? UUID(),
                    userActionRepo: app.userActionRepo,
                    onSeeOpenVotes: {},
                    onSelectRule: { _ in }
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
