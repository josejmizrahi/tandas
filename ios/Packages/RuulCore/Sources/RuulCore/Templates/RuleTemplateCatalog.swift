import Foundation

/// Static catalog of Beta-1 rule templates + the trigger→resource_type
/// map the mock uses to filter `loadTemplates(forResourceType:)`.
///
/// **Why this file exists:** the catalog data (19 `RuleBuilderTemplate`
/// literals + the trigger map) used to live inside
/// `Repositories/RuleTemplateRepository.swift`. That file was 767 LOC, ~70%
/// of which was catalog data — repo transport plumbing was lost in the
/// noise. A designer iterating on template copy ended up editing a
/// transport file. Per Plans/Active/CleanupAudit_2026-05-18 §04.3 the
/// data layer was extracted here; the repo file shrinks to ~200 LOC of
/// pure CRUD + RPC.
///
/// **Source of truth:** mig 00171 (Beta-1 seed) + mig 00227 (asset rule
/// templates) + mig 00272 (space rule templates). Mock previews/tests
/// render from this catalog; live behavior is enforced server-side.
public enum RuleTemplateCatalog {

    /// Static mirror of `rule_shapes.valid_resource_types` used by the
    /// Mock to filter `loadTemplates(forResourceType:)` the same way the
    /// server does. Kept in sync by hand — diverges only when a new
    /// trigger lands in rule_shapes; add the entry here so previews
    /// match prod.
    public static let triggerResourceTypes: [String: [String]] = [
        "checkInRecorded":      ["event"],
        "eventClosed":          ["event"],
        "eventStarted":         ["event"],
        "eventCancelled":       ["event"],
        "eventUpdated":         ["event"],
        "hoursBeforeEvent":     ["event"],
        "rsvpDeadlinePassed":   ["event"],
        "rsvpChangedSameDay":   ["event"],
        "ledgerEntryCreated":   ["event", "fund"],
        "assetTransferred":     ["asset"],
        "checkoutOverdue":      ["asset"],
        "damageReported":       ["asset"],
        "maintenanceOverdue":   ["asset"],
        "rightExpiringSoon":    ["right"],
    ]

    /// Seed catalog mirroring mig 00171 (5 attendance) + mig 00227 (5
    /// asset) + mig 00272 (7 space) + 2 money templates. Lets previews
    /// and tests render the gallery without round-tripping to Supabase.
    public static let defaults: [RuleBuilderTemplate] = [
        RuleBuilderTemplate(
            id: "late_arrival_fine",
            displayNameES: "Multa por llegar tarde",
            descriptionES: "Cobra una multa cuando un miembro llega tarde a un evento (después de X minutos).",
            category: "attendance",
            templateKind: "penalty",
            requiredCapabilities: ["check_in", "fines"],
            defaultParams: .object(["amount": .int(200), "minutes": .int(15)]),
            composition: .init(
                triggerShapeId: "checkInRecorded",
                conditionShapeIds: ["checkInMinutesLate"],
                consequenceShapeIds: ["fine"],
                scopeHint: RuleScope.series
            ),
            sortOrder: 10
        ),
        RuleBuilderTemplate(
            id: "no_show_fine",
            displayNameES: "Multa por no asistir",
            descriptionES: "Cobra una multa a los miembros que no hicieron check-in cuando el evento se cierra.",
            category: "attendance",
            templateKind: "penalty",
            requiredCapabilities: ["rsvp", "check_in", "fines"],
            defaultParams: .object(["amount": .int(300)]),
            composition: .init(
                triggerShapeId: "eventClosed",
                conditionShapeIds: ["alwaysTrue"],
                consequenceShapeIds: ["fine"],
                scopeHint: RuleScope.series
            ),
            sortOrder: 20
        ),
        RuleBuilderTemplate(
            id: "same_day_cancel_fine",
            displayNameES: "Multa por cancelar el mismo día",
            descriptionES: "Cobra una multa cuando un miembro cambia su RSVP a \"no voy\" el mismo día del evento.",
            category: "attendance",
            templateKind: "penalty",
            requiredCapabilities: ["rsvp", "fines"],
            defaultParams: .object(["amount": .int(250)]),
            composition: .init(
                triggerShapeId: "rsvpChangedSameDay",
                conditionShapeIds: ["alwaysTrue"],
                consequenceShapeIds: ["fine"],
                scopeHint: RuleScope.series
            ),
            sortOrder: 30
        ),
        RuleBuilderTemplate(
            id: "no_rsvp_fine",
            displayNameES: "Multa por no responder a tiempo",
            descriptionES: "Cobra una multa a quien no haya respondido al RSVP antes de la fecha límite.",
            category: "attendance",
            templateKind: "penalty",
            requiredCapabilities: ["rsvp", "fines"],
            defaultParams: .object(["amount": .int(150)]),
            composition: .init(
                triggerShapeId: "rsvpDeadlinePassed",
                conditionShapeIds: ["alwaysTrue"],
                consequenceShapeIds: ["fine"],
                scopeHint: RuleScope.series
            ),
            sortOrder: 40
        ),
        RuleBuilderTemplate(
            id: "host_no_menu_fine",
            displayNameES: "Multa al anfitrión si no propone menú",
            descriptionES: "Cobra una multa al anfitrión si no ha comunicado el plan 24h antes del evento.",
            category: "attendance",
            templateKind: "penalty",
            requiredCapabilities: ["rotating_host", "fines"],
            defaultParams: .object(["amount": .int(100), "hours": .int(24)]),
            composition: .init(
                triggerShapeId: "hoursBeforeEvent",
                conditionShapeIds: ["alwaysTrue"],
                consequenceShapeIds: ["fine"],
                scopeHint: RuleScope.series
            ),
            sortOrder: 50
        ),
        RuleBuilderTemplate(
            id: "expense_threshold_warning",
            displayNameES: "Aviso por gasto grande",
            descriptionES: "Cuando alguien registre un movimiento de dinero mayor a X pesos, el grupo recibe un aviso en la actividad. Útil para que los administradores vean gastos grandes sin tener que pedir aprobación previa.",
            category: "money",
            templateKind: "governance",
            requiredCapabilities: ["ledger"],
            defaultParams: .object(["threshold_cents": .int(200_000)]),
            composition: .init(
                triggerShapeId: "ledgerEntryCreated",
                conditionShapeIds: ["amountAbove"],
                consequenceShapeIds: ["emitWarning"],
                scopeHint: RuleScope.group
            ),
            sortOrder: 60
        ),
        RuleBuilderTemplate(
            id: "expense_threshold_vote",
            displayNameES: "Voto por gasto grande",
            descriptionES: "Cuando alguien registre un movimiento de dinero mayor a X pesos, se abre automáticamente una votación. Si el grupo la rechaza, el gasto se reversa con un reembolso automático.",
            category: "money",
            templateKind: "governance",
            requiredCapabilities: ["ledger", "voting"],
            defaultParams: .object([
                "threshold_cents":   .int(500_000),
                "duration_hours":    .int(48),
                "quorum_percent":    .int(50),
                "threshold_percent": .int(50),
            ]),
            composition: .init(
                triggerShapeId: "ledgerEntryCreated",
                conditionShapeIds: ["amountAbove"],
                consequenceShapeIds: ["startVote"],
                scopeHint: RuleScope.group
            ),
            sortOrder: 70
        ),

        // MARK: - Asset rule templates (mig 00227 — Plans/Active/AssetRules.md §1)

        RuleBuilderTemplate(
            id: "damage_approval_required",
            displayNameES: "Daño grande requiere aprobación",
            descriptionES: "Si alguien reporta un daño con costo estimado mayor a $X, se crea una acción pendiente para que un admin apruebe el siguiente paso.",
            category: "assets",
            templateKind: "governance",
            requiredCapabilities: ["maintenance"],
            defaultParams: .object(["threshold_cents": .int(500_000)]),
            composition: .init(
                triggerShapeId: "damageReported",
                conditionShapeIds: ["damageAmountAbove"],
                consequenceShapeIds: ["requireApproval"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 80
        ),
        RuleBuilderTemplate(
            id: "not_returned_fine",
            displayNameES: "Multa por no devolver el activo",
            descriptionES: "Si quien hizo checkout no devuelve el activo después de la fecha esperada (con X días de tolerancia), cobra una multa.",
            category: "assets",
            templateKind: "penalty",
            requiredCapabilities: ["custody"],
            defaultParams: .object([
                "grace_days": .int(1),
                "amount":     .int(200),
            ]),
            composition: .init(
                triggerShapeId: "checkoutOverdue",
                conditionShapeIds: ["alwaysTrue"],
                consequenceShapeIds: ["fine"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 90
        ),
        RuleBuilderTemplate(
            id: "maintenance_overdue_lock",
            displayNameES: "Bloquea bookings si el mantenimiento está atrasado",
            descriptionES: "Si un mantenimiento queda abierto más de X días, bloquea nuevos bookings del activo hasta que el mantenimiento se cierre o se desbloquee manualmente.",
            category: "assets",
            templateKind: "governance",
            requiredCapabilities: ["maintenance", "booking"],
            defaultParams: .object(["days": .int(7)]),
            composition: .init(
                triggerShapeId: "maintenanceOverdue",
                conditionShapeIds: ["alwaysTrue"],
                consequenceShapeIds: ["lockBookings"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 100
        ),
        RuleBuilderTemplate(
            id: "transfer_large_vote",
            displayNameES: "Voto para transferencias grandes",
            descriptionES: "Si la última valuación del activo supera $X y se intenta transferir, abre automáticamente una votación al grupo.",
            category: "assets",
            templateKind: "governance",
            requiredCapabilities: ["transfer", "voting"],
            defaultParams: .object([
                "threshold_cents":   .int(5_000_000),
                "duration_hours":    .int(48),
                "quorum_percent":    .int(50),
                "threshold_percent": .int(66),
            ]),
            composition: .init(
                triggerShapeId: "assetTransferred",
                conditionShapeIds: ["transferAmountAbove"],
                consequenceShapeIds: ["startVote"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 110
        ),
        RuleBuilderTemplate(
            id: "damage_logged_warning",
            displayNameES: "Aviso al grupo cuando se reporta un daño",
            descriptionES: "Cualquier daño reportado emite un aviso visible en la actividad del grupo. Útil para que los admins vean reportes sin esperar a que se acumulen.",
            category: "assets",
            templateKind: "governance",
            requiredCapabilities: ["maintenance"],
            defaultParams: .object([:]),
            composition: .init(
                triggerShapeId: "damageReported",
                conditionShapeIds: ["alwaysTrue"],
                consequenceShapeIds: ["emitWarning"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 120
        ),

        // MARK: - Space rule templates (mig 00272 — Plans/Active/SpaceRules.md §1)

        RuleBuilderTemplate(
            id: "space_capacity_overflow_waitlist",
            displayNameES: "Avisa cuando el espacio se llena",
            descriptionES: "Cuando una reserva completa el aforo del espacio, emite un aviso visible en la actividad. La UI sugiere a los siguientes interesados unirse a la lista de espera.",
            category: "spaces",
            templateKind: "governance",
            requiredCapabilities: ["capacity"],
            defaultParams: .object([:]),
            composition: .init(
                triggerShapeId: "spaceCapacityReached",
                conditionShapeIds: ["alwaysTrue"],
                consequenceShapeIds: ["emitWarning"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 200
        ),
        RuleBuilderTemplate(
            id: "space_cancellation_late_fine",
            displayNameES: "Multa por cancelación tardía",
            descriptionES: "Si alguien cancela una reserva con menos de X horas antes de su inicio, cobra una multa. Justo cuando ya no hay tiempo para que otro miembro use el espacio.",
            category: "spaces",
            templateKind: "penalty",
            requiredCapabilities: ["booking", "consequence"],
            defaultParams: .object([
                "hours":  .int(24),
                "amount": .int(200),
            ]),
            composition: .init(
                triggerShapeId: "bookingCancelled",
                conditionShapeIds: ["cancelledWithinHours"],
                consequenceShapeIds: ["fine"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 210
        ),
        RuleBuilderTemplate(
            id: "space_no_check_in_release",
            displayNameES: "Libera la reserva si nadie marca llegada",
            descriptionES: "Si pasa la hora de inicio y nadie ha hecho check-in en los siguientes X minutos, libera automáticamente la reserva para que otro miembro pueda ocupar el espacio.",
            category: "spaces",
            templateKind: "governance",
            requiredCapabilities: ["booking", "check_in"],
            defaultParams: .object(["grace_minutes": .int(30)]),
            composition: .init(
                triggerShapeId: "bookingNoCheckIn",
                conditionShapeIds: ["alwaysTrue"],
                consequenceShapeIds: ["releaseBooking"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 220
        ),
        RuleBuilderTemplate(
            id: "space_outside_allowed_hours_deny",
            displayNameES: "Rechaza reservas fuera del horario",
            descriptionES: "Si alguien intenta reservar fuera del horario permitido (por ejemplo, fuera de 8am-10pm), el sistema lo marca como no permitido. La UI captura el rechazo y avisa al usuario.",
            category: "spaces",
            templateKind: "governance",
            requiredCapabilities: ["booking", "schedule"],
            defaultParams: .object([
                "start_hour": .int(8),
                "end_hour":   .int(22),
                "message_es": .string("Reservas solo dentro del horario permitido del espacio"),
            ]),
            composition: .init(
                triggerShapeId: "bookingCreated",
                conditionShapeIds: ["outsideAllowedHours"],
                consequenceShapeIds: ["denyAction"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 230
        ),
        RuleBuilderTemplate(
            id: "space_founder_priority_bump",
            displayNameES: "Fundadores tienen prioridad en lista de espera",
            descriptionES: "Cuando un fundador entra a la lista de espera, su prioridad sube automáticamente para que pase delante de bookings posteriores. Para miembros con otro rol, configura el campo \"rol\".",
            category: "spaces",
            templateKind: "governance",
            requiredCapabilities: ["waitlist"],
            defaultParams: .object([
                "role":           .string("founder"),
                "priority_delta": .int(100),
            ]),
            composition: .init(
                triggerShapeId: "spaceWaitlistJoined",
                conditionShapeIds: ["actorHasRole"],
                consequenceShapeIds: ["bumpPriority"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 240
        ),
        RuleBuilderTemplate(
            id: "space_long_booking_vote",
            displayNameES: "Reservas largas requieren voto",
            descriptionES: "Si alguien reserva el espacio por más de X minutos en una sola sesión, abre automáticamente una votación al grupo. Útil para gates de uso intensivo (ej. canchas, palco).",
            category: "spaces",
            templateKind: "governance",
            requiredCapabilities: ["booking", "voting"],
            defaultParams: .object([
                "minutes":           .int(120),
                "duration_hours":    .int(24),
                "quorum_percent":    .int(50),
                "threshold_percent": .int(66),
            ]),
            composition: .init(
                triggerShapeId: "bookingCreated",
                conditionShapeIds: ["bookingDurationAbove"],
                consequenceShapeIds: ["startVote"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 250
        ),
        RuleBuilderTemplate(
            id: "space_damage_temporary_closure_vote",
            displayNameES: "Daño grave: voto para cerrar temporalmente el espacio",
            descriptionES: "Si alguien reporta un daño con severidad grave o total, abre automáticamente una votación al grupo para decidir si cerrar temporalmente el espacio mientras se repara.",
            category: "spaces",
            templateKind: "governance",
            requiredCapabilities: ["maintenance", "voting"],
            defaultParams: .object([
                "level":             .string("major"),
                "duration_hours":    .int(48),
                "quorum_percent":    .int(50),
                "threshold_percent": .int(66),
            ]),
            composition: .init(
                triggerShapeId: "damageReported",
                conditionShapeIds: ["damageSeverityAbove"],
                consequenceShapeIds: ["startVote"],
                scopeHint: RuleScope.resource
            ),
            sortOrder: 260
        )
    ]
}
