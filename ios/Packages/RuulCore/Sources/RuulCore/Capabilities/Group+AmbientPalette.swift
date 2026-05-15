import SwiftUI

public extension Group {
    /// 9-stop ambient palette derived from the group's category ramp.
    /// Tile the 3 semantic stops (background / accent / foreground) so
    /// the receiver — typically `.ruulAmbientScreen(palette:)` — has
    /// enough colors to fill a 3×3 MeshGradient without padding logic
    /// in the call site.
    ///
    /// Use as the canonical "what color is this group?" answer for any
    /// screen scoped to a single group (Home, Inbox, History, Profile
    /// in a group context, etc.). Resource detail screens derive a
    /// palette from the resource's cover instead — see
    /// `ResourceAmbientPalette` in RuulFeatures.
    var ambientPalette: [Color] {
        let ramp = category.ramp
        return [
            ramp.background, ramp.accent,     ramp.foreground,
            ramp.accent,     ramp.background, ramp.foreground,
            ramp.accent,     ramp.foreground, ramp.accent
        ]
    }
}
