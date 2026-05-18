import SwiftUI
import RuulUI
import RuulCore

/// Free-text body section. Reads `resource.metadata.description` and
/// renders it as plain body text — no card chrome, no section header.
/// Mirrors the Apple Invites / Calendar treatment: description sits in
/// the page rhythm as prose, not as a card-with-caption.
///
/// Honors the `description` capability declared in `CapabilityCatalog.v1`
/// (mig 00109 seeds it for every event). Returns `EmptyView` when the
/// metadata key is missing or empty so the always-on cap stays harmless.
public struct DescriptionSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "description",
        priority: 150,
        isEnabledFor: { caps in caps.contains(CapabilityID.description) },
        render: { ctx in AnyView(DescriptionSectionView(context: ctx)) }
    )

    public var body: some View {
        if let body = descriptionBody {
            Text(body)
                .ruulTextStyle(RuulTypography.bodyLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RuulSpacing.xxs)
                .accessibilityLabel("Descripción del recurso")
                .accessibilityValue(body)
        }
    }

    private var descriptionBody: String? {
        guard let raw = context.resource.metadata["description"]?.stringValue else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
