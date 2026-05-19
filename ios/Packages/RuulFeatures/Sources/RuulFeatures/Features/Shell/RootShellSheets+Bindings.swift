import SwiftUI
import RuulCore

/// `Binding` adapters that translate `RouterState.activeRoutes` into the
/// shapes SwiftUI's `.sheet(item:)` / `.fullScreenCover(item:)` /
/// `.sheet(isPresented:)` modifiers expect. One per route case the
/// shell presents.
///
/// Extracted from `RootShellSheets.swift` 2026-05-18 per
/// Plans/Active/CleanupAudit_2026-05-18/01_architecture.md §3.
/// Members lose `private` (now module-internal) since Swift extensions
/// across files can't share `private` scope.
extension RootShellSheets {

    func boolBinding(for route: RootRoute) -> Binding<Bool> {
        Binding(
            get: { router.state.contains(route) },
            set: { wantsPresent in
                if wantsPresent {
                    if !router.state.contains(route) { router.present(route) }
                } else {
                    while router.state.contains(route) { router.state.dismissTop() }
                }
            }
        )
    }

    func itemBinding<Payload: Hashable>(
        extract: @escaping (RootRoute) -> Payload?,
        matches: @escaping (RootRoute) -> Bool
    ) -> Binding<Payload?> {
        Binding(
            get: { router.state.activeRoutes.compactMap(extract).last },
            set: { newValue in
                if newValue == nil {
                    while router.state.activeRoutes.contains(where: matches) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    // MARK: - Per-case item bindings

    var ruleEditItem: Binding<RuleEditRouteContext?> {
        itemBinding(
            extract: { route in
                if case .ruleEdit(let ctx) = route { return ctx } else { return nil }
            },
            matches: { route in
                if case .ruleEdit = route { return true } else { return false }
            }
        )
    }

    var appealItem: Binding<AppealRouteContext?> {
        itemBinding(
            extract: { route in
                if case .voteOnAppeal(let ctx) = route { return ctx } else { return nil }
            },
            matches: { route in
                if case .voteOnAppeal = route { return true } else { return false }
            }
        )
    }

    /// Binding that drives the event detail cover via `state.activeEvent`.
    /// Using an `IdentifiableEventWrapper` so `fullScreenCover(item:)` can
    /// detect identity changes when a different event is opened.
    var activeEventItem: Binding<IdentifiableEventWrapper?> {
        Binding(
            get: {
                guard router.state.activeRoutes.contains(where: { if case .eventDetail = $0 { return true }; return false }),
                      let event = router.state.activeEvent else { return nil }
                return IdentifiableEventWrapper(event: event)
            },
            set: { newValue in
                if newValue == nil {
                    router.state.activeEvent = nil
                    while router.state.activeRoutes.contains(where: { if case .eventDetail = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    /// Binding for the polymorphic resource detail cover. Mirrors
    /// `activeEventItem` but for `ResourceRow` (fund/asset/space/
    /// slot/right) routed via `RootRoute.resourceDetail`.
    var activeResourceItem: Binding<IdentifiableResourceWrapper?> {
        Binding(
            get: {
                guard router.state.activeRoutes.contains(where: { if case .resourceDetail = $0 { return true }; return false }),
                      let row = router.state.activeResource else { return nil }
                return IdentifiableResourceWrapper(resource: row)
            },
            set: { newValue in
                if newValue == nil {
                    router.state.activeResource = nil
                    while router.state.activeRoutes.contains(where: { if case .resourceDetail = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    var activeEditEventItem: Binding<IdentifiableEventWrapper?> {
        Binding(
            get: {
                guard router.state.contains(.editEvent),
                      let event = router.state.activeEditEvent else { return nil }
                return IdentifiableEventWrapper(event: event)
            },
            set: { newValue in
                if newValue == nil {
                    router.state.activeEditEvent = nil
                    while router.state.contains(.editEvent) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    var activeScannerItem: Binding<IdentifiableScannerWrapper?> {
        Binding(
            get: {
                guard router.state.activeRoutes.contains(where: { if case .scanner = $0 { return true }; return false }),
                      let coord = router.state.activeScannerCoordinator else { return nil }
                return IdentifiableScannerWrapper(coordinator: coord)
            },
            set: { newValue in
                if newValue == nil {
                    router.state.activeScannerCoordinator = nil
                    while router.state.activeRoutes.contains(where: { if case .scanner = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    /// Binding for the fine detail cover, driven by `state.activeFine`
    /// (parallels `activeEventItem`). Returns nil when no `.fineDetail`
    /// route is active or `activeFine` isn't populated, which keeps the
    /// pure-id push path (`router.openFineDetail(id:)`, currently unused
    /// outside deep links) a no-op until callers also set the model.
    var activeFineItem: Binding<IdentifiableFineWrapper?> {
        Binding(
            get: {
                guard router.state.activeRoutes.contains(where: {
                    if case .fineDetail = $0 { return true }
                    return false
                }), let fine = router.state.activeFine else { return nil }
                return IdentifiableFineWrapper(fine: fine)
            },
            set: { newValue in
                if newValue == nil {
                    router.state.activeFine = nil
                    while router.state.activeRoutes.contains(where: {
                        if case .fineDetail = $0 { return true }
                        return false
                    }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    var voteDetailItem: Binding<VoteDetailRouteContext?> {
        itemBinding(
            extract: { route in
                if case .voteDetail(let ctx) = route { return ctx } else { return nil }
            },
            matches: { route in
                if case .voteDetail = route { return true } else { return false }
            }
        )
    }

    /// Binding for the appeal presented state (used by `VoteOnAppealSheet`
    /// which takes a `Binding<Bool>` rather than `item:`).
    var appealPresentedBinding: Binding<Bool> {
        Binding(
            get: { router.state.activeRoutes.contains(where: { if case .voteOnAppeal = $0 { return true }; return false }) },
            set: { isPresented in
                if !isPresented {
                    while router.state.activeRoutes.contains(where: { if case .voteOnAppeal = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }

    /// Item binding for `.createRuleChange(GroupRule?)`. Wraps the optional
    /// rule in an `IdentifiableRuleChangeWrapper` so `sheet(item:)` works.
    var createRuleChangeItem: Binding<IdentifiableRuleChangeWrapper?> {
        Binding(
            get: {
                guard let match = router.state.activeRoutes.last(where: { if case .createRuleChange = $0 { return true }; return false }) else { return nil }
                if case .createRuleChange(let rule) = match {
                    return IdentifiableRuleChangeWrapper(rule: rule)
                }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    while router.state.activeRoutes.contains(where: { if case .createRuleChange = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            }
        )
    }
}
