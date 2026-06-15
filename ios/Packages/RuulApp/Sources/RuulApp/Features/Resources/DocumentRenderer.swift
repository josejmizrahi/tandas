import SwiftUI
import RuulCore

/// R.10.F.6 — `class_key="document"` renderer (contrato / acta / poder /
/// escritura / título / cesión).
///
/// Migra `case "document":` inline en `ResourceDetailV2InfoSection` al
/// protocolo polimórfico. Cero cambio visual respecto al monolito previo.
///
/// Sections específicas pendientes (capability-gated, requieren backend
/// support):
///   - Versiones (capability `versionable`) — supersedes chain
///   - Firmas (capability `signable`) — signature ledger
/// Se evalúan en F.10 cuando el descriptor exponga el shape (linked_versions /
/// linked_signatures no existen hoy).
@MainActor
struct DocumentRenderer: ResourceSubtypeRenderer {
    static let classKey = "document"

    func informationFields(_ d: ResourceDetailDescriptor) -> AnyView {
        AnyView(
            Group {
                if let partyA = d.resource.metadataString("party_a") {
                    LabeledContent("Parte A", value: partyA)
                }
                if let partyB = d.resource.metadataString("party_b") {
                    LabeledContent("Parte B", value: partyB)
                }
                if let effective = d.resource.metadataString("effective_date") {
                    LabeledContent("Vigencia", value: effective)
                }
                if let expiration = d.resource.metadataString("expiration_date") {
                    LabeledContent("Vence", value: expiration)
                }
                if let created = d.resource.createdAt {
                    LabeledContent(
                        "Creado",
                        value: created.formatted(date: .abbreviated, time: .omitted)
                    )
                }
            }
        )
    }

    /// R.10.F.f Hero subtitle — badge "Decisión abierta" cuando el documento
    /// está locked por governance (critical state, no debe esconderse en Info).
    /// El row legacy del Info section se eliminó: vive solo en Hero (E.4 dedup).
    func heroSubtitle(_ d: ResourceDetailDescriptor) -> AnyView {
        guard d.state.lockedForGovernance else { return AnyView(EmptyView()) }
        return AnyView(
            Label("Decisión abierta", systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.purple)
        )
    }
}
