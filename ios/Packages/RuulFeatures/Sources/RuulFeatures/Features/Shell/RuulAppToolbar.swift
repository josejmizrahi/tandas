import SwiftUI
import RuulCore
import RuulUI

/// Canonical toolbar chrome shared by every top-level tab (Home, Inbox,
/// Activity, Profile). Defines two of the three nav-bar slots so every
/// page reads the same way:
///
///   `.topBarLeading`  — active group avatar (tap → `GroupSwitcherSheet`)
///   `.principal`      — "ruul" wordmark (system 20pt bold)
///   `.topBarTrailing` — left empty; each view appends its own actions via
///                       a standard `.toolbar { ... }` modifier downstream.
///
/// Replaces the old `GroupSwitcherToolbarModifier` (which only set the
/// principal slot) and the per-page handmade headers (in-body title +
/// greeting + icon row, ~140pt) so every tab gets the same ~44pt nav bar
/// regardless of who renders it. Pushed destinations override the
/// principal/leading slots with their own title, so detail screens don't
/// accidentally inherit "ruul".
///
/// Apply on the view INSIDE each tab's `NavigationStack` — not on the
/// stack itself, so the toolbar is scoped to the root content only.
public struct RuulAppToolbarModifier: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router

    /// When false (Profile), the leading group avatar is hidden — Profile
    /// is cross-group and showing a group affordance there is misleading.
    let showsGroupAvatar: Bool

    public init(showsGroupAvatar: Bool = true) {
        self.showsGroupAvatar = showsGroupAvatar
    }

    public func body(content: Content) -> some View {
        content
            .toolbar {
                if showsGroupAvatar {
                    ToolbarItem(placement: .topBarLeading) {
                        if let group = app.activeGroup {
                            Button { router.openGroupSwitcher() } label: {
                                RuulGroupAvatar(group: group, size: .lg)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Cambiar grupo. Actual: \(group.name).")
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("ruul")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.ruulTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

public extension View {
    /// Mounts the canonical Ruul app toolbar (group avatar + "ruul"
    /// wordmark) on the receiver. Each caller appends its own trailing
    /// actions through a normal `.toolbar { ToolbarItem(placement:
    /// .topBarTrailing) { ... } }` modifier — SwiftUI composes them.
    ///
    /// Pass `showsGroupAvatar: false` on cross-group surfaces (Profile)
    /// so the leading slot stays empty.
    func ruulAppToolbar(showsGroupAvatar: Bool = true) -> some View {
        modifier(RuulAppToolbarModifier(showsGroupAvatar: showsGroupAvatar))
    }
}
