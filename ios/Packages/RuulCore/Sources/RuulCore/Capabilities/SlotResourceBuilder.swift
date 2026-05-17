import Foundation
import OSLog

/// ResourceBuilder for Slot resources — a usage window of a parent Asset
/// (turno, asiento, horario, mesa, fin de semana). Routes through
/// `build_resource_from_draft` (mig 00204) → `create_slot` RPC (mig 00070).
///
/// Slot creation requires a parent asset. The wizard's type picker should
/// only enable this builder when the group already has at least one
/// asset; otherwise the resourcePicker has nothing to bind. UI gating is
/// the picker's concern — the builder itself just delegates.
public actor SlotResourceBuilder: ResourceBuilder {
    public nonisolated let resourceType: ResourceType = .slot
    public nonisolated let displayName: String = "Turno"
    public nonisolated let icon: String = "ticket"
    public nonisolated let summary: String = "Ventana de uso de un activo (turno, asiento, horario)."

    public nonisolated var requiredFields: [BuilderField] {
        [
            BuilderField(
                key: "assetId",
                label: "Activo",
                kind: .resourcePicker,
                helpText: "Elige a qué activo pertenece este turno."
            ),
            BuilderField(
                key: "startsAt",
                label: "Empieza",
                kind: .dateTime
            ),
            BuilderField(
                key: "endsAt",
                label: "Termina",
                kind: .dateTime
            )
        ]
    }

    /// Tier 0/0.5 are merged via `withTierDefaults()`; only Tier 1
    /// type-specific opt-ins listed here.
    public nonisolated var optionalCapabilities: [String] {
        ["capacity", "booking", "swap", "guest_access"]
    }

    private let draftRepo: any ResourceDraftRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.builder.slot")

    public init(draftRepo: any ResourceDraftRepository) {
        self.draftRepo = draftRepo
    }

    public func build(_ rawDraft: ResourceDraft) async throws -> ResourceCreationResult {
        guard rawDraft.resourceType == .slot else {
            throw ResourceBuilderError.underlying("SlotResourceBuilder cannot build this type")
        }
        guard rawDraft.basicFields["assetId"]?.uuidValue != nil else {
            throw ResourceBuilderError.missingRequiredField("assetId")
        }
        guard rawDraft.basicFields["startsAt"]?.dateValue != nil else {
            throw ResourceBuilderError.missingRequiredField("startsAt")
        }
        guard rawDraft.basicFields["endsAt"]?.dateValue != nil else {
            throw ResourceBuilderError.missingRequiredField("endsAt")
        }

        // Tier 0 + Tier 0.5 caps merged in per CapabilityTiers.md §2-3.
        let draft = rawDraft.withTierDefaults()

        // Atomic submit via build_resource_from_draft. The RPC's
        // `when 'slot'` branch (mig 00204) parses the three fields and
        // calls create_slot, then installs series + capabilities + rules
        // in the same transaction.
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
