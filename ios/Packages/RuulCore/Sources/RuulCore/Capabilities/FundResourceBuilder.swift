import Foundation
import OSLog

/// ResourceBuilder for Fund resources (caja común, vaquita, pot rotatorio).
/// Tier 6 slice 19 (mig 00139): atomic submit via `build_resource_from_draft`
/// → server-side `create_fund` RPC. Stores name + optional target in
/// `resources.metadata`.
///
/// The `money` + `ledger` capabilities auto-apply for the fund — that's
/// the entire reason this resource type exists. Member balances (mig 00136
/// `member_balances_per_resource`) aggregate any `record_ledger_entry`
/// rows scoped to the fund's resource_id.
public actor FundResourceBuilder: ResourceBuilder {
    public nonisolated let resourceType: ResourceType = .fund
    public nonisolated let displayName: String = "Fondo"
    public nonisolated let icon: String = "banknote"
    public nonisolated let summary: String = "Caja común para aportaciones, multas y payouts del grupo."

    public nonisolated var requiredFields: [BuilderField] {
        [
            BuilderField(
                key: "name",
                label: "Nombre",
                kind: .text,
                placeholder: "ej: Bote de fin de año"
            )
        ]
    }

    public nonisolated var optionalFields: [BuilderField] {
        [
            BuilderField(
                key: "targetAmountCents",
                label: "Meta (centavos)",
                kind: .integer,
                placeholder: "ej: 500000 = $5,000",
                helpText: "Meta opcional para mostrar progreso. Se almacena en centavos.",
                isOptional: true
            ),
            BuilderField(
                key: "currency",
                label: "Moneda",
                kind: .text,
                placeholder: "MXN",
                helpText: "Por defecto MXN.",
                isOptional: true
            )
        ]
    }

    public nonisolated var optionalCapabilities: [String] {
        ["money", "ledger", "voting", "rules"]
    }

    private let draftRepo: any ResourceDraftRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.builder.fund")

    public init(draftRepo: any ResourceDraftRepository) {
        self.draftRepo = draftRepo
    }

    public func build(_ draft: ResourceDraft) async throws -> ResourceCreationResult {
        guard draft.resourceType == .fund else {
            throw ResourceBuilderError.underlying("FundResourceBuilder cannot build this type")
        }
        guard case let .string(name)? = draft.basicFields["name"], !name.isEmpty else {
            throw ResourceBuilderError.missingRequiredField("name")
        }

        // Atomic submit via build_resource_from_draft. The RPC's
        // `when 'fund'` branch calls create_fund — same shape as
        // event / asset paths. Partial-failure rollback at the
        // function transaction level.
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
