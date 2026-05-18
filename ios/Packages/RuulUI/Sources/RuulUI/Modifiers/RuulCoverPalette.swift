import SwiftUI

/// Stateless helpers around `RuulCoverCatalog` that pick a curated
/// cover from a UUID. UI-agnostic to the domain concept the UUID
/// represents — callers pass `group.id`, `resource.id`, `user.id`,
/// whatever; same UUID always lands on the same cover.
///
/// Per Plans/Active/CleanupAudit_2026-05-18 §01.2 §03 ("RuulUI extends
/// `RuulCore.Group`") — this file used to also declare
/// `extension RuulCore.Group { var ambientPalette: [Color] }`. That
/// extension was a doctrinal drift (the UI package reaching into the
/// domain to add behavior). It had zero call sites in either Features
/// or the app target — only the docs ever referenced it — so it was
/// deleted outright. Callers that need a per-group palette now write
/// `RuulCoverPalette.deterministicCover(for: group.id).palette`.
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
