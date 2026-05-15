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
        // V1 MVP: minimal create surface — just `name`. The right's
        // holder defaults to the caller server-side (mig 00201), and
        // the remaining knobs (scope/priority/exclusive/transferable/
        // delegable/divisible/expires_at/target_resource/target_capability)
        // accept server-side defaults too. All of them can be reset via
        // the dedicated lifecycle RPCs (transfer_right, delegate_right,
        // update_right_metadata, …).
        //
        // Why `holderMemberId` isn't here yet: BuilderFieldRenderer's
        // `.memberPicker` kind renders disabled today
        // ("Selector de miembros no disponible — Próximamente"); making
        // holderMemberId a required field would block the entire wizard
        // submit until the picker ships. Defaulting to the creator gets
        // the create-flow working today; a future slice adds an explicit
        // holder picker for "grant right to David" UX.
        [
            BuilderField(
                key: "name",
                label: "Nombre",
                kind: .text,
                placeholder: "ej: Prioridad de reserva en el palco"
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
        // holderMemberId is optional in the wizard's basic_fields (mig 00201):
        // when absent, create_right defaults to the caller's membership. The
        // Swift side mirrors that — submitting without a holder is valid.

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
