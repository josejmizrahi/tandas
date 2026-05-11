import Foundation
import OSLog

/// ResourceBuilder for Asset resources (palco, casa, cancha, membresía).
/// Wraps `SlotLifecycleRepository.createAsset` from Phase 2 Slice 2.3.
public actor AssetResourceBuilder: ResourceBuilder {
    public nonisolated let resourceType: ResourceType = .asset
    public nonisolated let displayName: String = "Activo compartido"
    public nonisolated let icon: String = "key.fill"
    public nonisolated let summary: String = "Palco, casa, cancha, membresía. Cosa persistente que se usa por turnos."

    public nonisolated var requiredFields: [BuilderField] {
        [
            BuilderField(key: "name", label: "Nombre",
                         kind: .text, placeholder: "ej: Palco Azul")
        ]
    }

    public nonisolated var optionalCapabilities: [String] {
        ["ownership", "capacity", "slot", "booking", "guest_access", "rules", "voting"]
    }

    private let slotRepo: any SlotLifecycleRepository
    private let capabilityRepo: (any ResourceCapabilityRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.builder.asset")

    public init(
        slotRepo: any SlotLifecycleRepository,
        capabilityRepo: (any ResourceCapabilityRepository)? = nil
    ) {
        self.slotRepo = slotRepo
        self.capabilityRepo = capabilityRepo
    }

    public func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult {
        guard draft.resourceType == .asset else {
            throw ResourceBuilderError.underlying("AssetResourceBuilder cannot build this type")
        }
        guard case let .string(name)? = draft.basicFields["name"], !name.isEmpty else {
            throw ResourceBuilderError.missingRequiredField("name")
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
