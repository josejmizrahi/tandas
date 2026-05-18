import Foundation
import OSLog

/// ResourceBuilder for Space resources (salón, cancha, sala, oficina,
/// palco, casa). Mig 00203: atomic submit via `build_resource_from_draft`
/// → server-side `create_space` RPC. Stores name + optional capacity /
/// location_name / coordinates / description in `resources.metadata`.
///
/// Booking, schedule, check_in, capacity, location, and guest_access
/// capabilities are catalog-enabled for space (mig 00203 catalog extension).
/// The wizard surfaces them as opt-in toggles; defaults stay off until
/// the user picks them or a template provides them.
public actor SpaceResourceBuilder: ResourceBuilder {
    public nonisolated let resourceType: ResourceType = .space
    public nonisolated let displayName: String = "Espacio"
    public nonisolated let icon: String = "mappin.and.ellipse"
    public nonisolated let summary: String = "Lugar reservable del grupo: salón, cancha, sala, oficina."

    public nonisolated var requiredFields: [BuilderField] {
        [
            BuilderField(
                key: "name",
                label: "Nombre",
                kind: .text,
                placeholder: "ej: Salón comunitario"
            )
        ]
    }

    public nonisolated var optionalFields: [BuilderField] {
        [
            BuilderField(
                key: "capacity",
                label: "Aforo (opcional)",
                kind: .integer,
                placeholder: "ej: 50",
                helpText: "Capacidad máxima de personas para reservas y eventos."
            ),
            BuilderField(
                key: "locationName",
                label: "Dirección o referencia (opcional)",
                kind: .text,
                placeholder: "ej: Av. Reforma 222, CDMX"
            ),
            BuilderField(
                key: "description",
                label: "Descripción (opcional)",
                kind: .text,
                placeholder: "Notas para el grupo"
            )
        ]
    }

    /// Tier 0/0.5 (status/description/history/rules/voting/ledger/money)
    /// are merged in by `withTierDefaults()` — they're not listed here.
    public nonisolated var optionalCapabilities: [String] {
        ["booking", "schedule", "check_in", "capacity", "location", "guest_access"]
    }

    private let draftRepo: any ResourceDraftRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.builder.space")

    public init(draftRepo: any ResourceDraftRepository) {
        self.draftRepo = draftRepo
    }

    public func build(_ rawDraft: ResourceDraft) async throws -> ResourceCreationResult {
        guard rawDraft.resourceType == .space else {
            throw ResourceBuilderError.underlying("SpaceResourceBuilder cannot build this type")
        }
        guard case let .string(name)? = rawDraft.basicFields["name"], !name.isEmpty else {
            throw ResourceBuilderError.missingRequiredField("name")
        }

        // Tier 0 + Tier 0.5 caps merged in per CapabilityTiers.md §2-3.
        let draft = rawDraft.withTierDefaults()

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
