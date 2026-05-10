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
            .select("id,group_id,slug,name,is_active,trigger,conditions,consequences,module_key,resource_id")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .order("created_at", ascending: true)
            .execute()
            .value
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
