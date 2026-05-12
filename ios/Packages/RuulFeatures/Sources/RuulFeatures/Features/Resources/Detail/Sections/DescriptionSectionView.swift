import SwiftUI
import RuulUI
import RuulCore

/// Free-text body section. Reads `resource.metadata.description` and
/// renders it in a soft card. Returns `EmptyView` when the metadata
/// key is missing or empty, so the cap stays always-on at the DB level
/// without polluting the detail layout for events that didn't fill it in.
///
/// Honors the `description` capability declared in `CapabilityCatalog.v1`
/// (mig 00109 seeds it for every event resource).
public struct DescriptionSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "description",
        priority: 150,
        isEnabledFor: { caps in caps.contains("description") },
        render: { ctx in AnyView(DescriptionSectionView(context: ctx)) }
    )

    public var body: some View {
        if let body = descriptionBody {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                sectionHeader("DESCRIPCIÓN")
                Text(body)
                    .ruulTextStyle(RuulTypography.bodyLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(RuulSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground()
                    .accessibilityLabel("Descripción del recurso")
                    .accessibilityValue(body)
            }
        }
    }

    /// Trimmed description from `resource.metadata.description`, or nil
    /// when the field is missing, NULL, or whitespace-only.
    private var descriptionBody: String? {
        guard let raw = context.resource.metadata["description"]?.stringValue else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
