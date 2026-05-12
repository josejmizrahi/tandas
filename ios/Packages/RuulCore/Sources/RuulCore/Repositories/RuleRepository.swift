import Foundation
import Supabase

public enum RuleError: Error, Equatable {
    case rpcFailed(String)
}

public enum RulesRepositoryError: Error {
    case notFlatFine
    case rlsDenied
    case other(Error)
}

/// Lightweight Vote projection for the pending-repeal badge.
public struct PendingVote: Sendable, Hashable {
    public let id: UUID
    public let referenceId: UUID
    public let closesAt: Date

    public init(id: UUID, referenceId: UUID, closesAt: Date) {
        self.id = id
        self.referenceId = referenceId
        self.closesAt = closesAt
    }
}

/// Return type from the create-initial-rule and seed-template-rules RPCs.
/// Carries only platform fields after Slice E.2 dropped the legacy columns.
/// `slug` is optional because user-authored rules (Phase 4) won't have one.
public struct OnboardingRule: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let slug: String?
    public let name: String
    public let isActive: Bool

    public init(id: UUID, groupId: UUID, slug: String?, name: String, isActive: Bool) {
        self.id = id
        self.groupId = groupId
        self.slug = slug
        self.name = name
        self.isActive = isActive
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId  = "group_id"
        case slug
        case name
        case isActive = "is_active"
    }
}

public protocol RuleRepository: Actor {
    /// Creates only the active drafts. Returns the created rules.
    func createInitialRules(groupId: UUID, drafts: [RuleDraft]) async throws -> [OnboardingRule]

    /// Seeds the platform-shape default rules for `templateId`. Post mig
    /// 00075 this is an orchestrator that reads `groups.active_modules`
    /// and delegates to `seed_module_rules` per slug — the inserted rows
    /// carry `module_key` so the engine and archive cascade can identify
    /// ownership. Idempotent.
    func seedTemplateRules(templateId: String, groupId: UUID) async throws -> [OnboardingRule]

    /// Seeds the rules for a single module activation. Reads
    /// `modules.provided_rules_def[slug]` and upserts into `public.rules`
    /// with `module_key = moduleSlug`. Idempotent (re-enables archived
    /// rules instead of duplicating). Mirror of mig 00073's RPC; called
    /// when a module is toggled on outside the bulk template path
    /// (Phase E progressive onboarding).
    func seedModuleRules(moduleSlug: String, groupId: UUID) async throws -> [OnboardingRule]

    /// Read-only list of all rules for a group, ordered by creation time.
    /// Used by the Reglas tab to show the active group's rules.
    func list(groupId: UUID) async throws -> [GroupRule]

    /// Rules scoped to a single resource (`rules.resource_id`). Powers the
    /// per-event Rules section. Newest first so freshly authored rules
    /// surface immediately.
    func listForResource(_ resourceId: UUID) async throws -> [GroupRule]

    /// All rules applicable to a given resource in scope order: rules
    /// with `resource_id = resourceId`, plus rules from the resource's
    /// series, plus rules from the resource's group. Caller can bucket
    /// by inspecting each rule's `scope` (computed property). Powers R2
    /// inherited rules sections. Polymorphic over resource type — the
    /// same call works for events, assets, funds, etc.
    func listScopedForResource(_ resourceId: UUID) async throws -> [GroupRule]

    /// Creates a user-authored rule scoped to `resourceId` via the
    /// `create_resource_rule` RPC (mig 00086). Caller must be group
    /// admin or (for events) the event host. Server validates resource
    /// ownership + authorization. iOS just forwards the form.
    func createResourceRule(
        groupId: UUID,
        resourceId: UUID,
        name: String,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [RuleConsequence]
    ) async throws -> GroupRule

    /// Toggles `is_active`. Postgres trigger emits ruleEnabledChanged.
    func setIsActive(ruleId: UUID, isActive: Bool) async throws

    /// Updates the flat fine amount. Caller must pre-validate via
    /// `rule.fineShape == .flat`. Throws `.notFlatFine` if the rule is
    /// escalating or unknown shape. Postgres trigger emits ruleAmountChanged.
    func setFlatFineAmount(rule: GroupRule, amount: Int) async throws

    /// Returns the open rule_repeal vote for a rule, if any.
    func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote?
}

// MARK: - Mock

public actor MockRuleRepository: RuleRepository {
    public private(set) var lastCreatedDrafts: [RuleDraft] = []
    public init() {}
    public var nextCreateError: RuleError?

    public func createInitialRules(groupId: UUID, drafts: [RuleDraft]) async throws -> [OnboardingRule] {
        if let err = nextCreateError { nextCreateError = nil; throw err }
        let active = drafts.filter(\.isActive)
        lastCreatedDrafts = active
        return active.map { d -> OnboardingRule in
            OnboardingRule(
                id: UUID(),
                groupId: groupId,
                slug: d.slug,
                name: d.name,
                isActive: true
            )
        }
    }

    public func seedTemplateRules(templateId: String, groupId: UUID) async throws -> [OnboardingRule] {
        // Mock returns 5 fake rows so previews/tests see expected counts.
        // Only `recurring_dinner` has a known iOS-side mock catalog; other
        // templates would require their own template files (Phase 2+).
        guard templateId == "recurring_dinner" else { return [] }
        return DinnerRecurringTemplate.defaultRules(groupId: groupId).map {
            OnboardingRule(
                id: $0.id,
                groupId: groupId,
                slug: $0.slug,
                name: $0.name,
                isActive: $0.isActive
            )
        }
    }

    public func seedModuleRules(moduleSlug: String, groupId: UUID) async throws -> [OnboardingRule] {
        // Mock: only basic_fines has a known iOS-side rule catalog
        // (the dinner_* rules). Other modules return empty until their
        // catalogs ship in Phase 2+.
        guard moduleSlug == "basic_fines" else { return [] }
        return DinnerRecurringTemplate.defaultRules(groupId: groupId).map {
            OnboardingRule(
                id: $0.id,
                groupId: groupId,
                slug: $0.slug,
                name: $0.name,
                isActive: $0.isActive
            )
        }
    }

    public func list(groupId: UUID) async throws -> [GroupRule] {
        // Empty in mock — RulesView shows the empty state.
        []
    }

    public private(set) var mockEventRules: [GroupRule] = []

    public func listForResource(_ resourceId: UUID) async throws -> [GroupRule] {
        mockEventRules.filter { $0.resourceId == resourceId }
    }

    public func listScopedForResource(_ resourceId: UUID) async throws -> [GroupRule] {
        // Mock returns the resource-scoped subset only. Tests/previews
        // exercising inherited rules should pre-populate the mock with
        // series/group-scoped rules; the bucketing in the coordinator
        // will pick them up.
        mockEventRules.filter { $0.resourceId == resourceId }
    }

    public func createResourceRule(
        groupId: UUID,
        resourceId: UUID,
        name: String,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [RuleConsequence]
    ) async throws -> GroupRule {
        let envelopes = consequences.map { c -> GroupRule.ConsequenceEnvelope in
            // Mock projection: only `fine` carries an amount we can lift
            // from the JSONConfig payload; other types decode as nil amount.
            let amount: Int? = {
                guard c.type == .fine, case let .int(value) = c.config["amount"] else {
                    return nil
                }
                return value
            }()
            return GroupRule.ConsequenceEnvelope(
                type: c.type.rawString,
                config: .init(
                    amount: amount,
                    baseAmount: nil,
                    stepAmount: nil,
                    stepMinutes: nil
                )
            )
        }
        let rule = GroupRule(
            id: UUID(),
            groupId: groupId,
            slug: nil,
            name: name,
            isActive: true,
            trigger: trigger,
            conditions: conditions,
            consequences: envelopes,
            moduleKey: nil,
            resourceId: resourceId
        )
        mockEventRules.insert(rule, at: 0)
        return rule
    }

    public private(set) var lastSetIsActive: (ruleId: UUID, isActive: Bool)?
    public private(set) var lastSetAmount: (ruleId: UUID, amount: Int)?

    public func setIsActive(ruleId: UUID, isActive: Bool) async throws {
        lastSetIsActive = (ruleId, isActive)
    }

    public func setFlatFineAmount(rule: GroupRule, amount: Int) async throws {
        guard case .flat = rule.fineShape else { throw RulesRepositoryError.notFlatFine }
        lastSetAmount = (rule.id, amount)
    }

    public func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote? {
        nil
    }
}

// MARK: - Live

public actor LiveRuleRepository: RuleRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func createInitialRules(groupId: UUID, drafts: [RuleDraft]) async throws -> [OnboardingRule] {
        struct Params: Encodable {
            let p_group_id: String
            let p_slug: String
            let p_name: String
            let p_is_active: Bool
            let p_trigger: RuleTrigger
            let p_conditions: [RuleCondition]
            let p_consequences: [RuleConsequence]
        }

        var rules: [OnboardingRule] = []
        for draft in drafts where draft.isActive {
            let p = Params(
                p_group_id: groupId.uuidString.lowercased(),
                p_slug: draft.slug,
                p_name: draft.name,
                p_is_active: draft.isActive,
                p_trigger: draft.trigger,
                p_conditions: draft.conditions,
                p_consequences: draft.consequences
            )
            do {
                let rule: OnboardingRule = try await client
                    .rpc("create_initial_rule", params: p)
                    .execute()
                    .value
                rules.append(rule)
            } catch {
                throw RuleError.rpcFailed(error.localizedDescription)
            }
        }
        return rules
    }

    public func seedTemplateRules(templateId: String, groupId: UUID) async throws -> [OnboardingRule] {
        struct Params: Encodable {
            let p_template_id: String
            let p_group_id: String
        }
        do {
            return try await client
                .rpc("seed_template_rules", params: Params(
                    p_template_id: templateId,
                    p_group_id: groupId.uuidString.lowercased()
                ))
                .execute()
                .value
        } catch {
            throw RuleError.rpcFailed(error.localizedDescription)
        }
    }

    public func seedModuleRules(moduleSlug: String, groupId: UUID) async throws -> [OnboardingRule] {
        struct Params: Encodable {
            let p_group_id: String
            let p_module_slug: String
        }
        do {
            return try await client
                .rpc("seed_module_rules", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_module_slug: moduleSlug
                ))
                .execute()
                .value
        } catch {
            throw RuleError.rpcFailed(error.localizedDescription)
        }
    }

    public func list(groupId: UUID) async throws -> [GroupRule] {
        try await client
            .from("rules")
            .select("id,group_id,slug,name,is_active,trigger,conditions,consequences,module_key,resource_id,series_id,membership_id")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    public func listForResource(_ resourceId: UUID) async throws -> [GroupRule] {
        try await client
            .from("rules")
            .select("id,group_id,slug,name,is_active,trigger,conditions,consequences,module_key,resource_id,series_id,membership_id")
            .eq("resource_id", value: resourceId.uuidString.lowercased())
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    public func listScopedForResource(_ resourceId: UUID) async throws -> [GroupRule] {
        struct Params: Encodable { let p_resource_id: String }
        do {
            return try await client
                .rpc("list_resource_rules_with_inherited", params: Params(
                    p_resource_id: resourceId.uuidString.lowercased()
                ))
                .execute()
                .value
        } catch {
            throw RuleError.rpcFailed(error.localizedDescription)
        }
    }

    public func createResourceRule(
        groupId: UUID,
        resourceId: UUID,
        name: String,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [RuleConsequence]
    ) async throws -> GroupRule {
        struct Params: Encodable {
            let p_group_id: String
            let p_resource_id: String
            let p_name: String
            let p_trigger: RuleTrigger
            let p_conditions: [RuleCondition]
            let p_consequences: [RuleConsequence]
        }
        do {
            return try await client
                .rpc("create_resource_rule", params: Params(
                    p_group_id: groupId.uuidString.lowercased(),
                    p_resource_id: resourceId.uuidString.lowercased(),
                    p_name: name,
                    p_trigger: trigger,
                    p_conditions: conditions,
                    p_consequences: consequences
                ))
                .execute()
                .value
        } catch {
            throw RuleError.rpcFailed(error.localizedDescription)
        }
    }

    public func setIsActive(ruleId: UUID, isActive: Bool) async throws {
        struct Body: Encodable { let is_active: Bool }
        do {
            _ = try await client.from("rules")
                .update(Body(is_active: isActive))
                .eq("id", value: ruleId.uuidString.lowercased())
                .execute()
        } catch {
            throw RulesRepositoryError.other(error)
        }
    }

    public func setFlatFineAmount(rule: GroupRule, amount: Int) async throws {
        guard case .flat = rule.fineShape else { throw RulesRepositoryError.notFlatFine }

        struct ConsequenceBody: Encodable {
            let type: String
            let config: ConfigBody
        }
        struct ConfigBody: Encodable { let amount: Int }
        struct Body: Encodable { let consequences: [ConsequenceBody] }

        do {
            _ = try await client.from("rules")
                .update(Body(consequences: [
                    ConsequenceBody(type: "fine", config: ConfigBody(amount: amount))
                ]))
                .eq("id", value: rule.id.uuidString.lowercased())
                .execute()
        } catch {
            throw RulesRepositoryError.other(error)
        }
    }

    public func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote? {
        struct Row: Decodable {
            let id: UUID
            let reference_id: UUID
            let closes_at: Date
        }
        let rows: [Row] = try await client.from("votes")
            .select("id, reference_id, closes_at")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .eq("vote_type", value: "rule_repeal")
            .eq("reference_id", value: ruleId.uuidString.lowercased())
            .eq("status", value: "open")
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return nil }
        return PendingVote(id: row.id, referenceId: row.reference_id, closesAt: row.closes_at)
    }
}

// MARK: - Governance-aware mutation outcomes (Phase 1)

/// Result of an intercepted rule mutation. Callers branch on this to render
/// the right toast: "Cambio aplicado" vs "Cambio pendiente de votación".
public enum RuleMutationOutcome: Sendable, Hashable {
    /// The change was written directly. Local optimistic state already
    /// matches the new server state.
    case applied
    /// A vote was opened instead. The local optimistic state must be
    /// reverted; the change applies when the vote resolves passed (server
    /// trigger `votes_apply_on_pass_trg`, mig 00089).
    case vote(voteId: UUID)
    /// Caller doesn't have `Permission.modifyRules` and the policy is
    /// `admin_only`. Local state must be reverted; surface "solo admins".
    case adminOnly
}

public enum RuleMutationError: Error, Sendable, Equatable {
    case denied(reason: String)
    case voteOpenFailed(String)
    case underlying(String)
}

/// Wraps an inner `RuleRepository` and consults `GroupPolicyRepository`
/// before every mutation. When the resolver returns `.voteRequired`, opens
/// a `vote_type = rule_change` carrying a `PendingChangeEnvelope` so the
/// server trigger can auto-apply the diff on resolution=passed. Otherwise
/// delegates to the inner repo.
///
/// Compose at the AppState seam: the rest of the codebase keeps talking to
/// `RuleRepository`. The governance-aware mutation methods
/// (`setIsActive(_:isActive:groupId:currentIsActive:)` and the analogous
/// amount one) are NEW surface — call sites adopt them gradually. The
/// non-governance methods (`list`, `listForResource`, `pendingRepealVote`,
/// …) pass through to `inner` untouched, so this actor is also a drop-in
/// `RuleRepository` for the read side.
public actor InterceptingRuleRepository: RuleRepository {
    private let inner: any RuleRepository
    private let policyRepo: any GroupPolicyRepository
    private let voteRepo: any VoteRepository
    private let actorUserId: UUID

    public init(
        inner: any RuleRepository,
        policyRepo: any GroupPolicyRepository,
        voteRepo: any VoteRepository,
        actorUserId: UUID
    ) {
        self.inner = inner
        self.policyRepo = policyRepo
        self.voteRepo = voteRepo
        self.actorUserId = actorUserId
    }

    // MARK: Governance-aware mutations

    /// Toggles `is_active` with governance check.
    /// - parameter currentIsActive: the value before the user's tap;
    ///   needed to compose the `before` half of the audit envelope.
    public func setIsActive(
        ruleId: UUID,
        isActive: Bool,
        groupId: UUID,
        currentIsActive: Bool
    ) async throws -> RuleMutationOutcome {
        let decision = try await policyRepo.resolve(
            groupId: groupId,
            actorUserId: actorUserId,
            action: .ruleToggle,
            targetPayload: ["rule_id": ruleId.uuidString.lowercased()]
        )
        switch decision {
        case .allowed:
            try await inner.setIsActive(ruleId: ruleId, isActive: isActive)
            return .applied

        case .voteRequired(let q, let t, _):
            let envelope = PendingChangeEnvelope.ruleToggle(
                targetRuleId: ruleId,
                before: .init(isActive: currentIsActive),
                after:  .init(isActive: isActive)
            )
            let payload: JSONConfig
            do {
                payload = try JSONConfig.encoded(envelope)
            } catch {
                throw RuleMutationError.underlying(error.localizedDescription)
            }
            do {
                let voteId = try await voteRepo.startVote(
                    groupId: groupId,
                    voteType: .ruleChange,
                    referenceId: ruleId,
                    title: isActive ? "Activar regla" : "Desactivar regla",
                    description: nil,
                    payload: payload
                )
                _ = (q, t)  // quorum/threshold are server-driven via the vote row
                return .vote(voteId: voteId)
            } catch {
                throw RuleMutationError.voteOpenFailed(error.localizedDescription)
            }

        case .adminOnly:
            return .adminOnly

        case .denied(let reason):
            throw RuleMutationError.denied(reason: reason)
        }
    }

    /// Updates a flat-fine amount with governance check.
    /// - parameter currentAmount: pre-change value for the audit envelope.
    public func setFlatFineAmount(
        rule: GroupRule,
        amount: Int,
        currentAmount: Int
    ) async throws -> RuleMutationOutcome {
        let decision = try await policyRepo.resolve(
            groupId: rule.groupId,
            actorUserId: actorUserId,
            action: .ruleUpdateAmount,
            targetPayload: ["rule_id": rule.id.uuidString.lowercased()]
        )
        switch decision {
        case .allowed:
            try await inner.setFlatFineAmount(rule: rule, amount: amount)
            return .applied

        case .voteRequired:
            let envelope = PendingChangeEnvelope.ruleUpdateAmount(
                targetRuleId: rule.id,
                before: .init(amount: currentAmount),
                after:  .init(amount: amount)
            )
            let payload: JSONConfig
            do {
                payload = try JSONConfig.encoded(envelope)
            } catch {
                throw RuleMutationError.underlying(error.localizedDescription)
            }
            do {
                let voteId = try await voteRepo.startVote(
                    groupId: rule.groupId,
                    voteType: .ruleChange,
                    referenceId: rule.id,
                    title: "Cambiar monto: \(rule.name)",
                    description: nil,
                    payload: payload
                )
                return .vote(voteId: voteId)
            } catch {
                throw RuleMutationError.voteOpenFailed(error.localizedDescription)
            }

        case .adminOnly:
            return .adminOnly

        case .denied(let reason):
            throw RuleMutationError.denied(reason: reason)
        }
    }

    // MARK: RuleRepository conformance (pass-through)

    public func createInitialRules(groupId: UUID, drafts: [RuleDraft]) async throws -> [OnboardingRule] {
        try await inner.createInitialRules(groupId: groupId, drafts: drafts)
    }

    public func seedTemplateRules(templateId: String, groupId: UUID) async throws -> [OnboardingRule] {
        try await inner.seedTemplateRules(templateId: templateId, groupId: groupId)
    }

    public func seedModuleRules(moduleSlug: String, groupId: UUID) async throws -> [OnboardingRule] {
        try await inner.seedModuleRules(moduleSlug: moduleSlug, groupId: groupId)
    }

    public func list(groupId: UUID) async throws -> [GroupRule] {
        try await inner.list(groupId: groupId)
    }

    public func listForResource(_ resourceId: UUID) async throws -> [GroupRule] {
        try await inner.listForResource(resourceId)
    }

    public func listScopedForResource(_ resourceId: UUID) async throws -> [GroupRule] {
        try await inner.listScopedForResource(resourceId)
    }

    public func createResourceRule(
        groupId: UUID,
        resourceId: UUID,
        name: String,
        trigger: RuleTrigger,
        conditions: [RuleCondition],
        consequences: [RuleConsequence]
    ) async throws -> GroupRule {
        try await inner.createResourceRule(
            groupId: groupId, resourceId: resourceId, name: name,
            trigger: trigger, conditions: conditions, consequences: consequences
        )
    }

    /// Bare-conformance pass-through. Governance-aware callers should use
    /// the `setIsActive(ruleId:isActive:groupId:currentIsActive:)` overload
    /// — this one bypasses the resolver and writes directly.
    public func setIsActive(ruleId: UUID, isActive: Bool) async throws {
        try await inner.setIsActive(ruleId: ruleId, isActive: isActive)
    }

    /// Bare-conformance pass-through. Governance-aware callers should use
    /// the `setFlatFineAmount(rule:amount:currentAmount:)` overload.
    public func setFlatFineAmount(rule: GroupRule, amount: Int) async throws {
        try await inner.setFlatFineAmount(rule: rule, amount: amount)
    }

    public func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote? {
        try await inner.pendingRepealVote(ruleId: ruleId, groupId: groupId)
    }
}
