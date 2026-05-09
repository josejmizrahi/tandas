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

public struct OnboardingRule: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID
    public let slug: String?
    public let code: String?
    public let title: String
    public let description: String?
    public let enabled: Bool
    public let status: String

    public init(id: UUID, groupId: UUID, slug: String?, code: String?, title: String, description: String?, enabled: Bool, status: String) {
        self.id = id
        self.groupId = groupId
        self.slug = slug
        self.code = code
        self.title = title
        self.description = description
        self.enabled = enabled
        self.status = status
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId     = "group_id"
        case slug, code, title, description, enabled, status
    }

    /// Platform-shape forwarder. Views read `name`; legacy `title` is kept
    /// on the struct only until the column drop in `RulesPlatformOnly.md`
    /// E.2. After E.2 this becomes a stored field decoded from the
    /// platform `name` column.
    public var name: String { title }

    /// Platform-shape forwarder. The legacy `enabled` boolean and the
    /// platform `is_active` boolean were equal until 2026-05-08 because
    /// `LiveRuleRepository.setEnabled` only updated the legacy column.
    /// That writer now dual-writes both, so the forwarder is safe to use
    /// from views going forward.
    public var isActive: Bool { enabled }
}

public protocol RuleRepository: Actor {
    /// Creates only the enabled drafts. Returns the created rules.
    func createInitialRules(groupId: UUID, drafts: [RuleDraft]) async throws -> [OnboardingRule]

    /// Seeds the 5 default Platform rules for the "Cena recurrente" template
    /// via the `seed_dinner_template_rules` RPC. Idempotent — re-running on a
    /// group that already has Platform-shape rules is a no-op.
    func seedDinnerTemplateRules(groupId: UUID) async throws -> [OnboardingRule]

    /// Read-only list of all rules for a group, ordered by creation time.
    /// Used by the Reglas tab to show the active group's rules.
    func list(groupId: UUID) async throws -> [GroupRule]

    /// Toggles enabled/disabled. Postgres trigger emits ruleEnabledChanged.
    func setEnabled(ruleId: UUID, enabled: Bool) async throws

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
        let enabled = drafts.filter(\.enabled)
        lastCreatedDrafts = enabled
        return enabled.map { d -> OnboardingRule in
            OnboardingRule(
                id: UUID(),
                groupId: groupId,
                slug: nil,
                code: d.code,
                title: d.title,
                description: d.description,
                enabled: true,
                status: "active"
            )
        }
    }

    public func seedDinnerTemplateRules(groupId: UUID) async throws -> [OnboardingRule] {
        // Mock returns 5 fake rows so previews/tests see expected counts.
        return DinnerRecurringTemplate.defaultRules(groupId: groupId).map {
            OnboardingRule(
                id: $0.id,
                groupId: groupId,
                slug: $0.slug,
                code: nil,
                title: $0.name,
                description: nil,
                enabled: $0.isActive,
                status: "active"
            )
        }
    }

    public func list(groupId: UUID) async throws -> [GroupRule] {
        // Empty in mock — RulesView shows the empty state.
        []
    }

    public private(set) var lastSetEnabled: (ruleId: UUID, enabled: Bool)?
    public private(set) var lastSetAmount: (ruleId: UUID, amount: Int)?

    public func setEnabled(ruleId: UUID, enabled: Bool) async throws {
        lastSetEnabled = (ruleId, enabled)
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
            let p_code: String
            let p_title: String
            let p_description: String
            let p_trigger: TriggerEnvelope
            let p_action: ActionEnvelope
        }
        struct TriggerEnvelope: Encodable {
            let type: String
            let params: [String: AnyCodable]
        }
        struct ActionEnvelope: Encodable {
            let type: String
            let amount_mxn: Int
        }

        var rules: [OnboardingRule] = []
        for draft in drafts where draft.enabled {
            let p = Params(
                p_group_id: groupId.uuidString.lowercased(),
                p_code: draft.code,
                p_title: draft.title,
                p_description: draft.description,
                p_trigger: TriggerEnvelope(type: draft.trigger.type, params: draft.trigger.params),
                p_action: ActionEnvelope(type: "fine", amount_mxn: draft.amountMXN)
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

    public func seedDinnerTemplateRules(groupId: UUID) async throws -> [OnboardingRule] {
        struct Params: Encodable { let p_group_id: String }
        do {
            return try await client
                .rpc("seed_dinner_template_rules", params: Params(
                    p_group_id: groupId.uuidString.lowercased()
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
            .select("id,group_id,slug,code,title,description,enabled,is_active,action,consequences")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    public func setEnabled(ruleId: UUID, enabled: Bool) async throws {
        // Dual-write the legacy `enabled` boolean and the platform
        // `is_active` boolean so the two columns stay in lockstep until
        // `RulesPlatformOnly.md` E.2 drops the legacy column. Pre-2026-05-09
        // this writer only updated the legacy column, leaving the platform
        // column stale on every toggle — `GroupRule.isLive = enabled &&
        // isActive` then masked the divergence by AND-ing both.
        struct Body: Encodable {
            let enabled: Bool
            let is_active: Bool
        }
        do {
            _ = try await client.from("rules")
                .update(Body(enabled: enabled, is_active: enabled))
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
