import Foundation
import Supabase

/// Calls the server-side `build_resource_from_draft` RPC (mig 00101) to
/// commit an entire ResourceDraft in a single transaction. Replaces the
/// N-call orchestration that lived inside per-type builders.
///
/// Founder framing 2026-05-11 #5: iOS no debe orquestar N writes
/// críticos uno por uno. This protocol gives every ResourceBuilder a
/// single atomic submit path; partial failures on the server roll back
/// the whole batch instead of leaving orphan rows.
public protocol ResourceDraftRepository: Actor {
    /// Submits the draft and returns the created resource id. The RPC
    /// is polymorphic — internally dispatches on `draft.resourceType`
    /// to create the resource via its existing helper (`create_event_v2`,
    /// `create_asset`, …), then inserts series + capabilities + rules
    /// uniformly.
    func build(_ draft: ResourceDraft) async throws -> UUID
}

public enum ResourceDraftError: Error, Equatable {
    case rpcFailed(String)
}

// MARK: - Mock

public actor MockResourceDraftRepository: ResourceDraftRepository {
    public init() {}
    public private(set) var lastDraft: ResourceDraft?

    public func build(_ draft: ResourceDraft) async throws -> UUID {
        lastDraft = draft
        return UUID()
    }
}

// MARK: - Live

public actor LiveResourceDraftRepository: ResourceDraftRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func build(_ draft: ResourceDraft) async throws -> UUID {
        // RPC return shape: a bare uuid. Decode into our wrapper struct
        // so the supabase-swift type inference keeps a non-optional path.
        //
        // ALL params are non-optional — PostgREST overload resolution
        // requires the calling shape to match an existing function
        // signature. Encoding `p_series_pattern` as `JSONConfig?` and
        // sending nil caused JSON encoder to OMIT the key, which made
        // PostgREST search for a 6-param overload of
        // build_resource_from_draft. That overload doesn't exist, so
        // every Activo / Fondo without a series got
        // "Could not find the function … in the schema cache". Fix:
        // always send a JSONConfig value (null or object) so all 7
        // params are present in the envelope.
        struct Params: Encodable {
            let p_group_id: String
            let p_resource_type: String
            let p_basic_fields: JSONConfig
            let p_enabled_capabilities: [String]
            let p_capability_configs: JSONConfig
            let p_series_pattern: JSONConfig
            let p_initial_rules: [DraftRuleWire]
        }

        // Flatten basicFields ([String: JSONConfig]) into a single
        // JSONConfig.object so it serializes as the jsonb shape the
        // RPC expects.
        let basicFields = JSONConfig.object(draft.basicFields)
        // capabilityConfigs is already [String: JSONConfig] per the
        // wizard's flattening at submit time.
        let capabilityConfigs = JSONConfig.object(draft.capabilityConfigs)

        let initialRules: [DraftRuleWire] = draft.initialRules.map { d in
            DraftRuleWire(
                slug: d.slug,
                name: d.name,
                isActive: d.isActive,
                trigger: JSONConfig.fromTrigger(d.trigger),
                conditions: JSONConfig.fromConditions(d.conditions),
                consequences: JSONConfig.fromConsequences(d.consequences)
            )
        }

        do {
            let id: UUID = try await client
                .rpc("build_resource_from_draft", params: Params(
                    p_group_id: draft.groupId.uuidString.lowercased(),
                    p_resource_type: draft.resourceType.rawString,
                    p_basic_fields: basicFields,
                    p_enabled_capabilities: draft.enabledCapabilities,
                    p_capability_configs: capabilityConfigs,
                    // Pre-fix this was `draft.seriesPattern` (Optional);
                    // nil omitted the key → PostgREST 404. Send
                    // JSONConfig.null when absent so the envelope
                    // shape is always 7 keys.
                    p_series_pattern: draft.seriesPattern ?? .null,
                    p_initial_rules: initialRules
                ))
                .execute()
                .value
            return id
        } catch {
            throw ResourceDraftError.rpcFailed(error.localizedDescription)
        }
    }
}

/// Wire shape for the `p_initial_rules` jsonb array. Mirrors the
/// fields the server's `build_resource_from_draft` reads out of each
/// element.
private struct DraftRuleWire: Encodable {
    let slug: String
    let name: String
    let isActive: Bool
    let trigger: JSONConfig
    let conditions: JSONConfig
    let consequences: JSONConfig
}

private extension JSONConfig {
    static func fromTrigger(_ t: RuleTrigger) -> JSONConfig {
        .object([
            "eventType": .string(t.eventType.rawString),
            "config":    t.config
        ])
    }

    static func fromConditions(_ list: [RuleCondition]) -> JSONConfig {
        .array(list.map { c in
            .object([
                "type":   .string(c.type.rawString),
                "config": c.config
            ])
        })
    }

    static func fromConsequences(_ list: [RuleConsequence]) -> JSONConfig {
        .array(list.map { c in
            .object([
                "type":   .string(c.type.rawString),
                "config": c.config
            ])
        })
    }
}
