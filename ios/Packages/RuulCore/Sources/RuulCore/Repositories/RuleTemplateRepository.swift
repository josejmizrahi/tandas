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

    /// Edits an existing rule in place: supersedes the active
    /// rule_version and inserts a new one with version+1 + same
    /// `rule_id`. Preserves slug + scope; only trigger / conditions /
    /// consequences (and name) change. Powers the §22.1 edit flow.
    ///
    /// Server-side (mig 00247) validates `has_permission('modifyRules')`,
    /// shape compatibility against the rule's preserved scope, and
    /// re-runs conflict detection excluding the version being
    /// superseded. Returns the same envelope as publish, with
    /// `rule_id` unchanged.
    func bumpRuleVersion(
        ruleId: UUID,
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

    public init(templates: [RuleBuilderTemplate] = RuleTemplateCatalog.defaults) {
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
            let valid = RuleTemplateCatalog.triggerResourceTypes[template.composition.triggerShapeId]
            // Unknown trigger or universal trigger → let it through.
            guard let valid, !valid.isEmpty else { return true }
            return valid.contains(resourceType)
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
    public private(set) var lastBumpCall: (ruleId: UUID, draft: RuleDraft)?
    /// Per-ruleId version counter to make bumps look incremental in
    /// previews/tests. Persists across calls.
    private var bumpVersionCounter: [UUID: Int] = [:]

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

    public func bumpRuleVersion(
        ruleId: UUID,
        draft: RuleDraft
    ) async throws -> RuleVersionPublishResult {
        if let err = nextPublishError { nextPublishError = nil; throw err }
        lastBumpCall = (ruleId, draft)
        guard draft.isPublishable else {
            throw RuleTemplateError.rpcFailed("draft is incomplete (name/trigger/consequence missing)")
        }
        let nextVersion = (bumpVersionCounter[ruleId] ?? 1) + 1
        bumpVersionCounter[ruleId] = nextVersion
        return RuleVersionPublishResult(
            ruleId: ruleId,
            ruleVersionId: UUID(),
            version: nextVersion,
            slug: draft.slug,
            conflicts: []
        )
    }

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

        struct Params: Encodable {
            let p_group_id: String
            let p_name: String
            let p_scope: JSONConfig
            let p_trigger: ShapePayload
            // §22.4 (mig 00251): either a flat array of ShapePayload
            // leaves (legacy/Simple mode) or a `{op,children}` tree
            // (Avanzado mode). ConditionsPayload picks the encoding
            // at runtime from the draft state.
            let p_conditions: ConditionsPayload
            let p_consequences: [ShapePayload]
            let p_change_reason: String?
            let p_slug: String?
            let p_exceptions: [ShapePayload]
            // Mig 00250 / §22.5: orthogonal membership filter. When non-nil,
            // engine restricts targets to this single `group_members.id`.
            let p_membership_id: String?
        }

        let params = Params(
            p_group_id: groupId.uuidString.lowercased(),
            p_name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            p_scope: RuleBuilderTemplate.scopeJSON(draft.scope),
            p_trigger: ShapePayload(shape_id: triggerInstance.shapeId, config: triggerInstance.config, target: nil),
            p_conditions: Self.conditionsPayload(from: draft),
            p_consequences: draft.consequences.map { ShapePayload(shape_id: $0.shapeId, config: $0.config, target: $0.target) },
            p_change_reason: draft.changeReason.isEmpty ? nil : draft.changeReason,
            p_slug: draft.slug?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            p_exceptions: draft.exceptions.map { ShapePayload(shape_id: $0.shapeId, config: $0.config, target: nil) },
            p_membership_id: draft.membershipFilter?.uuidString.lowercased()
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

    public func bumpRuleVersion(
        ruleId: UUID,
        draft: RuleDraft
    ) async throws -> RuleVersionPublishResult {
        guard let triggerInstance = draft.trigger else {
            throw RuleTemplateError.rpcFailed("draft has no trigger")
        }
        guard !draft.consequences.isEmpty else {
            throw RuleTemplateError.rpcFailed("draft has no consequences")
        }

        struct Params: Encodable {
            let p_rule_id: String
            let p_name: String
            let p_trigger: ShapePayload
            // §22.4 (mig 00251): array or tree, same shape as publish.
            let p_conditions: ConditionsPayload
            let p_consequences: [ShapePayload]
            let p_change_reason: String?
            let p_exceptions: [ShapePayload]
            // Mig 00250 / §22.5: composer is authoritative — always assert
            // the membership state explicitly. nil filter → clear=true;
            // non-nil → send id + clear=false. Server's "preserve" mode
            // (clear=false + null id) is for callers that don't hold the
            // full draft; we always hold it.
            let p_membership_id: String?
            let p_clear_membership: Bool
        }

        // Bump always sends p_exceptions (even if empty) so the server
        // sees the draft's authoritative current view. Server-side null
        // would mean "preserve previous"; since the composer holds the
        // full state, we explicitly assert it.
        let params = Params(
            p_rule_id: ruleId.uuidString.lowercased(),
            p_name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            p_trigger: ShapePayload(shape_id: triggerInstance.shapeId, config: triggerInstance.config, target: nil),
            p_conditions: Self.conditionsPayload(from: draft),
            p_consequences: draft.consequences.map { ShapePayload(shape_id: $0.shapeId, config: $0.config, target: $0.target) },
            p_change_reason: draft.changeReason.isEmpty ? nil : draft.changeReason,
            p_exceptions: draft.exceptions.map { ShapePayload(shape_id: $0.shapeId, config: $0.config, target: nil) },
            p_membership_id: draft.membershipFilter?.uuidString.lowercased(),
            p_clear_membership: draft.membershipFilter == nil
        )

        do {
            return try await client
                .rpc("bump_rule_version", params: params)
                .execute()
                .value
        } catch {
            throw RuleTemplateError.rpcFailed(error.localizedDescription)
        }
    }

    // MARK: §22.4 — conditions payload (flat array OR tree)

    /// One shape leaf as it appears on the wire — shared by trigger /
    /// flat conditions / consequences / exceptions and re-used inside
    /// tree leaves.
    fileprivate struct ShapePayload: Encodable {
        let shape_id: String
        let config: JSONConfig
        // Optional target — only meaningful for consequences (mig 00249,
        // §22.3). Encoded only when non-nil so trigger/condition/
        // exception payloads stay compact.
        let target: String?
    }

    /// Polymorphic payload for `p_conditions`: encodes as a JSON array
    /// of leaves (Simple mode / legacy wire) or as a `{op,children}`
    /// AND/OR/NOT tree (Avanzado mode, mig 00251). The server's
    /// `compile_condition_tree` + `validate_condition_node` accept
    /// both shapes — picking at encode time is the cleanest way to
    /// keep one RPC path.
    fileprivate enum ConditionsPayload: Encodable {
        case flat([ShapePayload])
        case tree(ShapeNode)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .flat(let leaves):
                var c = encoder.singleValueContainer()
                try c.encode(leaves)
            case .tree(let node):
                var c = encoder.singleValueContainer()
                try c.encode(node)
            }
        }
    }

    fileprivate static func conditionsPayload(from draft: RuleDraft) -> ConditionsPayload {
        // §22.4: send the tree when the composer was in Avanzado mode
        // AND the tree carries OR/NOT structure that would be lost as
        // a flat array. A pure `.and([leaves])` tree round-trips
        // identically to the flat path, so we emit the legacy array
        // shape — keeps `rule_versions.compiled.conditions` unchanged
        // for the common case.
        if let tree = draft.conditionsTree, !tree.isFlatAnd {
            return .tree(tree)
        }
        return .flat(draft.conditions.map {
            ShapePayload(shape_id: $0.shapeId, config: $0.config, target: nil)
        })
    }
}
