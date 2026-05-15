import SwiftUI
import RuulCore

public extension RuulCore.Group {
    /// 9-stop ambient palette for this group's screens. Picks one of the
    /// `RuulCoverCatalog` curated covers deterministically from the
    /// group's UUID — same group always gets the same palette, but two
    /// groups in the same `category` get different colors.
    ///
    /// Doctrine: each group "wears its own color" the way Luma events
    /// each have their own cover. Category drives semantic chrome
    /// elsewhere (the avatar ring, the type chip) but the ambient is a
    /// per-group identifier, not a per-category one.
    ///
    /// Use as the canonical "what color is this group?" answer for any
    /// screen scoped to a single group (Home, Inbox, History, Profile
    /// in a group context, etc.). Resource detail screens still derive
    /// from the resource's own cover when set — see
    /// `ResourceAmbientPalette` in RuulFeatures.
    var ambientPalette: [Color] {
        RuulCoverPalette.deterministicCover(for: id).palette
    }
}

/// Stateless helpers around `RuulCoverCatalog` that pick a curated
/// cover from a UUID. Pulled out of the `Group` extension so other
/// UUID-keyed entities (resources without their own cover, users for
/// color-coding, etc.) can derive consistent palettes from the same
/// seed function.
public enum RuulCoverPalette {
    /// Deterministic cover lookup: sums the UUID's 16 raw bytes
    /// (cheap, stable, no Hashable randomization) and maps the sum
    /// into the catalog index. Two UUIDs that differ by even one byte
    /// land on different covers; the same UUID always lands on the
    /// same cover across launches.
    public static func deterministicCover(for id: UUID) -> RuulCover {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        let catalog = RuulCoverCatalog.all
        let idx = abs(sum) % catalog.count
        return catalog[idx]
    }
}
