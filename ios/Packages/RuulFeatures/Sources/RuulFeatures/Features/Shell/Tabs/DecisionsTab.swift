import SwiftUI
import RuulCore

/// Thin tab wrapper for Decisions (Rules). Embeds RulesView inside a
/// NavigationStack. `voteRepo`, `policyRepo`, and `userActionRepo` are
/// read directly from the AppState environment — they are already wired
/// at app boot, so this avoids threading them through RootShell.
///
/// Navigation callbacks are wired to RootRouter via @Environment injection.
/// `onSelectRule` drives a local navigationDestination push within this
/// stack (mirrors MainTabView behaviour — ruleDetailRoute is a nav push,
/// not a sheet).
@MainActor
public struct DecisionsTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    let rulesCoordinator: RulesCoordinator?

    @State private var ruleDetailRoute: GroupRule?

    public init(rules: RulesCoordinator?) {
        self.rulesCoordinator = rules
    }

    public var body: some View {
        NavigationStack {
            if let coord = rulesCoordinator,
               let group = app.activeGroup {
                RulesView(
                    coordinator: coord,
                    voteRepo: app.voteRepo,
                    policyRepo: app.policyRepo,
                    actorUserId: app.session?.user.id ?? UUID(),
                    userActionRepo: app.userActionRepo,
                    onSeeOpenVotes: {
                        router.openOpenVotes(OpenVotesRouteContext(id: group.id))
                    },
                    onSelectRule: { rule in ruleDetailRoute = rule }
                )
                .environment(app)
                .navigationDestination(item: $ruleDetailRoute) { rule in
                    RuleDetailView(
                        rule: rule,
                        canEditRules: coord.canEditRules,
                        onEdit: {
                            router.handleRuleChange(
                                rule: rule,
                                group: group,
                                proposedAmount: nil,
                                pendingActionId: nil
                            )
                        },
                        onProposeChange: {
                            router.openCreateRuleChange(initialRule: rule)
                        }
                    )
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
