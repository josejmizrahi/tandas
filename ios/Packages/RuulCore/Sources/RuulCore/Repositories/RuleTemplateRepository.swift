import Foundation
import Supabase

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
    /// Loads the active template catalog. Sorted by `sort_order` then name.
    /// iOS calls this at boot (AppState wiring) — output drives the
    /// Template Gallery UI.
    func loadTemplates() async throws -> [RuleBuilderTemplate]

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
}

// MARK: - Mock

public actor MockRuleTemplateRepository: RuleTemplateRepository {
    public private(set) var lastPublishCall: (groupId: UUID, templateId: String, params: JSONConfig, scope: RuleTemplateScope)?
    private var stubTemplates: [RuleBuilderTemplate]
    public var nextPublishError: RuleTemplateError?

    public init(templates: [RuleBuilderTemplate] = MockRuleTemplateRepository.defaultBetaCatalog) {
        self.stubTemplates = templates
    }

    public func loadTemplates() async throws -> [RuleBuilderTemplate] {
        stubTemplates.sorted { $0.sortOrder < $1.sortOrder }
    }

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
        )
    ]
}

// MARK: - Live

public actor LiveRuleTemplateRepository: RuleTemplateRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func loadTemplates() async throws -> [RuleBuilderTemplate] {
        do {
            return try await client
                .rpc("list_rule_templates")
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
}
