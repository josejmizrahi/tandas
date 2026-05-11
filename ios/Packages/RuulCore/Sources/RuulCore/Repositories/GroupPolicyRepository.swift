import Foundation
import Supabase

/// CRUD + decision surface over `public.group_policies` (mig 00087) and
/// `public.resolve_governance` (mig 00088).
///
/// V1 callers:
/// - `GroupRulesCoordinator` lists + upserts policies via the picker UI.
/// - `InterceptingRuleRepository` calls `resolve` before every rule mutation
///   to decide whether to write directly or open a vote.
public protocol GroupPolicyRepository: Actor {
    /// All policies for a group, ordered for stable display.
    func list(groupId: UUID) async throws -> [GroupPolicy]

    /// Upsert by `(group_id, target_action, target_scope, target_resource_type,
    /// target_resource_id)` — server enforces `Permission.modifyGovernance`
    /// via RLS.
    func upsert(_ policy: GroupPolicy) async throws -> GroupPolicy

    /// Batch-apply a preset: replaces the V1 `rule.*` policies in one pass.
    func applyPreset(_ preset: GroupPolicyPreset, groupId: UUID) async throws

    /// Server-side decision via `resolve_governance` RPC. Pure / no side effects.
    /// `targetPayload` may carry keys like `resource_id` / `resource_type` so
    /// the resolver can match per-resource policies.
    func resolve(
        groupId: UUID,
        actorUserId: UUID,
        action: TargetAction,
        targetPayload: [String: String]
    ) async throws -> PolicyDecision
}

// MARK: - Mock

public actor MockGroupPolicyRepository: GroupPolicyRepository {
    private var policies: [GroupPolicy] = []
    private var resolutions: [Key: PolicyDecision] = [:]

    private struct Key: Hashable { let group: UUID; let action: TargetAction }

    public init(seed: [GroupPolicy] = []) { self.policies = seed }

    /// Test/preview hook to script the next `resolve(...)` result for a
    /// `(group, action)` tuple.
    public func setResolution(
        groupId: UUID,
        action: TargetAction,
        decision: PolicyDecision
    ) {
        resolutions[Key(group: groupId, action: action)] = decision
    }

    public func list(groupId: UUID) async throws -> [GroupPolicy] {
        policies.filter { $0.groupId == groupId }
    }

    public func upsert(_ policy: GroupPolicy) async throws -> GroupPolicy {
        if let i = policies.firstIndex(where: {
            $0.groupId == policy.groupId
                && $0.targetAction == policy.targetAction
                && $0.targetScope == policy.targetScope
                && $0.targetResourceType == policy.targetResourceType
                && $0.targetResourceId == policy.targetResourceId
        }) {
            policies[i] = policy
        } else {
            policies.append(policy)
        }
        return policy
    }

    public private(set) var appliedPresets: [(presetId: String, groupId: UUID)] = []

    public func applyPreset(_ preset: GroupPolicyPreset, groupId: UUID) async throws {
        appliedPresets.append((preset.id, groupId))
        // Replace any existing rule.* policies for this group at scope=group
        // so the preset is the authoritative state. Other-scope policies
        // (resource / resource_type) are not touched.
        policies.removeAll {
            $0.groupId == groupId
                && $0.targetScope == "group"
                && [
                    TargetAction.ruleToggle,
                    .ruleUpdateAmount,
                    .ruleCreate,
                    .ruleDelete
                ].contains($0.targetAction)
        }
        for spec in preset.specs {
            policies.append(GroupPolicy(
                groupId: groupId,
                policyType: spec.policyType,
                targetAction: spec.action,
                approvalConfig: spec.approvalConfig
            ))
        }
    }

    public func resolve(
        groupId: UUID,
        actorUserId: UUID,
        action: TargetAction,
        targetPayload: [String: String]
    ) async throws -> PolicyDecision {
        resolutions[Key(group: groupId, action: action)] ?? .adminOnly
    }
}

// MARK: - Live

public actor LiveGroupPolicyRepository: GroupPolicyRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func list(groupId: UUID) async throws -> [GroupPolicy] {
        try await client
            .from("group_policies")
            .select("*")
            .eq("group_id", value: groupId.uuidString.lowercased())
            .order("target_action", ascending: true)
            .order("priority", ascending: true)
            .execute()
            .value
    }

    public func upsert(_ policy: GroupPolicy) async throws -> GroupPolicy {
        // The unique partial index covers (group, action, scope,
        // coalesce(resource_type, ''), coalesce(resource_id, sentinel))
        // WHERE enabled. supabase-swift's upsert API doesn't expose the
        // expression-based conflict target, so we list the simple columns
        // and rely on Postgres to match.
        let row: GroupPolicy = try await client
            .from("group_policies")
            .upsert(policy, onConflict: "group_id,target_action,target_scope")
            .select()
            .single()
            .execute()
            .value
        return row
    }

    public func applyPreset(_ preset: GroupPolicyPreset, groupId: UUID) async throws {
        // V1: client-side loop. Could become a single SQL RPC later if the
        // round-trips become a bottleneck.
        for spec in preset.specs {
            _ = try await upsert(GroupPolicy(
                groupId: groupId,
                policyType: spec.policyType,
                targetAction: spec.action,
                approvalConfig: spec.approvalConfig
            ))
        }
    }

    public func resolve(
        groupId: UUID,
        actorUserId: UUID,
        action: TargetAction,
        targetPayload: [String: String]
    ) async throws -> PolicyDecision {
        struct Params: Encodable {
            let p_group_id: String
            let p_actor_user_id: String
            let p_target_action: String
            let p_target_payload: [String: String]
        }
        let params = Params(
            p_group_id:       groupId.uuidString.lowercased(),
            p_actor_user_id:  actorUserId.uuidString.lowercased(),
            p_target_action:  action.rawValue,
            p_target_payload: targetPayload
        )
        return try await client
            .rpc("resolve_governance", params: params)
            .execute()
            .value
    }
}
