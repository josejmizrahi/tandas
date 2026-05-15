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
///   2. Otherwise, pick a curated cover deterministically from the
///      resource's UUID via `RuulCoverPalette.deterministicCover` —
///      same resource always gets the same palette, but two resources
///      without an explicit cover get different colors.
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
        return RuulCoverPalette.deterministicCover(for: context.resource.id).palette
    }
}
