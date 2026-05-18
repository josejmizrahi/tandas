import Foundation

/// Typed namespace for the 35 capability identifiers declared by
/// `CapabilityCatalog`. Using these constants instead of raw string
/// literals lets the compiler catch typos in `caps.contains(...)`,
/// `attachedCapabilities: [...]`, `dependencies: [...]`, etc.
///
/// **Why this exists:** capability ids are flat strings at runtime
/// (resource_capabilities.capability_block_id is `text` in Postgres), but
/// every consumer in the iOS app had been gating on raw string literals.
/// One typo silently disabled a section without a compile error —
/// `caps.contains("rvsp")` evaluates to false forever. Per
/// Plans/Active/CleanupAudit_2026-05-18 §5 finding #4.
///
/// **Source of truth:** the `id` property of each `CapabilityBlock`
/// struct in `CapabilityCatalog.swift`. When a new capability ships,
/// add its constant here *and* register the block; the catalog's
/// integrity check (and tests) will catch drift between the two.
///
/// Pattern matches `RsvpAction.Status` (PlatformModels/RsvpAction.swift)
/// — caseless enum used as a namespace for typed string constants.
public enum CapabilityID {
    // MARK: - Event resource capabilities
    public static let rsvp           = "rsvp"
    public static let checkIn        = "check_in"
    public static let schedule       = "schedule"
    public static let recurrence     = "recurrence"
    public static let attendance     = "attendance"
    public static let deadline       = "deadline"
    public static let reminder       = "reminder"
    public static let description    = "description"
    public static let hostActions    = "host_actions"
    public static let location       = "location"
    public static let cancellation   = "cancellation"

    // MARK: - Money / governance
    public static let money          = "money"
    public static let ledger         = "ledger"
    public static let consequence    = "consequence"
    public static let rules          = "rules"
    public static let voting         = "voting"
    public static let approval       = "approval"
    public static let appeal         = "appeal"

    // MARK: - Rotation / assignment
    public static let rotation       = "rotation"
    public static let assignment     = "assignment"
    public static let participants   = "participants"
    public static let swap           = "swap"

    // MARK: - Asset capabilities
    public static let custody        = "custody"
    public static let maintenance    = "maintenance"
    public static let valuation      = "valuation"
    public static let transfer       = "transfer"
    public static let access         = "access"
    public static let delegation     = "delegation"
    public static let inventory      = "inventory"

    // MARK: - Space capabilities
    public static let capacity       = "capacity"
    public static let guestAccess    = "guest_access"
    public static let booking        = "booking"
    public static let expiration     = "expiration"

    // MARK: - Status / observability
    public static let status         = "status"
    public static let history        = "history"

    /// Every capability id declared above. Tests compare this against the
    /// catalog's registered blocks to detect drift in either direction.
    public static let all: Set<String> = [
        rsvp, checkIn, schedule, recurrence, attendance, deadline, reminder,
        description, hostActions, location, cancellation,
        money, ledger, consequence, rules, voting, approval, appeal,
        rotation, assignment, participants, swap,
        custody, maintenance, valuation, transfer, access, delegation, inventory,
        capacity, guestAccess, booking, expiration,
        status, history,
    ]
}
