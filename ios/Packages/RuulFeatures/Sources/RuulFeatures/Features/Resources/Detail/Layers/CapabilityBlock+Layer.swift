import RuulCore

/// Classification of `CapabilityBlock`s into Universal Resource Detail
/// layers (see `Plans/Active/Fase1ComponentMap.md` §"Universal Resource
/// Detail — layered architecture").
///
/// PR 3 of the layered rebuild introduces only the Participation
/// classification — the inline ForEach in `UniversalResourceDetailView`
/// renders everything not classified as participation, so coordination
/// blocks (`location`, `balance`, …) stay where they are until PR 4
/// extracts them into their own layer.
///
/// IDs come from the per-resource block builders
/// (`EventBlockBuilder`, `FundBlockBuilder`, …). Only IDs that exist
/// today appear in the whitelist; future participation blocks
/// (`members`, `custodians`, `beneficiaries`, …) extend this list when
/// their builders ship.
extension CapabilityBlock {
    /// True when the block answers "¿Quién está involucrado y cómo?"
    /// — event attendees + RSVP state, host rotation queue, future
    /// custody / beneficiary / membership lists.
    var belongsToParticipationLayer: Bool {
        switch id {
        case "rsvp", "rotation":
            return true
        default:
            return false
        }
    }
}
