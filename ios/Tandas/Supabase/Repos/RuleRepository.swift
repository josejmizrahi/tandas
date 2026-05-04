import Foundation
import Supabase

enum RuleError: Error, Equatable {
    case rpcFailed(String)
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
}
