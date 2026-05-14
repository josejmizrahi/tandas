import SwiftUI
import RuulCore
import RuulUI

/// Adds the active-group switcher pill as the navigation bar's
/// `.principal` toolbar item. Tap routes to
/// `RootRouter.openGroupSwitcher()` which presents `GroupSwitcherSheet`.
///
/// Apply via `.groupSwitcherToolbar()` to the root content of any tab
/// that wants the switcher as chrome (Inbox, Activity). Home renders
/// its own prominent inline header (Apple Sports style) so it does NOT
/// apply this modifier. Profile is cross-group, so it never gets one.
///
/// Why a toolbar item (not a `VStack` header above the TabView):
/// - integrates with iOS 26 `tabBarMinimizeBehavior(.onScrollDown)` and
///   the Liquid Glass scroll edge
/// - push navigation correctly replaces the principal item with the
///   pushed screen's title (no doubled chrome)
/// - per-tab opt-in keeps Profile naturally empty
public struct GroupSwitcherToolbarModifier: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router

    public func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .principal) {
                if let group = app.activeGroup {
                    RuulGroupSwitcher(
                        activeGroupName: group.name,
                        activeCategory: group.category,
                        activeInitials: nil,
                        onTap: { router.openGroupSwitcher() }
                    )
                }
            }
        }
    }
}

public extension View {
    /// Mounts the active-group switcher pill as the `.principal`
    /// navigation-bar toolbar item. See `GroupSwitcherToolbarModifier`
    /// for the design rationale and per-tab opt-in policy.
    func groupSwitcherToolbar() -> some View {
        modifier(GroupSwitcherToolbarModifier())
    }
}
