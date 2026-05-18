import Foundation

/// V1 platform modules. Each is a static `GroupModule` declaring what it
/// provides + what it depends on. Loaded by `ModuleRegistry` at app boot.
///
/// `providedRules` lists the canonical **stable slugs** of the rules this
/// module ships (template-rule slugs, e.g. `dinner_late_arrival`). The
/// slug survives display rename + i18n, so the link remains valid even
/// when the rule's `name` is edited per-group.
/// Used by the rule engine to know which module a rule belongs to (for
/// analytics + future per-module enable/disable toggles).
///
/// `providedSystemEventTypes` lists ONLY events the platform actually emits
/// today via this module's flows. Future events (e.g. fine_proposed,
/// rotation_advanced) are added when the corresponding emitter ships.

public extension GroupModule {

    /// Monetary fines triggered by rule violations. Core V1 module — most
    /// rules in the dinner template are part of this module.
    public static let basicFines = GroupModule(
        id: "basic_fines",
        name: "Multas básicas",
        description: "Multas monetarias automáticas por reglas violadas: llegar tarde, no avisar, no presentarse.",
        providedRules: [
            DinnerRecurringTemplate.RuleSlug.lateArrival,
            DinnerRecurringTemplate.RuleSlug.noResponse,
            DinnerRecurringTemplate.RuleSlug.sameDayCancel,
            DinnerRecurringTemplate.RuleSlug.noShow,
            DinnerRecurringTemplate.RuleSlug.hostNoMenu,
        ],
        providedSystemEventTypes: [
            .fineOfficialized,
            .finePaid,
            .appealCreated,
            .appealResolved,
        ],
        providedTabs: [],
        providedCapabilityBlocks: [CapabilityID.rules, CapabilityID.consequence, CapabilityID.ledger],
        dependencies: ["rsvp", "check_in"],
        conflictsWith: []
    )

    /// Rotating host assignment. Maintains a turn order across members
    /// and advances on event close.
    public static let rotatingHost = GroupModule(
        id: "rotating_host",
        name: "Host rotativo",
        description: "El rol de host rota entre miembros automáticamente al cerrar cada evento.",
        providedRules: [],
        providedSystemEventTypes: [
            .positionChanged,
        ],
        providedTabs: [],
        providedCapabilityBlocks: [CapabilityID.rotation, CapabilityID.assignment],
        dependencies: [],
        conflictsWith: []
    )

    /// RSVP system: members respond to events (going / maybe / declined /
    /// pending / waitlisted). Core V1 module.
    public static let rsvp = GroupModule(
        id: "rsvp",
        name: "RSVP",
        description: "Respuestas de asistencia: voy, tal vez, no voy. Auto-creadas al crearse un evento.",
        providedRules: [],
        providedSystemEventTypes: [
            .rsvpSubmitted,
            .rsvpChangedSameDay,
            .rsvpDeadlinePassed,
        ],
        providedTabs: [],
        providedCapabilityBlocks: [CapabilityID.rsvp, CapabilityID.attendance, CapabilityID.deadline],
        dependencies: [],
        conflictsWith: []
    )

    /// Check-in: members mark arrival at events (self, manual, or QR).
    /// Drives the `dinner_late_arrival` rule.
    public static let checkIn = GroupModule(
        id: "check_in",
        name: "Check-in",
        description: "Registro de llegada al evento: self check-in, manual o QR. Habilita reglas de tardanza.",
        providedRules: [],
        providedSystemEventTypes: [
            .checkInRecorded,
            .checkInMissed,
        ],
        providedTabs: [],
        providedCapabilityBlocks: [CapabilityID.checkIn, CapabilityID.attendance],
        dependencies: ["rsvp"],
        conflictsWith: []
    )

    /// Appeal voting: when a member appeals a fine, group votes whether
    /// to cancel it. Built on the generic Vote primitive (Bloque 4).
    public static let appealVoting = GroupModule(
        id: "appeal_voting",
        name: "Apelación con votación",
        description: "Si un miembro apela una multa, el grupo vota anónimamente si cancelarla.",
        providedRules: [],
        providedSystemEventTypes: [
            .voteOpened,
            .voteCast,
            .voteResolved,
        ],
        providedTabs: [],
        providedCapabilityBlocks: [CapabilityID.appeal, CapabilityID.voting, CapabilityID.consequence],
        dependencies: ["basic_fines"],
        conflictsWith: []
    )
}
