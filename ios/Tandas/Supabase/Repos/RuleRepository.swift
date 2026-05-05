import Foundation
import Supabase

enum RuleError: Error, Equatable {
    case rpcFailed(String)
}

public enum RulesRepositoryError: Error {
    case notFlatFine
    case rlsDenied
    case other(Error)
}

/// Lightweight Vote projection for the pending-repeal badge.
struct PendingVote: Sendable, Hashable {
    let id: UUID
    let referenceId: UUID
    let closesAt: Date
}

struct OnboardingRule: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let groupId: UUID
    let code: String?
    let title: String
    let description: String?
    let enabled: Bool
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case groupId     = "group_id"
        case code, title, description, enabled, status
    }
}

protocol RuleRepository: Actor {
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

actor MockRuleRepository: RuleRepository {
    private(set) var lastCreatedDrafts: [RuleDraft] = []
    var nextCreateError: RuleError?

    func createInitialRules(groupId: UUID, drafts: [RuleDraft]) async throws -> [OnboardingRule] {
        if let err = nextCreateError { nextCreateError = nil; throw err }
        let enabled = drafts.filter(\.enabled)
        lastCreatedDrafts = enabled
        return enabled.map { d -> OnboardingRule in
            OnboardingRule(
                id: UUID(),
                groupId: groupId,
                code: d.code,
                title: d.title,
                description: d.description,
                enabled: true,
                status: "active"
            )
        }
    }

    func seedDinnerTemplateRules(groupId: UUID) async throws -> [OnboardingRule] {
        // Mock returns 5 fake rows so previews/tests see expected counts.
        return DinnerRecurringTemplate.defaultRules(groupId: groupId).map {
            OnboardingRule(
                id: $0.id,
                groupId: groupId,
                code: nil,
                title: $0.name,
                description: nil,
                enabled: $0.isActive,
                status: "active"
            )
        }
    }

    func list(groupId: UUID) async throws -> [GroupRule] {
        // Empty in mock — RulesView shows the empty state.
        []
    }

    private(set) var lastSetEnabled: (ruleId: UUID, enabled: Bool)?
    private(set) var lastSetAmount: (ruleId: UUID, amount: Int)?

    func setEnabled(ruleId: UUID, enabled: Bool) async throws {
        lastSetEnabled = (ruleId, enabled)
    }

    func setFlatFineAmount(rule: GroupRule, amount: Int) async throws {
        guard case .flat = rule.fineShape else { throw RulesRepositoryError.notFlatFine }
        lastSetAmount = (rule.id, amount)
    }

    func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote? {
        nil
    }
}

// MARK: - Live

actor LiveRuleRepository: RuleRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func createInitialRules(groupId: UUID, drafts: [RuleDraft]) async throws -> [OnboardingRule] {
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

    func seedDinnerTemplateRules(groupId: UUID) async throws -> [OnboardingRule] {
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

    func list(groupId: UUID) async throws -> [GroupRule] {
        try await client
            .from("rules")
            .select("id,group_id,code,title,description,enabled,is_active,action,consequences")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    func setEnabled(ruleId: UUID, enabled: Bool) async throws {
        struct Body: Encodable { let enabled: Bool }
        do {
            _ = try await client.from("rules")
                .update(Body(enabled: enabled))
                .eq("id", value: ruleId.uuidString.lowercased())
                .execute()
        } catch {
            throw RulesRepositoryError.other(error)
        }
    }

    func setFlatFineAmount(rule: GroupRule, amount: Int) async throws {
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

    func pendingRepealVote(ruleId: UUID, groupId: UUID) async throws -> PendingVote? {
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
