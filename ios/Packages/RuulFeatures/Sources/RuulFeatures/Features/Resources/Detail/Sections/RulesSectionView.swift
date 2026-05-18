import SwiftUI
import RuulUI
import RuulCore

/// Rules section rendered inline inside the resource detail's Reglas
/// tab. Owns a `ResourceRulesCoordinator` (built on first appear from
/// `AppState`'s `ruleRepo` + `ruleShapeRegistry`) and renders the same
/// `ResourceRulesBody` the `ResourceRulesSheet` uses — so the user
/// sees the rules list directly, no row-→-sheet bounce.
///
/// The catalog `render` closure returns this view, which then attaches
/// to `@Environment(AppState.self)` from the SwiftUI graph. The outer
/// `ResourceDetailSheet` already injects `app` + `router` on the
/// fullScreenCover so the environment lookup succeeds.
public struct RulesSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "rules",
        priority: 800,
        tabId: "rules",
        isEnabledFor: { caps in caps.contains("rules") },
        render: { ctx in AnyView(RulesSectionView(context: ctx)) }
    )

    public var body: some View {
        InlineRulesContent(context: context)
    }
}

@MainActor
private struct InlineRulesContent: View {
    let context: ResourceDetailContext
    @Environment(AppState.self) private var app
    /// Lazy-built coordinator. Held as @State so it survives tab
    /// switches inside the detail (Reglas tab → otra tab → Reglas
    /// tab) — the loaded rules don't refetch on every visit.
    @State private var coordinator: ResourceRulesCoordinator?

    var body: some View {
        Group {
            if let coordinator {
                ResourceRulesBody(coordinator: coordinator)
            } else {
                RuulLoadingState()
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .onAppear {
            if coordinator == nil {
                coordinator = makeCoordinator()
            }
        }
    }

    private func makeCoordinator() -> ResourceRulesCoordinator {
        let ctx = ResourceRuleContext(
            groupId: context.group.id,
            resourceId: context.resource.id,
            resourceType: context.resource.resourceType.rawString,
            displayName: context.displayName,
            canCreate: canCreateRules
        )
        return ResourceRulesCoordinator(
            context: ctx,
            ruleRepo: app.ruleRepo,
            shapeRegistry: app.ruleShapeRegistry
        )
    }

    /// Mirrors `ResourceDetailSheet.canCreateRules`. Founders / admins
    /// + any custom role with `.modifyRules` qualify; everyone else is
    /// read-only. Server still gates the write at the RPC level.
    private var canCreateRules: Bool {
        guard let userId = context.currentUserId,
              let me = context.memberDirectory[userId]?.member else { return false }
        let catalog = context.group.effectiveRoles
        for raw in me.rawRoles {
            if let def = catalog[raw], def.grants(.modifyRules) { return true }
        }
        return false
    }
}
