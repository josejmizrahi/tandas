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

    // MARK: - Capability tiers (Plans/Active/CapabilityTiers.md)

    /// Tier 0 — universals. Apply to ALL 6 resource types. See
    /// `Plans/Active/CapabilityTiers.md §2`. `status`, `description`,
    /// `history` are universal in catalog already; this list is the
    /// canonical Tier-0 contract referenced by builders + the backfill
    /// migration so any future addition is grep-able from one place.
    ///
    /// `links` (mig 00233) joined Tier 0 with Fase 2 — every resource
    /// is a node of the graph and surfaces a "Vinculado con…" section.
    public static let tier0CapabilityIds: [String] = [
        "status", "description", "history", "rules", "voting", "links"
    ]

    /// Tier 0.5 — economic universals. Apply to every resource type that
    /// can be the subject of money flows (event/fund/asset/space/slot).
    /// `right` is excluded by doctrine — see `CapabilityTiers.md §3`.
    public static let tier05CapabilityIds: [String] = [
        "ledger", "money"
    ]

    /// Resource types that receive Tier 0.5 economic capabilities on
    /// creation. Mirrors `LedgerCapability.enabledResourceTypes` and
    /// `MoneyCapability.enabledResourceTypes` — kept in sync manually.
    public static let tier05EligibleTypes: Set<ResourceType> = [
        .event, .fund, .asset, .space, .slot
    ]

    /// Returns the canonical default set of capabilities a new resource of
    /// this type should be created with: Tier 0 (always) ∪ Tier 0.5
    /// (when eligible). Type-specific Tier 1 caps (rsvp, custody,
    /// booking, etc.) remain opt-in via the wizard.
    public static func tierDefaultCapabilities(for type: ResourceType) -> [String] {
        var ids = tier0CapabilityIds
        if tier05EligibleTypes.contains(type) {
            ids.append(contentsOf: tier05CapabilityIds)
        }
        return ids
    }

    /// Merge an explicit capability list with the tier defaults for the
    /// given type, preserving order and deduping. Builders use this when
    /// persisting a draft so Tier 0/0.5 caps end up on the resource even
    /// if the wizard didn't list them.
    public static func mergeTierDefaults(
        explicit: [String],
        for type: ResourceType
    ) -> [String] {
        var seen: Set<String> = []
        var merged: [String] = []
        for id in explicit + tierDefaultCapabilities(for: type) {
            if seen.insert(id).inserted { merged.append(id) }
        }
        return merged
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
        SwapCapability(),
        // Phase 2 prerequisites (audit task M.10). These blocks are
        // referenced by modules.provided_capability_blocks rows seeded
        // in mig 00078 (slot_assignment provides capacity + booking +
        // expiration; rsvp module pairs with reminder). Declared here
        // so resource_capabilities lookups resolve cleanly before the
        // matching ResourceType cases ship their own builders.
        CapacityCapability(),
        GuestAccessCapability(),
        BookingCapability(),
        ExpirationCapability(),
        CancellationCapability(),
        ReminderCapability(),
        StatusCapability(),
        HistoryCapability(),
        LinksCapability(),
        // Event-shape primitives. Hard-seeded on every event resource by
        // mig 00109 + 00110 (no module provides them — they're inherent
        // to the event shape). Declared here so the catalog resolves the
        // strings when iOS reads resource_capabilities.
        DescriptionCapability(),
        HostActionsCapability(),
        LocationCapability(),
        // Asset universal blocks — mig 00199 (canonical asset spec §8).
        // Backend RPCs in mig 00200, projections in mig 00201.
        CustodyCapability(),
        MaintenanceCapability(),
        ValuationCapability(),
        TransferCapability(),
        AccessCapability(),
        DelegationCapability(),
        InventoryCapability()
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
    public var enabledResourceTypes: [ResourceType] { [.event, .slot] }
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
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .fund] }
    /// Founder framing 2026-05-12 (Tier 1.1): full pattern surface so
    /// the cron generator (auto-generate-events post-Tier-1.5) has
    /// every field it needs to compute occurrences without legacy
    /// fallbacks. Conditional fields (count, untilDate) use the new
    /// BuilderField.dependsOn predicate.
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
            ),
            BuilderField(
                key: "startDate",
                label: "Empieza el",
                kind: .date,
                helpText: "Fecha del primer evento de la serie."
            ),
            BuilderField(
                key: "endCondition",
                label: "Termina",
                kind: .picker,
                options: [
                    .init(value: .string("never"),       label: "Nunca"),
                    .init(value: .string("after_count"), label: "Después de N veces"),
                    .init(value: .string("until_date"),  label: "En una fecha")
                ]
            ),
            // Conditional: count only when endCondition='after_count'.
            BuilderField(
                key: "count",
                label: "¿Cuántas veces?",
                kind: .integer,
                placeholder: "8",
                helpText: "Número total de ocurrencias a generar.",
                dependsOn: .init(key: "endCondition", equalsValue: .string("after_count"))
            ),
            // Conditional: untilDate only when endCondition='until_date'.
            BuilderField(
                key: "untilDate",
                label: "Hasta",
                kind: .date,
                helpText: "Última fecha posible. Si cae el día de la serie, ese día sí cuenta.",
                dependsOn: .init(key: "endCondition", equalsValue: .string("until_date"))
            ),
            BuilderField(
                key: "timezone",
                label: "Zona horaria",
                kind: .text,
                placeholder: "America/Mexico_City",
                helpText: "Solo informativa por ahora — la generación usa UTC."
            )
        ]
    }
    public var optionalFields: [BuilderField] {
        // Interval kept as an advanced option (for "every N weeks/months").
        // V1 generator ignores it (advances by 1 unit per frequency). The
        // field stays declared so the wizard renders + persists it for
        // later Tier-8 work, but it's not required.
        [
            BuilderField(key: "interval", label: "Cada cuántas (avanzado)", kind: .integer)
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
    // Tier 1 (2026-05-12) shipped:
    //   - Catalog full pattern: startDate, endCondition options,
    //     count + untilDate (conditional via dependsOn), timezone.
    //   - Wizard serializes the full pattern jsonb on submit.
    //   - auto-generate-events rewrite reads resource_series + uses
    //     _shared/recurrence.ts (24 unit tests passing).
    //   - resource_series.generated_until cursor + events.series_id
    //     unique constraint for idempotency (mig 00126).
    // Status default `.stable` via protocol extension applies.
}

// rotation — turns rotate among participants
public struct RotationCapability: CapabilityBlock {
    public init() {}
    public var id: String { "rotation" }
    public var displayName: String { "Rotación" }
    public var summary: String { "Asigna un rol o turno rotativamente entre los miembros." }
    /// Founder decision 2026-05-13: rotation is a capability on
    /// `resource_series` for Tier 5 Beta. Only events (recurring) are
    /// in scope today — slot/position remain declarative future scope.
    /// The wizard reaches this capability when configuring a series.
    public var enabledResourceTypes: [ResourceType] { [.event, .slot] }
    public var requiredFields: [BuilderField] {
        [
            BuilderField(
                key: "purpose",
                label: "Para qué rola",
                kind: .text,
                helpText: "host, payout, slot, etc."
            ),
            BuilderField(
                key: "participants",
                label: "Miembros que rotan",
                kind: .multiPicker,
                helpText: "Selecciona quiénes entran al ciclo de rotación."
            ),
            BuilderField(
                key: "order",
                label: "Orden",
                kind: .picker,
                options: [
                    .init(value: .string("sequential"), label: "En orden (1 → 2 → 3 → 1)"),
                    .init(value: .string("random"),     label: "Aleatorio determinístico")
                ]
            ),
            BuilderField(
                key: "frequency",
                label: "Frecuencia",
                kind: .picker,
                options: [
                    .init(value: .string("every_event"), label: "Cada ocurrencia")
                ],
                // Tier 5 Beta scope: only every_event ships. Adding
                // every_n_events is a follow-up that requires the
                // generator to divide cycle by N before lookup.
                dependsOn: nil
            )
        ]
    }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(
                key: "replacementPolicy",
                label: "Si el elegido no está",
                kind: .picker,
                options: [
                    .init(value: .string("skip_to_next"),         label: "Pasa al siguiente"),
                    .init(value: .string("host_stays_until_swap"), label: "Se queda hasta swap")
                ]
            )
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
    /// Tier 5 Beta closed end-to-end:
    ///   - mig 00132: next_host_for_series + series-level cap_config
    ///   - auto-generate-events v7: forwards resolved host_id to create_event_v2
    ///   - mig 00133: trigger inserts user_action(hostAssigned) when host_id ≠ created_by
    ///   - MemberMultiPickerField: real member-aware multi-picker with ordered output
    ///   - RotationSectionView: read-only Resource Detail surface (next host,
    ///     upcoming, rotation order, policy summary)
    ///   - ActivitySectionView.labelForEventCreated: surfaces host name in
    ///     the activity feed for rotation-resolved occurrences
    /// Future work (out of Beta scope, won't reopen .stable):
    ///   - host_skipped / host_reassigned signals (no schema field today)
    ///   - swap requests, marketplace, voting on swaps
    ///   - rotation shared across multiple resources
    public var status: CapabilityStatus { .stable }
}

// assignment — discrete responsibility
public struct AssignmentCapability: CapabilityBlock {
    public init() {}
    public var id: String { "assignment" }
    public var displayName: String { "Asignación" }
    public var summary: String { "Asigna una tarea a un miembro específico." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot] }
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
    /// Tier 0 audit 2026-05-12: `assignee` is .memberPicker which falls
    /// through to free text in the renderer. No standalone backend save
    /// path — assignments live inside slot.metadata.assigned_member_id.
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 5: needs real memberPicker UI + standalone save path or removal in favor of slot.metadata.")
    }
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
    /// Tier 0 audit 2026-05-12: `explicitMembers` is .multiPicker which
    /// falls to free text. No backend consumer of participants config.
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 5: needs member directory multiPicker + backend that reads participants config.")
    }
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
    public var enabledResourceTypes: [ResourceType] { [.event, .slot] }
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
    public var enabledResourceTypes: [ResourceType] { [.slot, .right] }
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
    /// Tier 0 audit 2026-05-12: approverType + autoApprovePolicy declared
    /// as `.picker` without options. No event-side approval RPC; only
    /// finalize-fine-reviews hardcoded 48h grace exists.
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 4: needs approverType + autoApprovePolicy options + per-resource approval RPC.")
    }
}

// money — semantic umbrella over expense/contribution/payout
public struct MoneyCapability: CapabilityBlock {
    public init() {}
    public var id: String { "money" }
    public var displayName: String { "Dinero" }
    public var summary: String { "Gastos, aportaciones y multas asociadas a este recurso." }
    // Tier 0.5 per Plans/Active/CapabilityTiers.md §3. Every resource that
    // can be the subject of money flows owns this surface. `right` is
    // explicitly excluded — rights generate fees but the money lives in
    // the underlying resource (the fund that pays, the asset they control).
    public var enabledResourceTypes: [ResourceType] { [.event, .fund, .asset, .space, .slot] }
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
    /// Tier 6 closed end-to-end (mig 00136 → 00145):
    ///   - balance projection views aggregate ledger_entries at read time
    ///   - MoneySectionView renders top 3 non-zero balances inline
    ///   - `fund` resource_type creatable via create_fund + wizard branch
    ///   - fundDeposit emits on every contribution to a fund
    ///   - fundThresholdReached emits once when cumulative deposits cross
    ///     target_amount_cents in the fund's currency
    ///   - record_settlement RPC + SettlementSheet UI: any member can
    ///     register a bilateral payment; balance views refresh on read
    /// Out of Tier 6 Beta scope (deliberately deferred):
    ///   - wizard form for who-can-add / default-split / reminders
    ///     (Beta 1 Consolidation says "no new wizard features")
    ///   - automated split (one-tap "divide la cena entre todos")
    public var status: CapabilityStatus { .stable }
}

// ledger — append-only money atoms
public struct LedgerCapability: CapabilityBlock {
    public init() {}
    public var id: String { "ledger" }
    public var displayName: String { "Ledger" }
    public var summary: String { "Asientos contables atómicos." }
    // Tier 0.5 per Plans/Active/CapabilityTiers.md §3. All economic
    // resources get the polymorphic ledger surface (record_ledger_entry,
    // record_settlement, type-specific writers where they exist).
    // Excluded: `right` — see CapabilityTiers §3 for the ontological
    // justification (rights are relations, not balance holders).
    public var enabledResourceTypes: [ResourceType] { [.event, .fund, .asset, .space, .slot] }
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
    /// Tier 6 closed (mig 00136 → 00145): ledger atoms feed
    /// balance projection views, MoneySectionView renders inline
    /// balances, record_settlement + SettlementSheet wire the bilateral
    /// payment loop. A dedicated group-wide ledger surface (separate
    /// from MoneySection's resource-scoped roll-up) is intentionally
    /// out-of-scope for Beta — per-resource visibility covers the
    /// canonical use cases without adding a tab/surface duplication.
    public var status: CapabilityStatus { .stable }
}

// voting — collective decision
public struct VotingCapability: CapabilityBlock {
    public init() {}
    public var id: String { "voting" }
    public var displayName: String { "Votación" }
    public var summary: String { "Decisión colectiva con quórum y umbral." }
    /// Voting is a governance workflow that can subject ANY resource:
    /// fines (appeals on events), rule changes (any scope), member
    /// removals, fund threshold adjustments, asset acquisitions, etc.
    /// Universal — enabled for the full canonical 6.
    public var enabledResourceTypes: [ResourceType] { [.event, .fund, .asset, .space, .slot, .right] }
    /// Tier 3 (2026-05-13) promoted quorum/threshold/anonymous to required
    /// so step 3 of the wizard renders them. Pre-Tier-3 they were optional
    /// and never surfaced — the wizard collected nothing and start_vote
    /// silently used groups.governance defaults for every vote.
    public var requiredFields: [BuilderField] {
        [
            BuilderField(key: "quorumPercent",    label: "Quórum (%)",  kind: .integer),
            BuilderField(key: "thresholdPercent", label: "Umbral (%)",  kind: .integer),
            BuilderField(key: "anonymous",        label: "Anónimo",     kind: .boolean)
        ]
    }
    public var optionalFields: [BuilderField] { [] }
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
    /// Tier 3 (mig 00130) shipped: start_vote now consults
    /// `p_payload.capability_config.voting` before falling back to
    /// `groups.governance`. The remaining .incomplete blocker is the
    /// resource-creation side — neither `proposal` nor `booking` is yet
    /// creatable via `build_resource_from_draft`, so no wizard reaches
    /// this capability today. When those resource types ship, the
    /// caller (LiveVoteRepository or equivalent) must pluck the cap
    /// config off `resource_capabilities.config.voting` and forward it
    /// in `p_payload.capability_config.voting` to make the wizard's
    /// values stick on each vote opened against that resource.
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 5+: ship proposal/booking creation paths so the wizard can actually persist voting cap_config (start_vote already reads it as of Tier 3 / mig 00130).")
    }
}

// rules — configurable WHEN/IF/THEN
public struct RulesCapability: CapabilityBlock {
    public init() {}
    public var id: String { "rules" }
    public var displayName: String { "Reglas" }
    public var summary: String { "Define qué pasa automáticamente cuando algo sucede." }
    // Tier 0 per Plans/Active/CapabilityTiers.md §2. Every resource is
    // governable — rules tie WHEN/IF/THEN over any atom. Asset rules
    // (insurance renewal), right rules (auto-expire), space rules
    // (capacity caps) are first-class.
    public var enabledResourceTypes: [ResourceType] { [.event, .fund, .asset, .space, .slot, .right] }
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
    // Follows `rules` (Tier 0). A consequence is dead without a rule to
    // produce it, so wherever rules apply consequences apply too.
    public var enabledResourceTypes: [ResourceType] { [.event, .fund, .asset, .space, .slot, .right] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { ["rules"] }
    public var conflicts: [String] { [] }
    /// Tier 0 audit 2026-05-12: empty fields = decorative toggle. The
    /// real consequence config lives inside each rule's `consequences`
    /// jsonb (see RulesCapability). Surfacing this as its own toggle is
    /// confusing — the user thinks it's a switch for "are consequences
    /// allowed" when really every rule already declares its own.
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 7: collapse into Rules — consequence is per-rule, not a resource-level switch.")
    }
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
    public var enabledResourceTypes: [ResourceType] { [.slot] }
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
    /// Tier 0 audit 2026-05-12: only relevant for slot/booking (both
    /// raise in build_resource_from_draft). request_slot_swap RPC exists
    /// but finalize-handler "lands in Slice 2.5" — not shipped.
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 5: ship slot/booking creation + slot_swap finalize handler before exposing.")
    }
}

// MARK: - Phase 2 prerequisites (audit M.10)

// capacity — cap on participant count
public struct CapacityCapability: CapabilityBlock {
    public init() {}
    public var id: String { "capacity" }
    public var displayName: String { "Cupo" }
    public var summary: String { "Límite de cuántos miembros pueden ocupar el recurso." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .asset, .right] }
    public var requiredFields: [BuilderField] {
        [BuilderField(key: "max", label: "Cupo máximo", kind: .integer)]
    }
    public var optionalFields: [BuilderField] {
        [BuilderField(key: "waitlistEnabled", label: "Lista de espera", kind: .boolean)]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// guest_access — non-member can attend
public struct GuestAccessCapability: CapabilityBlock {
    public init() {}
    public var id: String { "guest_access" }
    public var displayName: String { "Invitados" }
    public var summary: String { "Permite que los miembros traigan acompañantes externos al grupo." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .asset] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "perMemberLimit", label: "Invitados por miembro", kind: .integer),
            BuilderField(key: "approvalRequired", label: "Requiere aprobación", kind: .boolean)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "guest_access.invite", label: "Agregar invitado", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
    /// Tier 0 audit 2026-05-12: required + optional fields don't surface
    /// in step 3 (no requiredFields). For events, runtime reads
    /// events.allow_plus_ones column not capability_config — works as a
    /// FLAG but the user-facing toggle promises per-resource limits the
    /// config can't actually set.
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 2: promote perMemberLimit + approvalRequired to requiredFields + wire set_rsvp_v2 to read capability_config.")
    }
}

// booking — claiming a slot/resource for a member
public struct BookingCapability: CapabilityBlock {
    public init() {}
    public var id: String { "booking" }
    public var displayName: String { "Reservas" }
    public var summary: String { "Los miembros reservan slots o recursos disponibles." }
    public var enabledResourceTypes: [ResourceType] { [.slot, .asset] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "approvalRequired", label: "Requiere aprobación", kind: .boolean),
            BuilderField(key: "cancellationDeadlineHours", label: "Cancelar hasta (h antes)", kind: .integer)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "booking.request", label: "Reservar", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { ["schedule"] }
    public var conflicts: [String] { [] }
    /// Tier 0 audit 2026-05-12: slot/asset resource_types are the only
    /// targets; slot raises in build_resource_from_draft. requiredFields
    /// empty → toggle has no form to fill.
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 5: ship slot creation via build_resource_from_draft + promote approval/cancellationDeadline to requiredFields.")
    }
}

// expiration — auto-close after a time window
public struct ExpirationCapability: CapabilityBlock {
    public init() {}
    public var id: String { "expiration" }
    public var displayName: String { "Expira" }
    public var summary: String { "El recurso se libera o cierra automáticamente al pasar la fecha." }
    public var enabledResourceTypes: [ResourceType] { [.slot, .right] }
    public var requiredFields: [BuilderField] {
        [BuilderField(key: "expiresAt", label: "Expira", kind: .dateTime)]
    }
    public var optionalFields: [BuilderField] {
        [BuilderField(key: "autoRelease", label: "Liberar al expirar", kind: .boolean)]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// cancellation — explicit teardown lifecycle step
public struct CancellationCapability: CapabilityBlock {
    public init() {}
    public var id: String { "cancellation" }
    public var displayName: String { "Cancelación" }
    public var summary: String { "Define quién puede cancelar y con cuánta anticipación." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "whoCanCancel", label: "Quién puede cancelar", kind: .text),
            BuilderField(key: "deadlineHours", label: "Mínimo (h antes)", kind: .integer)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "cancellation.cancel", label: "Cancelar", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
    /// Tier 0 audit 2026-05-12: requiredFields empty → no form. Runtime
    /// cancel_event RPC exists but isn't gated by capability_config (any
    /// host/admin can cancel regardless of whoCanCancel/deadlineHours).
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 5: promote whoCanCancel + deadlineHours to requiredFields + cancel_event consults capability_config.")
    }
}

// reminder — scheduled nudge to members
public struct ReminderCapability: CapabilityBlock {
    public init() {}
    public var id: String { "reminder" }
    public var displayName: String { "Recordatorios" }
    public var summary: String { "Avisa a los miembros antes de la fecha límite o del evento." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .fund] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [BuilderField(key: "hoursBefore", label: "Horas antes", kind: .integer)]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
    /// Tier 0 audit 2026-05-12: empty requiredFields. No cron emits
    /// `hoursBeforeEvent` system_events — the evaluator exists but has
    /// no upstream emitter. send-fine-reminders hardcodes the 3/7/14d
    /// schedule. Per-resource reminder config is decorative.
    public var status: CapabilityStatus {
        .incomplete(reason: "Tier 4: ship emit-event-reminder-events cron + promote hoursBefore to requiredFields.")
    }
}

// status — lifecycle state machine on the resource
public struct StatusCapability: CapabilityBlock {
    public init() {}
    public var id: String { "status" }
    public var displayName: String { "Estado" }
    public var summary: String { "Lifecycle del recurso (borrador, activo, completo, cancelado, expirado, …)." }
    /// All Resource types own a status field. The catalog still has to
    /// enumerate the cases explicitly — `unknown` is omitted because it
    /// is the forward-compat sentinel, not a wireable type.
    public var enabledResourceTypes: [ResourceType] {
        [.event, .fund, .asset, .space, .slot, .right]
    }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "status", displayName: "Estado", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// description — free-text body shown as its own detail section
public struct DescriptionCapability: CapabilityBlock {
    public init() {}
    public var id: String { "description" }
    public var displayName: String { "Descripción" }
    public var summary: String { "Texto libre que describe el recurso." }
    public var enabledResourceTypes: [ResourceType] {
        [.event, .fund, .asset, .space, .slot, .right]
    }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [BuilderField(key: "description", label: "Descripción", kind: .multilineText)]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// host_actions — host-only action panel (reminders, edit, cancel, close, …).
// Section gates internally on viewer role; capability is always enabled for events.
public struct HostActionsCapability: CapabilityBlock {
    public init() {}
    public var id: String { "host_actions" }
    public var displayName: String { "Acciones del host" }
    public var summary: String { "Panel de acciones disponibles solo para el host del recurso." }
    public var enabledResourceTypes: [ResourceType] { [.event] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// location — physical place where the resource happens (lat/lng + name)
public struct LocationCapability: CapabilityBlock {
    public init() {}
    public var id: String { "location" }
    public var displayName: String { "Lugar" }
    public var summary: String { "Dirección o sitio físico donde sucede el recurso." }
    public var enabledResourceTypes: [ResourceType] { [.event, .slot, .asset] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "location_name", label: "Nombre del lugar", kind: .text),
            BuilderField(key: "location_lat", label: "Latitud", kind: .decimal),
            BuilderField(key: "location_lng", label: "Longitud", kind: .decimal)
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

// history — derived activity feed over system_events
public struct HistoryCapability: CapabilityBlock {
    public init() {}
    public var id: String { "history" }
    public var displayName: String { "Historial" }
    public var summary: String { "Bitácora de cambios del recurso, derivada de system_events." }
    public var enabledResourceTypes: [ResourceType] {
        [.event, .fund, .asset, .space, .slot, .right]
    }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "history.feed", label: "Historial", icon: "clock.arrow.circlepath")]
    }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "activity_feed", displayName: "Actividad", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// links — Fase 2 (mig 00232). Every resource is a node of the polymorphic
// graph; this cap surfaces the "Vinculado con…" section that lists in/
// out edges + the "+ Vincular" picker. Tier 0 per
// `Plans/Active/CapabilityTiers.md §2` — universal across the 6 types.
public struct LinksCapability: CapabilityBlock {
    public init() {}
    public var id: String { "links" }
    public var displayName: String { "Vinculaciones" }
    public var summary: String { "Conexiones de este recurso con otros del grupo." }
    public var enabledResourceTypes: [ResourceType] {
        [.event, .fund, .asset, .space, .slot, .right]
    }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "links.add", label: "Vincular", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "resource_links_view", displayName: "Vinculaciones", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// MARK: - Asset universal blocks (mig 00199 — canonical asset spec §8)
//
// The 7 capability blocks that make `resource_type='asset'` mean
// "objeto persistente socialmente gobernable" rather than "palco
// container for slots". Backed by mig 00200 RPCs (assign_custody,
// log_maintenance, record_valuation, transfer_asset, …) and mig
// 00201 projections (asset_current_custodian_view,
// asset_valuation_view, asset_maintenance_status_view,
// asset_usage_history_view).

// custody — who physically/operationally holds the asset
public struct CustodyCapability: CapabilityBlock {
    public init() {}
    public var id: String { "custody" }
    public var displayName: String { "Custodia" }
    public var summary: String { "Quién tiene físicamente el activo. Independiente de la propiedad." }
    public var enabledResourceTypes: [ResourceType] { [.asset] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [
            CapabilityAction(id: "custody.assign",  label: "Asignar custodio",  surface: .resourceDetail),
            CapabilityAction(id: "custody.release", label: "Liberar custodia",  surface: .resourceDetail)
        ]
    }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "custody.current", label: "Custodia", icon: "person.text.rectangle")]
    }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "current_custodian", displayName: "Custodio actual", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// maintenance — service / inspection / repair
public struct MaintenanceCapability: CapabilityBlock {
    public init() {}
    public var id: String { "maintenance" }
    public var displayName: String { "Mantenimiento" }
    public var summary: String { "Reportar daños, registrar reparaciones, recordar service." }
    public var enabledResourceTypes: [ResourceType] { [.asset, .space] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [
            CapabilityAction(id: "maintenance.log",    label: "Registrar mantenimiento", surface: .resourceDetail),
            CapabilityAction(id: "maintenance.report", label: "Reportar daño",            surface: .resourceDetail)
        ]
    }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "maintenance.list", label: "Mantenimiento", icon: "wrench.and.screwdriver")]
    }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "maintenance_status", displayName: "Mantenimiento", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// valuation — value-over-time append-only series
public struct ValuationCapability: CapabilityBlock {
    public init() {}
    public var id: String { "valuation" }
    public var displayName: String { "Valuación" }
    public var summary: String { "Registrar el valor del activo en el tiempo." }
    // Tier 0.5 per Plans/Active/CapabilityTiers.md §3. Only `asset` and
    // `fund` have intrinsic "how much am I worth" as a canonical concept.
    // `right` removed (was here from mig 00199): rights aren't valued
    // themselves; whatever value they represent lives in the underlying
    // resource they control. event/space/slot use budget/cost/price/
    // capacity-economics — semantically distinct from valuation.
    public var enabledResourceTypes: [ResourceType] { [.asset, .fund] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "valuation.record", label: "Registrar valor", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "valuation.history", label: "Valuación", icon: "chart.line.uptrend.xyaxis")]
    }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "current_valuation", displayName: "Valor actual", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// transfer — move ownership across members or to/from the group
public struct TransferCapability: CapabilityBlock {
    public init() {}
    public var id: String { "transfer" }
    public var displayName: String { "Transferencia" }
    public var summary: String { "Mover ownership del activo a otro miembro o al grupo." }
    public var enabledResourceTypes: [ResourceType] { [.asset, .right] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "transfer.execute", label: "Transferir", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "ownership", displayName: "Propiedad", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}

// access — who can use the asset and under what terms
public struct AccessCapability: CapabilityBlock {
    public init() {}
    public var id: String { "access" }
    public var displayName: String { "Acceso" }
    public var summary: String { "Quién puede usar el activo y bajo qué condiciones." }
    public var enabledResourceTypes: [ResourceType] { [.asset, .space, .right] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] { [] }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] { [] }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
    /// Spec §8 lists access; v1 catalog declares it but the runtime
    /// enforcement (per-member access lists, time windows, override)
    /// lives in a follow-up. Marked incomplete so the wizard hides it.
    public var status: CapabilityStatus {
        .incomplete(reason: "Asset spec §8: access list + time windows + override RPC pending.")
    }
}

// delegation — temporary loan to a non-custodian
public struct DelegationCapability: CapabilityBlock {
    public init() {}
    public var id: String { "delegation" }
    public var displayName: String { "Delegación" }
    public var summary: String { "Prestar el activo temporalmente a un no-custodio." }
    public var enabledResourceTypes: [ResourceType] { [.asset, .right] }
    public var requiredFields: [BuilderField] { [] }
    public var optionalFields: [BuilderField] { [] }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [
            CapabilityAction(id: "delegation.checkOut", label: "Prestar",   surface: .resourceDetail),
            CapabilityAction(id: "delegation.checkIn",  label: "Devolver",  surface: .resourceDetail)
        ]
    }
    public var routes: [CapabilityRoute] { [] }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "current_holder", displayName: "Quién lo tiene", scope: .resource)]
    }
    public var dependencies: [String] { ["custody"] }
    public var conflicts: [String] { [] }
    /// check_out_asset / check_in_asset RPCs ship in mig 00200 + the
    /// AssetLifecycleRepository. Marked stable; iOS surfaces the actions
    /// directly.
}

// inventory — count units of the asset
public struct InventoryCapability: CapabilityBlock {
    public init() {}
    public var id: String { "inventory" }
    public var displayName: String { "Inventario" }
    public var summary: String { "Contar unidades del activo (stock, cupos, copias)." }
    public var enabledResourceTypes: [ResourceType] { [.asset] }
    public var requiredFields: [BuilderField] {
        [BuilderField(key: "unitLabel", label: "Unidad", kind: .text, placeholder: "ej: piezas, kg, copias")]
    }
    public var optionalFields: [BuilderField] {
        [
            BuilderField(key: "currentCount", label: "Stock actual", kind: .integer),
            BuilderField(key: "lowStockThreshold", label: "Umbral mínimo", kind: .integer)
        ]
    }
    public var suggestedRules: [RuleTemplate] { [] }
    public var actions: [CapabilityAction] {
        [CapabilityAction(id: "inventory.recordUsage", label: "Registrar uso", surface: .resourceDetail)]
    }
    public var routes: [CapabilityRoute] {
        [CapabilityRoute(id: "inventory.summary", label: "Inventario", icon: "shippingbox")]
    }
    public var permissions: [Permission] { [] }
    public var projections: [ProjectionDescriptor] {
        [ProjectionDescriptor(id: "stock_count", displayName: "Stock", scope: .resource)]
    }
    public var dependencies: [String] { [] }
    public var conflicts: [String] { [] }
}
