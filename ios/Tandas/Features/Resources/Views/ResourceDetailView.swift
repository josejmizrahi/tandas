import SwiftUI
import RuulUI
import RuulCore

/// Container del detail screen de cualquier resource. Switches por
/// `resource.resourceType` y dispatch al body apropiado.
///
/// V1 solo `.event` case con stub body (EventDetailBody). Otros 5
/// resource types (slot, fund, position, asset, contribution) muestran
/// UnknownResourceDetailBody hasta Phase 2/3.
///
/// V1 scope: scaffolding. EventDetailView preserva su surface
/// existente como canonical entry point para events. ResourceDetailView
/// se vuelve canonical en Phase 2 cuando llega Slot.
struct ResourceDetailView: View {
    let resource: any ResourceProtocol

    var body: some View {
        switch resource.resourceType {
        case .event:
            // V1 stub. Phase 2: wire EventDetailCoordinator from injected env.
            UnknownResourceDetailBody(resource: resource, label: "Event")
        case .slot, .fund, .position, .asset, .contribution, .unknown:
            UnknownResourceDetailBody(
                resource: resource,
                label: String(describing: resource.resourceType)
            )
        }
    }
}

/// Fallback visual para resource types aún no implementados. Igual que
/// `UnknownResourceCard`: existir hace el switch total y deja a QA
/// detectar inmediatamente cuando un resource llega sin body.
private struct UnknownResourceDetailBody: View {
    let resource: any ResourceProtocol
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Resource detail (\(label)) — V1 stub")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Resource ID: \(resource.id.uuidString)")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.md)
    }
}
