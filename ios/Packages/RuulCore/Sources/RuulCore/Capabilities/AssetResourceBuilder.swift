import Foundation
import OSLog

/// ResourceBuilder for Asset resources (palco, casa, cancha, membresía).
/// Wraps `SlotLifecycleRepository.createAsset` from Phase 2 Slice 2.3.
public actor AssetResourceBuilder: ResourceBuilder {
    public nonisolated let resourceType: ResourceType = .asset
    public nonisolated let displayName: String = "Activo del grupo"
    public nonisolated let icon: String = "key.fill"
    public nonisolated let summary: String = "Coche, palco, herramientas, IP, equity. Cosa que se posee, custodia, presta o gobierna."

    public nonisolated var requiredFields: [BuilderField] {
        [
            BuilderField(key: "name", label: "Nombre",
                         kind: .text, placeholder: "ej: Palco Azul, Camioneta del grupo, Cámara")
        ]
    }

    /// Spec §8: capabilities that ANY asset can wear. The wizard
    /// surfaces these (filtered by CapabilityStatus) in step 3.
    /// `slot` is intentionally NOT a capability — slots are a
    /// separate resource_type per spec §18.
    public nonisolated var optionalCapabilities: [String] {
        [
            "custody", "maintenance", "valuation", "transfer",
            "inventory", "booking", "capacity", "guest_access",
            "delegation", "access", "voting", "rules", "history"
        ]
    }

    private let slotRepo: any SlotLifecycleRepository
    private let capabilityRepo: (any ResourceCapabilityRepository)?
    private let draftRepo: (any ResourceDraftRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.builder.asset")

    public init(
        slotRepo: any SlotLifecycleRepository,
        capabilityRepo: (any ResourceCapabilityRepository)? = nil,
        draftRepo: (any ResourceDraftRepository)? = nil
    ) {
        self.slotRepo = slotRepo
        self.capabilityRepo = capabilityRepo
        self.draftRepo = draftRepo
    }

    public func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult {
        guard draft.resourceType == .asset else {
            throw ResourceBuilderError.underlying("AssetResourceBuilder cannot build this type")
        }
        guard case let .string(name)? = draft.basicFields["name"], !name.isEmpty else {
            throw ResourceBuilderError.missingRequiredField("name")
        }

        // Atomic path via build_resource_from_draft RPC (mig 00101).
        // Same shape as EventResourceBuilder — one round-trip + RPC-side
        // rollback on partial failure.
        if let draftRepo {
            do {
                let resourceId = try await draftRepo.build(draft)
                return ResourceCreationResult(
                    resourceId: resourceId,
                    enabledCapabilityIds: draft.enabledCapabilities
                )
            } catch let e as ResourceDraftError {
                if case let .rpcFailed(msg) = e {
                    throw ResourceBuilderError.rpcFailed(msg)
                }
                throw ResourceBuilderError.rpcFailed("\(e)")
            } catch {
                throw ResourceBuilderError.rpcFailed(error.localizedDescription)
            }
        }

        let capacity: Int? = {
            if case let .int(value)? = draft.basicFields["capacity"] { return value }
            return nil
        }()

        let assetId: UUID
        do {
            assetId = try await slotRepo.createAsset(in: draft.groupId, name: name, capacity: capacity)
        } catch {
            throw ResourceBuilderError.rpcFailed(error.localizedDescription)
        }

        var persistedCapabilityIds: [String] = []
        if let capabilityRepo {
            for blockId in draft.enabledCapabilities {
                let config = draft.capabilityConfigs[blockId] ?? .object([:])
                do {
                    _ = try await capabilityRepo.enable(blockId, on: assetId, config: config)
                    persistedCapabilityIds.append(blockId)
                } catch {
                    log.warning("enable capability \(blockId) failed: \(error.localizedDescription)")
                }
            }
        }

        return ResourceCreationResult(
            resourceId: assetId,
            enabledCapabilityIds: persistedCapabilityIds.isEmpty
                ? draft.enabledCapabilities
                : persistedCapabilityIds
        )
    }
}
