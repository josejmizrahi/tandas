import Foundation
import OSLog

/// ResourceBuilder for Slot resources (a usage window of an Asset).
/// Wraps `SlotLifecycleRepository.createSlot` from Phase 2 Slice 2.3.
///
/// Note: Slot creation requires an Asset to attach to. The wizard's
/// type picker should only enable this builder when the group already
/// has at least one Asset (resolver-gated). Until then, the picker can
/// hint "Crea un activo primero".
public actor SlotResourceBuilder: ResourceBuilder {
    public nonisolated let resourceType: ResourceType = .slot
    public nonisolated let displayName: String = "Slot"
    public nonisolated let icon: String = "ticket"
    public nonisolated let summary: String = "Una ventana de uso de un activo (fin de semana, turno, asiento)."

    public nonisolated var requiredFields: [BuilderField] {
        [
            BuilderField(key: "assetId",  label: "Activo",  kind: .resourcePicker,
                         helpText: "Elige a qué activo pertenece este slot."),
            BuilderField(key: "startsAt", label: "Empieza", kind: .dateTime),
            BuilderField(key: "endsAt",   label: "Termina", kind: .dateTime)
        ]
    }

    public nonisolated var optionalCapabilities: [String] {
        ["capacity", "booking", "swap", "guest_access", "rules"]
    }

    private let slotRepo: any SlotLifecycleRepository
    private let capabilityRepo: (any ResourceCapabilityRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.builder.slot")

    public init(
        slotRepo: any SlotLifecycleRepository,
        capabilityRepo: (any ResourceCapabilityRepository)? = nil
    ) {
        self.slotRepo = slotRepo
        self.capabilityRepo = capabilityRepo
    }

    public func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult {
        guard draft.resourceType == .slot else {
            throw ResourceBuilderError.underlying("SlotResourceBuilder cannot build this type")
        }
        guard let assetId = draft.basicFields["assetId"]?.uuidValue else {
            throw ResourceBuilderError.missingRequiredField("assetId")
        }
        guard let startsAt = draft.basicFields["startsAt"]?.dateValue else {
            throw ResourceBuilderError.missingRequiredField("startsAt")
        }
        guard let endsAt = draft.basicFields["endsAt"]?.dateValue else {
            throw ResourceBuilderError.missingRequiredField("endsAt")
        }

        let slotId: UUID
        do {
            slotId = try await slotRepo.createSlot(asset: assetId, startsAt: startsAt, endsAt: endsAt)
        } catch {
            throw ResourceBuilderError.rpcFailed(error.localizedDescription)
        }

        var persistedCapabilityIds: [String] = []
        if let capabilityRepo {
            for blockId in draft.enabledCapabilities {
                let config = draft.capabilityConfigs[blockId] ?? .object([:])
                do {
                    _ = try await capabilityRepo.enable(blockId, on: slotId, config: config)
                    persistedCapabilityIds.append(blockId)
                } catch {
                    log.warning("enable capability \(blockId) failed: \(error.localizedDescription)")
                }
            }
        }

        return ResourceCreationResult(
            resourceId: slotId,
            enabledCapabilityIds: persistedCapabilityIds.isEmpty
                ? draft.enabledCapabilities
                : persistedCapabilityIds
        )
    }
}

// MARK: - JSONConfig accessors (shared with EventResourceBuilder)

extension JSONConfig {
    /// Best-effort decode of a UUID string.
    var uuidValue: UUID? {
        guard case let .string(raw) = self else { return nil }
        return UUID(uuidString: raw)
    }

    /// Best-effort decode of an ISO8601 / "yyyy-MM-dd HH:mm" date.
    var dateValue: Date? {
        guard case let .string(raw) = self else { return nil }
        if let iso = ISO8601DateFormatter().date(from: raw) { return iso }
        let fallback = DateFormatter()
        fallback.dateFormat = "yyyy-MM-dd HH:mm"
        return fallback.date(from: raw)
    }
}
