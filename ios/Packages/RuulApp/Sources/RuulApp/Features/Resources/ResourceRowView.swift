import SwiftUI
import RuulCore

/// Row used by both `GroupResourcesCard` (compact) and
/// `ResourcesListView`. Type-icon + name + subtitle (type · ownership);
/// optional one-line description preview when not compact.
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
}

#Preview("Rows") {
    List {
        Section { ResourceRowView(resource: ResourcesPreviewData.fund) }
        Section { ResourceRowView(resource: ResourcesPreviewData.space) }
        Section { ResourceRowView(resource: ResourcesPreviewData.asset, compact: true) }
        Section { ResourceRowView(resource: ResourcesPreviewData.document) }
    }
}
