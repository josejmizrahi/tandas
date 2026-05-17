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
        // `name` is the only truly required field — everything else is
        // declared with `isOptional: true` so the wizard renders the
        // input but doesn't block "Continuar" when empty. Server-side
        // defaults (mig 00201: caller is holder; transferable/delegable/
        // divisible/exclusive=false; priority=0; no expiration) take
        // over.
        //
        // Slice 15 expanded the surface from name-only after
        // BuilderFieldRenderer.memberPicker (slice 8) +
        // .resourcePicker (slice 9) +
        // BuilderField.isOptional (this slice) shipped.
        [
            BuilderField(
                key: "name",
                label: "Nombre",
                kind: .text,
                placeholder: "ej: Prioridad de reserva en el palco"
            ),
            BuilderField(
                key: "holderMemberId",
                label: "Titular (opcional)",
                kind: .memberPicker,
                helpText: "Quién posee este derecho. Si no eliges, tú serás el titular.",
                isOptional: true
            ),
            BuilderField(
                key: "transferable",
                label: "Transferible",
                kind: .boolean,
                helpText: "Permite que el titular reasigne el derecho a otro miembro.",
                isOptional: true
            ),
            BuilderField(
                key: "delegable",
                label: "Delegable",
                kind: .boolean,
                helpText: "Permite delegar temporalmente sin perder titularidad.",
                isOptional: true
            ),
            BuilderField(
                key: "exclusive",
                label: "Exclusivo",
                kind: .boolean,
                helpText: "Ningún otro titular puede tener el mismo claim al mismo tiempo.",
                isOptional: true
            ),
            BuilderField(
                key: "targetResourceId",
                label: "Sobre qué recurso (opcional)",
                kind: .resourcePicker,
                helpText: "Recurso que el derecho gobierna. Vacío = derecho a nivel grupo.",
                isOptional: true
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

    public func build(_ rawDraft: ResourceDraft) async throws -> ResourceCreationResult {
        guard rawDraft.resourceType == .right else {
            throw ResourceBuilderError.underlying("RightResourceBuilder cannot build this type")
        }

        guard case let .string(name)? = rawDraft.basicFields["name"], !name.isEmpty else {
            throw ResourceBuilderError.missingRequiredField("name")
        }
        // holderMemberId is optional in the wizard's basic_fields (mig 00201):
        // when absent, create_right defaults to the caller's membership. The
        // Swift side mirrors that — submitting without a holder is valid.

        // Tier 0 caps merged in (no Tier 0.5 for `right` per
        // CapabilityTiers.md §3 — rights are relations, not balance holders).
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
