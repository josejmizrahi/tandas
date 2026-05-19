import Foundation
import RuulCore

/// Stub builder for Right resources. Produces a minimal valid
/// `ResourceBlocks` from a `ResourceRow` with `resource_type = 'right'`.
///
/// Source per Addendum F: `ResourceRow` from `LiveResourceRepository`.
/// Full block fidelity (eligibility, transfer, delegation blocks) TBD
/// post-Beta-1 when the right lifecycle is fully specified.
///
/// TODO: Phase 2 — add eligibility block (capability "eligibility"),
/// transfer/delegation blocks, and rights-specific properties.
public struct RightBlockBuilder: BlockBuilder {
    public typealias Source = ResourceRow

    public init() {}

    public func build(
        source: ResourceRow,
        viewer: BlockViewerContext,
        now: Date
    ) -> ResourceBlocks {
        let name = source.metadata["name"]?.stringValue ?? "Derecho"

        return ResourceBlocks(
            identity: IdentityRibbon(
                icon: "person.badge.key.fill",
                tint: .neutral,
                title: name,
                subtitleSegments: ["Derecho", source.status.capitalized]
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
        if let holderName = source.metadata["holder_display_name"]?.stringValue {
            rows.append(FactRow(id: "holder", key: "Titular", value: holderName))
        }
        return PropertiesBlock(rows: rows)
    }
}
