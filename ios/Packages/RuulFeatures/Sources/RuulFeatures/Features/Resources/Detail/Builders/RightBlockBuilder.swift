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
        let name       = source.metadata["name"]?.stringValue ?? "Derecho"
        let statusEs   = ResourceStatusLocalization.es(source.status)
        let holderName = source.metadata["holder_display_name"]?.stringValue

        return ResourceBlocks(
            identity: IdentityRibbon(
                icon: "person.badge.key.fill",
                tint: .neutral,
                title: name,
                // Subtitle: family only. Status lives in the headline +
                // Estado property — repeating it here was a 3-way echo
                // ("Derecho · Active" / "Active" hero / "Estado: Active").
                subtitleSegments: ["Derecho"]
            ),
            state: StateHeadline(
                // Headline answers "¿qué está pasando ahora?". When a
                // holder is set, that's the load-bearing fact; status
                // trails as supporting. Otherwise show the localized
                // status as the calm anchor.
                headline: holderName.map { "Titular: \($0)" } ?? statusEs,
                supportingFacts: holderName != nil ? [statusEs] : [],
                primaryAction: nil,
                urgency: .ambient
            ),
            properties: makeProperties(statusEs: statusEs, holderName: holderName),
            capabilities: [],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }

    // MARK: - Properties

    private func makeProperties(statusEs: String, holderName: String?) -> PropertiesBlock {
        var rows: [FactRow] = [
            FactRow(id: "status", key: "Estado", value: statusEs)
        ]
        if let holderName {
            rows.append(FactRow(id: "holder", key: "Titular", value: holderName))
        }
        return PropertiesBlock(rows: rows)
    }
}
