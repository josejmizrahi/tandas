import Foundation

/// V1 catalog of capability blocks per OpenPlatform Taxonomy §2.
///
/// This is the in-code registry of every capability the iOS app knows
/// how to render / configure / resolve. It maps 1:1 with the
/// `capability_block_id` strings stored on the server in
/// `modules.provided_capability_blocks` and `resource_capabilities`.
///
/// Phase 1 ships the blocks that map to V1 modules (rsvp, check_in,
/// recurrence, rotation, money, voting, rules, attendance, schedule,
/// approval, deadline, consequence, appeal, participants, swap). Phase
/// 2+ blocks (capacity, fund, contribution, payout, settlement,
/// reputation, etc.) get added incrementally as features land.
///
/// Lookup is `O(1)` via the `byId` dict. The catalog is immutable at
/// runtime — adding a new block means a code change + ship.
public struct CapabilityCatalog: Sendable {
    public let blocks: [any CapabilityBlock]
    public let byId: [String: any CapabilityBlock]

    public init(blocks: [any CapabilityBlock]) {
        self.blocks = blocks
        self.byId = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
    }

    public subscript(id: String) -> (any CapabilityBlock)? { byId[id] }

    /// Returns blocks compatible with the given resource type.
    public func blocks(for resourceType: ResourceType) -> [any CapabilityBlock] {
        blocks.filter { $0.enabledResourceTypes.contains(resourceType) }
    }

    /// Resolves a transitive dependency closure for a block id, including
    /// the block itself. Detects cycles defensively (returns the
    /// already-discovered set if a cycle is hit).
    public func transitiveDependencies(of id: String) -> Set<String> {
        var visited: Set<String> = []
        var queue: [String] = [id]
        while let next = queue.popLast() {
            if visited.contains(next) { continue }
            visited.insert(next)
            if let block = byId[next] {
                for dep in block.dependencies where !visited.contains(dep) {
                    queue.append(dep)
                }
            }
        }
        return visited
    }

    /// Default V1 catalog, shipped in code.
    public static let v1: CapabilityCatalog = CapabilityCatalog(blocks: [
        RsvpCapability(),
        CheckInCapability(),
        ScheduleCapability(),
        RecurrenceCapability(),
        RotationCapability(),
        AssignmentCapability(),
        ParticipantsCapability(),
        AttendanceCapability(),
        DeadlineCapability(),
        ApprovalCapability(),
        MoneyCapability(),
        LedgerCapability(),
        VotingCapability(),
        RulesCapability(),
        ConsequenceCapability(),
        AppealCapability(),
        SwapCapability()
    ])
}

// MARK: - V1 blocks

/// Generic skeleton struct used by simple blocks that don't need custom
/// init logic. Real Phase 2+ blocks may declare their own structs with
/// per-instance state.
private struct SimpleCapability: CapabilityBlock {
    let id: String
    let displayName: String
    let summary: String
    let enabledResourceTypes: [ResourceType]
    let requiredFields: [BuilderField]
    let optionalFields: [BuilderField]
    let suggestedRules: [RuleTemplate]
    let actions: [CapabilityAction]
    let routes: [CapabilityRoute]
    let permissions: [Permission]
    let projections: [ProjectionDescriptor]
    let dependencies: [String]
    let conflicts: [String]
}

// rsvp — confirmation of attendance
public struct RsvpCapability: CapabilityBlock {
    public init() {}
    public var id: String { "rsvp" }
    public var displayName: String { "RSVP" }
    public var summary: String { "Los miembros confirman si van a venir." }
    public var enabledResourceTypes: [ResourceType] { [.event] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "deadline", label: "Fecha límite",  kind: .dateTime,
                         helpText: "Después de esta fecha, los pendientes pasan a 'no respondió'."),
            BuilderField(key: "allowMaybe", label: "Permitir 'tal vez'", kind: .boolean)
        ]
    }
    public var suggestedRules: [RuleTemplate] {
        // Each template declares its own trigger + consequence
        // explicitly per founder framing 2026-05-11. Reminder
        // template defaults ON; monetary fine template defaults OFF
        // so first-time users don't see a punitive default.
        [
            RuleTemplate(
                slug: "rsvp_no_response_reminder",
                displayName: "Recordatorio a quien no respondió",
                summary: "Cuando vence la fecha límite, manda un recordatorio a los pendientes.",
                triggerEventType: .rsvpDeadlinePassed,
                consequenceType: .sendNotification,
                defaultEnabled: true
            ),
            RuleTemplate(
                slug: "rsvp_late_cancel_fine",
                displayName: "Multa por cancelar el mismo día",
                summary: "Si alguien cambia a 'no voy' el día del evento, paga $150.",
                triggerEventType: .rsvpChangedSameDay,
                consequenceType: .fine,
                defaultConfig: ["amount": "150"],
                defaultEnabled: false
            )
        ]
    }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "rsvp.set", label: "Confirmar asistencia", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "rsvp.list", label: "Asistentes", icon: "person.2")]
    }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "attendance_summary", displayName: "Asistencia", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// check_in — physical presence registration
public struct CheckInCapability: CapabilityBlock {
    public init() {}
    public var id: String { "check_in" }
    public var displayName: String { "Check-in" }
    public var summary: String { "Registro de llegada al evento." }
    public var enabledResourceTypes: [ResourceType] { [.event] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [BuilderField(key: "lateThresholdMinutes", label: "Tarde después de (min)", kind: .integer)]
    }
    public var suggestedRules: [RuleTemplate] {
        // Late-arrival monetary fine + no-show monetary fine. Both
        // OFF by default — the user explicitly opts into punitive
        // rules. Their reminder counterparts (when seeded) would
        // default to ON.
        [
            RuleTemplate(
                slug: "check_in_late_arrival_fine",
                displayName: "Multa por llegar tarde",
                summary: "Si alguien hace check-in pasada la hora, paga $100.",
                triggerEventType: .checkInRecorded,
                consequenceType: .fine,
                defaultConfig: ["amount": "100"],
                defaultEnabled: false
            ),
            RuleTemplate(
                slug: "event_closed_no_show_fine",
                displayName: "Multa por no llegar",
                summary: "Cuando el host cierra el evento, los que no llegaron pagan $250.",
                triggerEventType: .eventClosed,
                consequenceType: .fine,
                defaultConfig: ["amount": "250"],
                defaultEnabled: false
            )
        ]
    }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "check_in.record", label: "Registrar llegada", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "attendance_actual", displayName: "Llegaron", scope: .resource)]
    }
    public var dependencies: [String] { ["rsvp"] }
    public var conflicts: [String] { [] }
}

// schedule — date/time/duration of a resource
public struct ScheduleCapability: CapabilityBlock {
    public init() {}
    public var id: String { "schedule" }
    public var displayName: String { "Horario" }
    public var summary: String { "Fecha, hora y duración." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .booking] }
    public var requiredFields: [BuilderField] {
        [BuilderField(key: "startsAt", label: "Empieza", kind: .dateTime)]
    }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "endsAt", label: "Termina", kind: .dateTime),
            BuilderField(key: "timezone", label: "Zona horaria", kind: .text),
            BuilderField(key: "allDay", label: "Todo el día", kind: .boolean)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// recurrence — turns one-off into a series
public struct RecurrenceCapability: CapabilityBlock {
    public init() {}
    public var id: String { "recurrence" }
    public var displayName: String { "Repetir" }
    public var summary: String { "Genera ocurrencias automáticamente según un patrón." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .contribution] }
    /// Founder framing 2026-05-11: capability sub-config is declarative.
    /// The wizard reads these fields via BuilderFieldRenderer instead of
    /// a hardcoded view for each capability id. Adding a new picker
    /// option (e.g. "anual") is one BuilderField.PickerOption row, not
    /// a Swift view edit.
    public var requiredFields: [BuilderField] {
        [
            BuilderField(
                key: "frequency",
                label: "Frecuencia",
                kind: .picker,
                options: [
                    .init(value: .string("weekly"),   label: "Semanal"),
                    .init(value: .string("biweekly"), label: "Cada 2 semanas"),
                    .init(value: .string("monthly"),  label: "Mensual")
                ]
            ),
            BuilderField(
                key: "dayOfWeek",
                label: "Día",
                kind: .picker,
                options: [
                    .init(value: .int(0), label: "Dom"),
                    .init(value: .int(1), label: "Lun"),
                    .init(value: .int(2), label: "Mar"),
                    .init(value: .int(3), label: "Mié"),
                    .init(value: .int(4), label: "Jue"),
                    .init(value: .int(5), label: "Vie"),
                    .init(value: .int(6), label: "Sáb")
                ]
            ),
            BuilderField(
                key: "time",
                label: "Hora",
                kind: .time
            )
        ]
    }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "interval", label: "Cada", kind: .integer),
            BuilderField(key: "endCondition", label: "Termina", kind: .picker)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "recurrence.series", label: "Próximas", icon: "calendar")]
    }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { ["schedule"] }
    public var conflicts: [String] { [] }
}

// rotation — turns rotate among participants
public struct RotationCapability: CapabilityBlock {
    public init() {}
    public var id: String { "rotation" }
    public var displayName: String { "Rotación" }
    public var summary: String { "Asigna un rol o turno rotativamente entre los miembros." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .position] }
    public var requiredFields: [BuilderField] {
        [BuilderField(key: "purpose", label: "Para qué rola", kind: .text,
                      helpText: "host, payout, slot, etc.")]
    }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "orderStrategy", label: "Orden", kind: .picker),
            BuilderField(key: "swapPolicy", label: "Política de cambio", kind: .picker)
        ]
    }
    public var suggestedRules: [RuleTemplate] {
        // Auto-skip is a structural rule (not monetary) — defaults ON
        // so rotation works smoothly out of the box. The optional
        // monetary fine for same-day cancellation defaults OFF.
        [
            RuleTemplate(
                slug: "rotation_auto_skip_late_cancel",
                displayName: "Si el host no puede, pasa al siguiente",
                summary: "Cuando el host cancela el mismo día, el turno se reasigna automáticamente.",
                triggerEventType: .rsvpChangedSameDay,
                consequenceType: .loseTurn,
                defaultEnabled: true
            ),
            RuleTemplate(
                slug: "rotation_late_cancel_fine",
                displayName: "Multa al host por cancelar el día",
                summary: "Además de perder turno, paga $200 si cancela el día.",
                triggerEventType: .rsvpChangedSameDay,
                consequenceType: .fine,
                defaultConfig: ["amount": "200"],
                defaultEnabled: false
            )
        ]
    }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "rotation.advance", label: "Avanzar turno", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "rotation.order", label: "Orden", icon: "arrow.triangle.2.circlepath")]
    }
    public var permissions: [Permission] { [.modifyMembers] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "rotation_state", displayName: "Turno actual", scope: .resource)]
    }
    public var dependencies: [String] { ["participants"] }
    public var conflicts: [String] { [] }
}

// assignment — discrete responsibility
public struct AssignmentCapability: CapabilityBlock {
    public init() {}
    public var id: String { "assignment" }
    public var displayName: String { "Asignación" }
    public var summary: String { "Asigna una tarea a un miembro específico." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .position] }
    public var requiredFields: [BuilderField] {
        [
            BuilderField(key: "assignee", label: "Asignado a", kind: .memberPicker),
            BuilderField(key: "task", label: "Tarea", kind: .text)
        ]
    }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "deadline", label: "Fecha límite", kind: .dateTime),
            BuilderField(key: "requiresAcceptance", label: "Requiere aceptación", kind: .boolean)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [
            CapabilityAction(id: "assignment.accept", label: "Aceptar", surface: .resourceDetail),
            CapabilityAction(id: "assignment.complete", label: "Completar", surface: .resourceDetail)
        ]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// participants — who's eligible / included
public struct ParticipantsCapability: CapabilityBlock {
    public init() {}
    public var id: String { "participants" }
    public var displayName: String { "Participantes" }
    public var summary: String { "Define quién está incluido por default." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "includeAllMembers", label: "Todos los miembros", kind: .boolean),
            BuilderField(key: "explicitMembers", label: "Miembros específicos", kind: .multiPicker)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// attendance — derived from rsvp + check_in
public struct AttendanceCapability: CapabilityBlock {
    public init() {}
    public var id: String { "attendance" }
    public var displayName: String { "Asistencia" }
    public var summary: String { "Registro de quién asistió de hecho." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "attendance.list", label: "Asistencia", icon: "checkmark.circle")]
    }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "attendance_rate", displayName: "Tasa", scope: .member)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// deadline — time-bounded action
public struct DeadlineCapability: CapabilityBlock {
    public init() {}
    public var id: String { "deadline" }
    public var displayName: String { "Fecha límite" }
    public var summary: String { "Define una hora a la que algo debe estar resuelto." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .booking] }
    public var requiredFields: [BuilderField] {
        [BuilderField(key: "deadlineAt", label: "Cuándo", kind: .dateTime)]
    }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "gracePeriodMinutes", label: "Tolerancia", kind: .integer),
            BuilderField(key: "deadlineAction", label: "Qué pasa después", kind: .picker)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// approval — explicit gate
public struct ApprovalCapability: CapabilityBlock {
    public init() {}
    public var id: String { "approval" }
    public var displayName: String { "Aprobación" }
    public var summary: String { "Requiere aprobación antes de tomar efecto." }
    public var enabledResourceTypes: [ResourceType] { [.booking, .guestPass] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "approverType", label: "Quién aprueba", kind: .picker),
            BuilderField(key: "autoApprovePolicy", label: "Auto-aprobar si", kind: .picker)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "approval.approve", label: "Aprobar", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// money — semantic umbrella over expense/contribution/payout
public struct MoneyCapability: CapabilityBlock {
    public init() {}
    public var id: String { "money" }
    public var displayName: String { "Dinero" }
    public var summary: String { "Gastos, aportaciones y multas asociadas a este recurso." }
    public var enabledResourceTypes: [ResourceType] { [.event, .booking, .fund] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "money.expense.add", label: "Registrar gasto", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "money.balance", label: "Saldo", icon: "dollarsign.circle")]
    }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "balance", displayName: "Saldo", scope: .resource)]
    }
    public var dependencies: [String] { ["ledger"] }
    public var conflicts: [String] { [] }
}

// ledger — append-only money atoms
public struct LedgerCapability: CapabilityBlock {
    public init() {}
    public var id: String { "ledger" }
    public var displayName: String { "Ledger" }
    public var summary: String { "Asientos contables atómicos." }
    public var enabledResourceTypes: [ResourceType] { [.event, .booking, .fund] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "ledger_view", displayName: "Movimientos", scope: .group)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// voting — collective decision
public struct VotingCapability: CapabilityBlock {
    public init() {}
    public var id: String { "voting" }
    public var displayName: String { "Votación" }
    public var summary: String { "Decisión colectiva con quórum y umbral." }
    public var enabledResourceTypes: [ResourceType] { [.proposal, .booking] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "quorumPercent",   label: "Quórum (%)", kind: .integer),
            BuilderField(key: "thresholdPercent", label: "Umbral (%)", kind: .integer),
            BuilderField(key: "anonymous",       label: "Anónimo",     kind: .boolean)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "voting.cast", label: "Votar", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "voting.results", label: "Resultados", icon: "chart.bar")]
    }
    public var permissions: [Permission] { [.castVote] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "vote_counts", displayName: "Conteo", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// rules — configurable WHEN/IF/THEN
public struct RulesCapability: CapabilityBlock {
    public init() {}
    public var id: String { "rules" }
    public var displayName: String { "Reglas" }
    public var summary: String { "Define qué pasa automáticamente cuando algo sucede." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .fund] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "rules.add", label: "Agregar regla", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "rules.list", label: "Reglas", icon: "list.bullet.clipboard")]
    }
    public var permissions: [Permission] { [.modifyRules] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// consequence — what a rule produces (fine, warning, etc.)
public struct ConsequenceCapability: CapabilityBlock {
    public init() {}
    public var id: String { "consequence" }
    public var displayName: String { "Consecuencias" }
    public var summary: String { "Las reglas pueden generar multas, advertencias o votos." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .fund] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { ["rules"] }
    public var conflicts: [String] { [] }
}

// appeal — disputing a consequence
public struct AppealCapability: CapabilityBlock {
    public init() {}
    public var id: String { "appeal" }
    public var displayName: String { "Apelación" }
    public var summary: String { "Permite disputar una multa o sanción." }
    public var enabledResourceTypes: [ResourceType] { [.event] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [BuilderField(key: "deadlineHours", label: "Ventana (horas)", kind: .integer)]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "appeal.start", label: "Apelar", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { ["voting", "consequence"] }
    public var conflicts: [String] { [] }
}

// swap — slot swapping
public struct SwapCapability: CapabilityBlock {
    public init() {}
    public var id: String { "swap" }
    public var displayName: String { "Cambios" }
    public var summary: String { "Permite intercambiar slots o turnos entre miembros." }
    public var enabledResourceTypes: [ResourceType] { [.slot, .booking] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "approvalRequired", label: "Requiere aprobación", kind: .boolean),
            BuilderField(key: "directSwap",        label: "Intercambio directo", kind: .boolean)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "swap.request", label: "Pedir cambio", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}
