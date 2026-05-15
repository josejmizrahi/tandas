import SwiftUI
import RuulCore
import RuulUI

/// Resolves the ambient color palette for a resource's detail screen.
/// The palette drives the full-screen tint behind everything else
/// (Luma signature: every event "wears its cover" across the whole
/// view, not just inside the cover card).
///
/// Resolution order:
///   1. If `resource.metadata.cover_image_name` matches a curated cover
///      in `RuulCoverCatalog`, use that cover's 9-color palette.
///   2. Otherwise, derive from the group's category ramp — three
///      stops (background / accent / foreground) tiled across the
///      gradient so each category still feels distinct.
///
/// The blur in `RuulAmbientBackground` smooths whichever input we
/// hand it into a continuous color field; banding is not a concern.
@MainActor
enum ResourceAmbientPalette {
    static func resolve(for context: ResourceDetailContext) -> [Color] {
        if let name = context.coverImageName,
           let cover = RuulCoverCatalog.all.first(where: { $0.id == name }) {
            return cover.palette
        }
        let ramp = context.group.category.ramp
        // Tile the 3 ramp stops across the mesh. Accent shows up
        // twice so it carries more of the visual weight — matches
        // the cover hero's MeshGradient layout.
        return [
            ramp.background,
            ramp.accent,
            ramp.foreground,
            ramp.accent,
            ramp.background,
            ramp.foreground,
            ramp.accent,
            ramp.foreground,
            ramp.accent
        ]
    }
}
