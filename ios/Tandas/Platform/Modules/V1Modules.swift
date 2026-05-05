import Foundation

/// V1 platform modules. Each is a static `GroupModule` declaring what it
/// provides + what it depends on. Loaded by `ModuleRegistry` at app boot.
///
/// `providedRules` lists the canonical rule names from the
/// `recurring_dinner` template (migration 00021). Used by the rule engine
/// to know which module a rule belongs to (for analytics + future
/// per-module enable/disable toggles).
///
/// `providedSystemEventTypes` lists ONLY events the platform actually emits
/// today via this module's flows. Future events (e.g. fine_proposed,
/// rotation_advanced) are added when the corresponding emitter ships.

extension GroupModule {

    /// Monetary fines triggered by rule violations. Core V1 module — most
    /// rules in the dinner template are part of this module.
    static let basicFines = GroupModule(
        id: "basic_fines",
        name: "Multas básicas",
        description: "Multas monetarias automáticas por reglas violadas: llegar tarde, no avisar, no presentarse.",
        providedRules: [
            "Llegada tardía",
            "No confirmó a tiempo",
            "Cancelación mismo día",
            "No se presentó",
            "Anfitrión sin descripción",
        ],
        providedResourceTypes: [],
        providedSystemEventTypes: [
            .fineOfficialized,
            .finePaid,
            .appealCreated,
            .appealResolved,
        ],
        providedTabs: [],
        dependencies: ["rsvp", "check_in"],
        conflictsWith: []
    )

    /// Rotating host assignment. Maintains a turn order across members
    /// and advances on event close.
    static let rotatingHost = GroupModule(
        id: "rotating_host",
        name: "Host rotativo",
        description: "El rol de host rota entre miembros automáticamente al cerrar cada evento.",
        providedRules: [],
        providedResourceTypes: [],
        providedSystemEventTypes: [
            .positionChanged,
        ],
        providedTabs: [],
        dependencies: [],
        conflictsWith: []
    )

    /// RSVP system: members respond to events (going / maybe / declined /
    /// pending / waitlisted). Core V1 module.
    static let rsvp = GroupModule(
        id: "rsvp",
        name: "RSVP",
        description: "Respuestas de asistencia: voy, tal vez, no voy. Auto-creadas al crearse un evento.",
        providedRules: [],
        providedResourceTypes: [],
        providedSystemEventTypes: [
            .rsvpSubmitted,
            .rsvpChangedSameDay,
            .rsvpDeadlinePassed,
        ],
        providedTabs: [],
        dependencies: [],
        conflictsWith: []
    )

    /// Check-in: members mark arrival at events (self, manual, or QR).
    /// Drives the `Llegada tardía` rule.
    static let checkIn = GroupModule(
        id: "check_in",
        name: "Check-in",
        description: "Registro de llegada al evento: self check-in, manual o QR. Habilita reglas de tardanza.",
        providedRules: [],
        providedResourceTypes: [],
        providedSystemEventTypes: [
            .checkInRecorded,
            .checkInMissed,
        ],
        providedTabs: [],
        dependencies: ["rsvp"],
        conflictsWith: []
    )

    /// Appeal voting: when a member appeals a fine, group votes whether
    /// to cancel it. Built on the generic Vote primitive (Bloque 4).
    static let appealVoting = GroupModule(
        id: "appeal_voting",
        name: "Apelación con votación",
        description: "Si un miembro apela una multa, el grupo vota anónimamente si cancelarla.",
        providedRules: [],
        providedResourceTypes: [],
        providedSystemEventTypes: [
            .voteOpened,
            .voteCast,
            .voteResolved,
        ],
        providedTabs: [],
        dependencies: ["basic_fines"],
        conflictsWith: []
    )
}
