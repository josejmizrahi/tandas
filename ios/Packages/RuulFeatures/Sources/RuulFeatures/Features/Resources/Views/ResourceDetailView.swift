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
public struct ResourceDetailView: View {
    public let resource: any Resource

    public init(resource: any Resource) {
        self.resource = resource
    }

    public var body: some View {
        switch resource.resourceType {
        case .event:
            UnknownResourceDetailBody(resource: resource, label: "Event")
        case .asset:
            // Phase 2 Slice 2.4 — AssetDetailView consumes the polymorphic
            // ResourceRow envelope directly. Caller passes a ResourceRow;
            // this guard preserves the protocol-typed entry path.
            if let row = resource as? ResourceRow {
                AssetDetailView(asset: row)
            } else {
                UnknownResourceDetailBody(resource: resource, label: "Asset")
            }
        case .slot:
            // Slot detail needs both the slot ResourceRow + its parent asset.
            // ResourceDetailView doesn't have asset context, so render a
            // lightweight body here that links to the asset from metadata.
            // Production callers should reach SlotDetailView via AssetDetailView's
            // navigation (which has both rows in scope).
            if let row = resource as? ResourceRow {
                SlotDetailStandaloneFallback(slot: row)
            } else {
                UnknownResourceDetailBody(resource: resource, label: "Slot")
            }
        case .booking, .fund, .position, .assignment, .rotation,
             .guestPass, .contribution, .proposal, .unknown:
            UnknownResourceDetailBody(
                resource: resource,
                label: String(describing: resource.resourceType)
            )
        }
    }
}

/// When a slot is opened directly (e.g., from a notification deep-link)
/// without an asset row in scope, fetch the asset on-demand and render
/// the full SlotDetailView once both rows are available.
private struct SlotDetailStandaloneFallback: View {
    let slot: ResourceRow
    @Environment(AppState.self) private var appState
    @State private var asset: ResourceRow?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let asset {
                SlotDetailView(slot: slot, asset: asset)
            } else if let loadError {
                Text(loadError).foregroundStyle(.red).padding()
            } else {
                ProgressView().task { await loadAsset() }
            }
        }
    }

    @MainActor
    private func loadAsset() async {
        guard let assetIdString = slot.metadata["asset_id"]?.stringValue,
              let assetId = UUID(uuidString: assetIdString) else {
            loadError = "Cupo sin asset_id en metadata"
            return
        }
        do {
            asset = try await appState.resourceRepo.resource(assetId)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct UnknownResourceDetailBody: View {
    public let resource: any Resource
    public let label: String

    public var body: some View {
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
