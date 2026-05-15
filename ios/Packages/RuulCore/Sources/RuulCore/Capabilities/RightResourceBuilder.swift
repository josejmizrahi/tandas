import Foundation
import OSLog

/// ResourceBuilder for the canonical `right` resource_type — the
/// normative layer of the platform (Constitution §1 art. 2, sixth
/// canonical type).
///
/// A `right` is NOT a permission flag: it is a Resource that records
/// who has a legitimate claim over something — a derecho de uso,
/// acceso, voto, prioridad, transferencia, equity, custodia. Rights
/// have lifecycle (transfer/delegate/revoke/suspend/restore/exercise),
/// governance (priority, exclusivity), and history (atom-backed). The
/// builder ships the creation path; downstream RPCs (`transfer_right`,
/// `delegate_right`, `revoke_right`, `suspend_right`, `restore_right`,
/// `exercise_right`) drive the lifecycle.
///
/// Atomic submit via `build_resource_from_draft` (mig 00198 `right`
/// branch) → server-side `create_right` RPC. Mirrors the Fund builder
/// shape — one RPC round-trip, partial-failure rollback at the server
/// transaction level.
public actor RightResourceBuilder: ResourceBuilder {
    public nonisolated let resourceType: ResourceType = .right
    public nonisolated let displayName: String = "Derecho"
    public nonisolated let icon: String = "person.badge.key.fill"
    public nonisolated let summary: String =
        "Acceso, prioridad, equity o custodia que alguien tiene sobre algo."

    public nonisolated var requiredFields: [BuilderField] {
        // V1 MVP: minimal create surface — `name` + `holder`. The RPC's
        // remaining knobs (scope/priority/exclusive/transferable/
        // delegable/divisible/expires_at/target_resource/target_capability)
        // accept server-side defaults; their values get set later via the
        // dedicated lifecycle RPCs (transfer_right, delegate_right, …).
        // A richer wizard surface comes in a follow-up slice — same
        // pattern as FundResourceBuilder which only surfaces `name` today
        // and leaves target_amount_cents as a metadata follow-up.
        [
            BuilderField(
                key: "name",
                label: "Nombre",
                kind: .text,
                placeholder: "ej: Prioridad de reserva en el palco"
            ),
            BuilderField(
                key: "holderMemberId",
                label: "Titular",
                kind: .memberPicker,
                helpText: "Miembro del grupo que tiene el derecho."
            )
        ]
    }

    public nonisolated var optionalCapabilities: [String] {
        // Rights mostly govern OTHER resources' capabilities. Capacity +
        // expiration + voting + rules are the ones that make sense as
        // capability rows on the right itself (vs. on its target).
        ["capacity", "expiration", "voting", "rules"]
    }

    private let draftRepo: any ResourceDraftRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.builder.right")

    public init(draftRepo: any ResourceDraftRepository) {
        self.draftRepo = draftRepo
    }

    public func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult {
        guard draft.resourceType == .right else {
            throw ResourceBuilderError.underlying("RightResourceBuilder cannot build this type")
        }

        guard case let .string(name)? = draft.basicFields["name"], !name.isEmpty else {
            throw ResourceBuilderError.missingRequiredField("name")
        }
        guard draft.basicFields["holderMemberId"]?.uuidValue != nil else {
            throw ResourceBuilderError.missingRequiredField("holderMemberId")
        }

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
