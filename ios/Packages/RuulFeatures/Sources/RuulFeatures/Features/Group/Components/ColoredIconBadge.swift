import SwiftUI
import RuulUI

/// Feature-layer helper for the "leading circle badge with a colored
/// SF Symbol" pattern that repeats across the group's subscreen rows
/// (`GroupFundsListView`, `GroupAssetsListView`, `GroupBalancesView`).
/// Centralises the 36×36 circle size + 12% tint background so changing
/// the badge shape later happens in one place instead of three.
///
/// NOT a RuulUI primitive — the design system is in DELETE mode per
/// `feedback_dont_touch_ruului_base.md`. This is a feature-internal
/// composition that the group rows are the only consumers of. If a
/// third surface (outside Features/Group) ever needs the same badge,
/// promote it then.
@MainActor
struct ColoredIconBadge: View {
    let systemName: String
    let tint: Color

    /// Apple-canonical badge size — matches Settings/Mail compact
    /// row icons. Kept as an internal constant rather than a free
    /// magic number so future "make all badges 32" tweaks stay
    /// centralized to this file.
    private static let size: CGFloat = 36
    /// Tint background opacity — calibrated against the system
    /// `Color.ruulSurface` so the symbol reads without overpowering
    /// the row.
    private static let tintOpacity: Double = 0.12

    var body: some View {
        Image(systemName: systemName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: Self.size, height: Self.size)
            .background(tint.opacity(Self.tintOpacity), in: Circle())
    }
}
