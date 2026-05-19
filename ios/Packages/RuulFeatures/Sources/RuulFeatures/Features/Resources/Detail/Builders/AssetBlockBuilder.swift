import Foundation
import RuulCore

/// Stub builder for Asset resources. Produces a minimal valid
/// `ResourceBlocks` from a `ResourceRow` with `resource_type = 'asset'`
/// (or `'space'` / `'slot'` which share the same visual shell).
///
/// Source per Addendum F: `ResourceRow` from `LiveResourceRepository`
/// (+ `AssetLifecycleRepository` for custody chain — Phase 2).
///
/// TODO: Phase 2 — add custodianship block (custody chain from
/// `resources.metadata.{custodian_id, owner_id, holder_id}`),
/// media strip (evidence thumbnails), booking/check-out block.
public struct AssetBlockBuilder: BlockBuilder {
    public typealias Source = ResourceRow

    public init() {}

    public func build(
        source: ResourceRow,
        viewer: BlockViewerContext,
        now: Date
    ) -> ResourceBlocks {
        let name = source.metadata["name"]?.stringValue ?? "Activo"

        return ResourceBlocks(
            identity: IdentityRibbon(
                icon: "key.fill",
                tint: .assets,
                title: name,
                subtitleSegments: ["Activo", source.status.capitalized]
            ),
            state: StateHeadline(
                headline: source.status.capitalized,
                supportingFacts: [],
                primaryAction: nil,
                urgency: .ambient
            ),
            properties: makeProperties(source: source),
            capabilities: [],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }

    // MARK: - Properties

    private func makeProperties(source: ResourceRow) -> PropertiesBlock {
        var rows: [FactRow] = [
            FactRow(id: "status", key: "Estado", value: source.status.capitalized)
        ]
        if let custodian = source.metadata["custodian_display_name"]?.stringValue {
            rows.append(FactRow(id: "custodian", key: "Custodio", value: custodian))
        }
        return PropertiesBlock(rows: rows)
    }
}
