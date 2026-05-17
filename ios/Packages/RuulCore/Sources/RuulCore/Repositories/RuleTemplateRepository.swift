import Foundation
import Supabase

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum RuleTemplateError: Error, Equatable, Sendable {
    case rpcFailed(String)
    case decodingFailed(String)
}

/// Repository for the Beta 1 Rule Builder. Loads the curated template
/// catalog from `public.rule_templates` and publishes new rules via the
/// `publish_rule_version` RPC (mig 00171).
///
/// Single-responsibility: separate from `RuleRepository` (which mutates
/// existing rules + reads per-resource) because publishing is a distinct
/// flow with its own RPC contract and result envelope.
///
/// Per Plans/Active/Governance.md §0.5 + §10 (Builder UX).
public protocol RuleTemplateRepository: Actor {
    /// Loads the active template catalog, optionally filtered by the
    /// resource type the caller is building a rule for. When
    /// `resourceType` is nil the server returns every active template
    /// (group-scope gallery). When non-nil, the server filters out
    /// templates whose trigger shape doesn't list that type in
    /// `valid_resource_types` (mig 00244) — keeping event-only
    /// templates out of an asset's gallery, etc.
    ///
    /// iOS calls the nil overload at boot (AppState wiring); per-resource
    /// builders call with the concrete type. Output sorted by
    /// `sort_order` then name.
    func loadTemplates(forResourceType resourceType: String?) async throws -> [RuleBuilderTemplate]

    /// Publishes a new rule from a template + user params. Returns the
    /// new rule_id + rule_version_id + any warning conflicts the server
    /// detected. Beta 1: caller must be group admin; same_scope_overlapping
    /// surfaces as warning (UI confirms before publish).
    func publishRuleVersion(
        groupId: UUID,
        templateId: String,
        shapeParams: JSONConfig,
        scope: RuleTemplateScope,
        title: String?,
        changeReason: String?
    ) async throws -> RuleVersionPublishResult

    /// Publishes a free-composition rule. Caller picks the trigger + N
    /// conditions + N consequences directly from the shape catalog —
    /// no template required. Powers the Rule Composer flow.
    ///
    /// Server-side validation (mig 00245):
    /// - Has modifyRules permission
    /// - Trigger compatible with scope.type + resource's resource_type
    /// - Every shape id exists in rule_shapes with the right kind
    /// - At least one consequence
    ///
    /// Returns the same envelope as `publishRuleVersion`: rule id +
    /// version id + any same_scope_overlapping warnings.
    func publishRuleComposition(
        groupId: UUID,
        draft: RuleDraft
    ) async throws -> RuleVersionPublishResult
}

public extension RuleTemplateRepository {
    /// Convenience: load the full catalog (no resource_type filter).
    /// Backward-compatible wrapper for the original `loadTemplates()`
    /// signature — keeps existing call sites (notably AppState's boot
    /// load) working unchanged.
    func loadTemplates() async throws -> [RuleBuilderTemplate] {
        try await loadTemplates(forResourceType: nil)
    }
}

// MARK: - Mock

public actor MockRuleTemplateRepository: RuleTemplateRepository {
    public private(set) var lastPublishCall: (groupId: UUID, templateId: String, params: JSONConfig, scope: RuleTemplateScope)?
    private var stubTemplates: [RuleBuilderTemplate]
    public var nextPublishError: RuleTemplateError?

    public init(templates: [RuleBuilderTemplate] = MockRuleTemplateRepository.defaultBetaCatalog) {
        self.stubTemplates = templates
    }

    public func loadTemplates(forResourceType resourceType: String?) async throws -> [RuleBuilderTemplate] {
        let sorted = stubTemplates.sorted { $0.sortOrder < $1.sortOrder }
        // Mock honors the same filter contract as the server (mig 00244):
        // null → all; non-null → only templates whose trigger shape
        // declares the requested resource_type as valid. The mock can't
        // peek into the shape registry, so it approximates by checking
        // a static type map keyed on triggerShapeId. Sufficient for
        // previews + unit tests; live behavior is enforced server-side.
        guard let resourceType else { return sorted }
        return sorted.filter { template in
            let valid = MockRuleTemplateRepository.triggerResourceTypes[template.composition.triggerShapeId]
            // Unknown trigger or universal trigger → let it through.
            guard let valid, !valid.isEmpty else { return true }
            return valid.contains(resourceType)
        }
    }

    /// Static mirror of `rule_shapes.valid_resource_types` used by the
    /// Mock to filter `loadTemplates(forResourceType:)` the same way the
    /// server does. Kept in sync by hand — diverges only when a new
    /// trigger lands in rule_shapes; add the entry here so previews
    /// match prod.
    private static let triggerResourceTypes: [String: [String]] = [
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

    public func publishRuleVersion(
        groupId: UUID,
        templateId: String,
        shapeParams: JSONConfig,
        scope: RuleTemplateScope,
        title: String?,
        changeReason: String?
    ) async throws -> RuleVersionPublishResult {
        if let err = nextPublishError { nextPublishError = nil; throw err }
        lastPublishCall = (groupId, templateId, shapeParams, scope)
        guard stubTemplates.contains(where: { $0.id == templateId }) else {
            throw RuleTemplateError.rpcFailed("template \(templateId) not in mock catalog")
        }
        return RuleVersionPublishResult(
            ruleId: UUID(),
            ruleVersionId: UUID(),
            version: 1,
            conflicts: []
        )
    }

    public private(set) var lastCompositionCall: (groupId: UUID, draft: RuleDraft)?

    public func publishRuleComposition(
        groupId: UUID,
        draft: RuleDraft
    ) async throws -> RuleVersionPublishResult {
        if let err = nextPublishError { nextPublishError = nil; throw err }
        lastCompositionCall = (groupId, draft)
        guard draft.isPublishable else {
            throw RuleTemplateError.rpcFailed("draft is incomplete (name/trigger/consequence missing)")
        }
        return RuleVersionPublishResult(
            ruleId: UUID(),
            ruleVersionId: UUID(),
            version: 1,
            conflicts: []
        )
    }

    /// Seed catalog mirroring mig 00171's 5 Beta 1 templates. Lets previews
    /// and tests render the gallery without round-tripping to Supabase.
    public static let defaultBetaCatalog: [RuleBuilderTemplate] = [
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
                scopeHint: "series"
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
                scopeHint: "series"
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
                scopeHint: "series"
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
                scopeHint: "series"
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
                scopeHint: "series"
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
                scopeHint: "group"
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
                scopeHint: "group"
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
                scopeHint: "resource"
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
                scopeHint: "resource"
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
                scopeHint: "resource"
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
                scopeHint: "resource"
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
                scopeHint: "resource"
            ),
            sortOrder: 120
        )
    ]
}

// MARK: - Live

public actor LiveRuleTemplateRepository: RuleTemplateRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func loadTemplates(forResourceType resourceType: String?) async throws -> [RuleBuilderTemplate] {
        struct Params: Encodable {
            let p_resource_type: String?
        }
        do {
            return try await client
                .rpc("list_rule_templates", params: Params(p_resource_type: resourceType))
                .execute()
                .value
        } catch {
            throw RuleTemplateError.rpcFailed(error.localizedDescription)
        }
    }

    public func publishRuleVersion(
        groupId: UUID,
        templateId: String,
        shapeParams: JSONConfig,
        scope: RuleTemplateScope,
        title: String?,
        changeReason: String?
    ) async throws -> RuleVersionPublishResult {
        struct Params: Encodable {
            let p_group_id: String
            let p_template_id: String
            let p_shape_params: JSONConfig
            let p_scope: JSONConfig
            let p_title: String?
            let p_change_reason: String?
        }
        let params = Params(
            p_group_id: groupId.uuidString.lowercased(),
            p_template_id: templateId,
            p_shape_params: shapeParams,
            p_scope: RuleBuilderTemplate.scopeJSON(scope),
            p_title: title,
            p_change_reason: changeReason
        )
        do {
            return try await client
                .rpc("publish_rule_version", params: params)
                .execute()
                .value
        } catch {
            throw RuleTemplateError.rpcFailed(error.localizedDescription)
        }
    }

    public func publishRuleComposition(
        groupId: UUID,
        draft: RuleDraft
    ) async throws -> RuleVersionPublishResult {
        guard let triggerInstance = draft.trigger else {
            throw RuleTemplateError.rpcFailed("draft has no trigger")
        }
        guard !draft.consequences.isEmpty else {
            throw RuleTemplateError.rpcFailed("draft has no consequences")
        }

        struct ShapePayload: Encodable {
            let shape_id: String
            let config: JSONConfig
        }
        struct Params: Encodable {
            let p_group_id: String
            let p_name: String
            let p_scope: JSONConfig
            let p_trigger: ShapePayload
            let p_conditions: [ShapePayload]
            let p_consequences: [ShapePayload]
            let p_change_reason: String?
            let p_slug: String?
        }

        let params = Params(
            p_group_id: groupId.uuidString.lowercased(),
            p_name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            p_scope: RuleBuilderTemplate.scopeJSON(draft.scope),
            p_trigger: ShapePayload(shape_id: triggerInstance.shapeId, config: triggerInstance.config),
            p_conditions: draft.conditions.map { ShapePayload(shape_id: $0.shapeId, config: $0.config) },
            p_consequences: draft.consequences.map { ShapePayload(shape_id: $0.shapeId, config: $0.config) },
            p_change_reason: draft.changeReason.isEmpty ? nil : draft.changeReason,
            p_slug: draft.slug?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )

        do {
            return try await client
                .rpc("publish_rule_composition", params: params)
                .execute()
                .value
        } catch {
            throw RuleTemplateError.rpcFailed(error.localizedDescription)
        }
    }
}
