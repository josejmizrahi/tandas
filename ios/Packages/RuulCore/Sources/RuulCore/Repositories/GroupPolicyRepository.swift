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
        // NOTE: single-row upsert is BROKEN today because the unique index
        // on group_policies (mig 00087) is partial + expression-based, and
        // PostgREST refuses to match a simple `onConflict` column list. V1
        // doesn't exercise this path (preset-only edits go through
        // `applyPreset`), so leaving it as-is until per-row editing ships
        // in V2. Fix at that point: either replace the partial index with
        // a non-partial one using `NULLS NOT DISTINCT`, or promote this
        // method to a SECURITY DEFINER RPC.
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
        // Two-step replace: delete existing rule.* group-scope rows then
        // insert the preset's rows. We don't use `upsert` here because
        // the unique index on group_policies (mig 00087) is partial
        // (`WHERE enabled`) and uses COALESCE expressions for nullable
        // resource_type/resource_id, which PostgREST cannot match against
        // a simple `onConflict` column list — Postgres raises
        // "there is no unique or exclusion constraint matching the ON
        // CONFLICT specification".
        //
        // Delete-then-insert is not atomic at the SQL level, but a single
        // user can only tap one preset at a time, and the unique-index
        // guard still prevents duplicate enabled rows. If atomicity becomes
        // important (concurrent admins), promote this to a SECURITY DEFINER
        // RPC that wraps both in one transaction.
        let actionValues = preset.specs.map { $0.action.rawValue }

        try await client.from("group_policies")
            .delete()
            .eq("group_id", value: groupId.uuidString.lowercased())
            .eq("target_scope", value: "group")
            .in("target_action", values: actionValues)
            .execute()

        let rows: [GroupPolicy] = preset.specs.map { spec in
            GroupPolicy(
                groupId: groupId,
                policyType: spec.policyType,
                targetAction: spec.action,
                approvalConfig: spec.approvalConfig
            )
        }

        guard !rows.isEmpty else { return }

        try await client.from("group_policies")
            .insert(rows)
            .execute()
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
