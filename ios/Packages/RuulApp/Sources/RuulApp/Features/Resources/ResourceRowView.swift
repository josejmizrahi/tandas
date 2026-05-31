import SwiftUI
import RuulCore

/// Row used by `GroupResourcesCard` (compact) and `ResourcesListView`.
/// Icon + name + subtitle (type · ownership), plus a per-type hint
/// pulled from the descriptor's metadata schema (e.g. mileage for
/// vehicle, address for space, quantity for inventory). The hint only
/// renders when the underlying metadata key is present, so envelope
/// rows without per-type data still look correct.
public struct ResourceRowView: View {
    let resource: GroupResource
    let compact: Bool

    public init(resource: GroupResource, compact: Bool = false) {
        self.resource = resource
        self.compact = compact
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: resource.resourceType.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(resource.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(resource.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let hint = descriptorHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !compact, !resource.previewText.isEmpty {
                    Text(resource.previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(resource.name). \(resource.subtitle)"))
    }

    /// First populated metadata field from the descriptor schema,
    /// rendered as "label: value". Returns nil when none of the
    /// per-type fields carry a value.
    private var descriptorHint: String? {
        for field in resource.resourceType.descriptor.metadataSchema {
            if let value = resource.metadataString(forKey: field.key) {
                return "\(String(localized: field.label)): \(value)"
            }
        }
        return nil
    }
}

#Preview("Rows") {
    List {
        Section { ResourceRowView(resource: ResourcesPreviewData.fund) }
        Section { ResourceRowView(resource: ResourcesPreviewData.space) }
        Section { ResourceRowView(resource: ResourcesPreviewData.asset, compact: true) }
        Section { ResourceRowView(resource: ResourcesPreviewData.document) }
        Section { ResourceRowView(resource: ResourcesPreviewData.vehicle) }
        Section { ResourceRowView(resource: ResourcesPreviewData.inventory) }
    }
}
