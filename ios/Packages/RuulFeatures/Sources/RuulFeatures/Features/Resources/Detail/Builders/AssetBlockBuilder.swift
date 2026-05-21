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
        let name      = source.metadata["name"]?.stringValue ?? "Activo"
        let statusEs  = ResourceStatusLocalization.es(source.status)
        let custodian = source.metadata["custodian_display_name"]?.stringValue

        return ResourceBlocks(
            identity: IdentityRibbon(
                icon: "key.fill",
                tint: .assets,
                title: name,
                // Subtitle: family only ("Activo" = asset noun).
                // Redundant English status string ("Active") was here
                // before; dropped to avoid the "Activo · Active" echo.
                subtitleSegments: ["Activo"]
            ),
            state: StateHeadline(
                // Headline answers "¿qué está pasando ahora?". When a
                // custodian is set, that's the load-bearing fact;
                // status trails as supporting. Otherwise show the
                // localized status as the calm anchor.
                headline: custodian.map { "En custodia de \($0)" } ?? statusEs,
                supportingFacts: custodian != nil ? [statusEs] : [],
                primaryAction: nil,
                urgency: .ambient
            ),
            properties: makeProperties(statusEs: statusEs, custodian: custodian),
            capabilities: [],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }

    // MARK: - Properties

    private func makeProperties(statusEs: String, custodian: String?) -> PropertiesBlock {
        var rows: [FactRow] = [
            FactRow(id: "status", key: "Estado", value: statusEs)
        ]
        if let custodian {
            rows.append(FactRow(id: "custodian", key: "Custodio", value: custodian))
        }
        return PropertiesBlock(rows: rows)
    }
}
