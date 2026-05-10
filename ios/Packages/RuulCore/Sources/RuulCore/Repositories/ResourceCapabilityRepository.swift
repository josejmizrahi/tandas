import Foundation
import Supabase

public enum ResourceCapabilityError: Error, Equatable {
    case rpcFailed(String)
}

/// Reads/writes for `public.resource_capabilities`.
public protocol ResourceCapabilityRepository: Actor {
    /// All capabilities (enabled or not) attached to a resource.
    func list(resourceId: UUID) async throws -> [ResourceCapability]
    /// Enable a block on a resource with optional config.
    func enable(_ blockId: String, on resourceId: UUID, config: JSONConfig) async throws -> ResourceCapability
    /// Disable a block on a resource (sets enabled=false; preserves the
    /// row + config so re-enabling restores history).
    func disable(_ blockId: String, on resourceId: UUID) async throws
    /// Update only the config jsonb for an already-attached block.
    func updateConfig(blockId: String, on resourceId: UUID, config: JSONConfig) async throws -> ResourceCapability
}

// MARK: - Mock

public actor MockResourceCapabilityRepository: ResourceCapabilityRepository {
    private var rows: [ResourceCapability]

    public init(seed: [ResourceCapability] = []) { self.rows = seed }

    public func list(resourceId: UUID) async throws -> [ResourceCapability] {
        rows.filter { $0.resourceId == resourceId }
    }

    public func enable(
        _ blockId: String,
        on resourceId: UUID,
        config: JSONConfig = .object([:])
    ) async throws -> ResourceCapability {
        let updated = ResourceCapability(
            resourceId: resourceId,
            capabilityBlockId: blockId,
            config: config,
            enabled: true,
            enabledAt: .now,
            enabledBy: nil
        )
        if let idx = rows.firstIndex(where: { $0.resourceId == resourceId && $0.capabilityBlockId == blockId }) {
            rows[idx] = updated
        } else {
            rows.append(updated)
        }
        return updated
    }

    public func disable(_ blockId: String, on resourceId: UUID) async throws {
        guard let idx = rows.firstIndex(where: { $0.resourceId == resourceId && $0.capabilityBlockId == blockId }) else {
            return
        }
        let r = rows[idx]
        rows[idx] = ResourceCapability(
            resourceId: r.resourceId,
            capabilityBlockId: r.capabilityBlockId,
            config: r.config,
            enabled: false,
            enabledAt: r.enabledAt,
            enabledBy: r.enabledBy
        )
    }

    public func updateConfig(
        blockId: String,
        on resourceId: UUID,
        config: JSONConfig
    ) async throws -> ResourceCapability {
        return try await enable(blockId, on: resourceId, config: config)
    }
}

// MARK: - Live

public actor LiveResourceCapabilityRepository: ResourceCapabilityRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func list(resourceId: UUID) async throws -> [ResourceCapability] {
        do {
            return try await client
                .from("resource_capabilities")
                .select("*")
                .eq("resource_id", value: resourceId.uuidString.lowercased())
                .execute()
                .value
        } catch {
            throw ResourceCapabilityError.rpcFailed(error.localizedDescription)
        }
    }

    public func enable(
        _ blockId: String,
        on resourceId: UUID,
        config: JSONConfig = .object([:])
    ) async throws -> ResourceCapability {
        struct Row: Encodable {
            let resource_id: String
            let capability_block_id: String
            let config: JSONConfig
            let enabled: Bool
            let enabled_at: Date
        }
        do {
            return try await client
                .from("resource_capabilities")
                .upsert(Row(
                    resource_id: resourceId.uuidString.lowercased(),
                    capability_block_id: blockId,
                    config: config,
                    enabled: true,
                    enabled_at: .now
                ), onConflict: "resource_id,capability_block_id")
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw ResourceCapabilityError.rpcFailed(error.localizedDescription)
        }
    }

    public func disable(_ blockId: String, on resourceId: UUID) async throws {
        struct Patch: Encodable { let enabled: Bool }
        do {
            _ = try await client
                .from("resource_capabilities")
                .update(Patch(enabled: false))
                .eq("resource_id", value: resourceId.uuidString.lowercased())
                .eq("capability_block_id", value: blockId)
                .execute()
        } catch {
            throw ResourceCapabilityError.rpcFailed(error.localizedDescription)
        }
    }

    public func updateConfig(
        blockId: String,
        on resourceId: UUID,
        config: JSONConfig
    ) async throws -> ResourceCapability {
        struct Patch: Encodable { let config: JSONConfig }
        do {
            return try await client
                .from("resource_capabilities")
                .update(Patch(config: config))
                .eq("resource_id", value: resourceId.uuidString.lowercased())
                .eq("capability_block_id", value: blockId)
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw ResourceCapabilityError.rpcFailed(error.localizedDescription)
        }
    }
}
