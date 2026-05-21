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

    /// Sub-category inside the Coordination layer per the universal
    /// block grammar. Drives the renderer the layer will pick in a
    /// follow-up PR (MoneyBlock / ScheduleBlock / AccessBlock /
    /// RulesBlock / ResponsibilityBlock / UsageBlock). PR 4 only
    /// classifies — the layer renders every kind through the existing
    /// `CapabilityBlockView` until the primitives ship.
    enum CoordinationKind {
        /// Balance, contributions, expenses, distributions, settlements.
        case money
        /// Dates, recurrence, rotations, reservations.
        case schedule
        /// Location, availability, bookings, ticketing.
        case access
        /// Active rules, votes, agreements, limits.
        case rules
        /// Custody, ownership, host assignment, maintenance.
        case responsibility
        /// Check-ins, occupancy, asset usage logs.
        case usage
        /// Not yet classified. Renders through the existing
        /// `CapabilityBlockView` until a future PR maps it.
        case other
    }

    /// Maps known block IDs to their Coordination sub-category. IDs
    /// that today live in the Participation layer return `.other`
    /// since `coordinationKind` is only meaningful for the residual
    /// the Participation filter leaves behind.
    var coordinationKind: CoordinationKind {
        switch id {
        case "balance":  return .money
        case "location": return .access
        // Future: "schedule"/"recurrence" → .schedule
        //         "rules" → .rules
        //         "custody"/"owner" → .responsibility
        //         "check_ins"/"usage" → .usage
        default:         return .other
        }
    }
}
