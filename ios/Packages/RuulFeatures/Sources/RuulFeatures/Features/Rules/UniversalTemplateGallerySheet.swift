import SwiftUI
import RuulUI
import RuulCore

/// Universal Rule Templates Gallery — Beta-1 canonical surface for picking
/// a rule template. Per Plans/Active/UniversalRuleTemplates.md §8.2:
///
///   "Elige un patrón → llena los huecos → mira cómo se lee → actívalo."
///
/// Doctrine framing: this is NOT a starter-examples shortcut; it IS the
/// canonical way to create a rule for the universal flow. Per-piece
/// composer remains available for admins via the "+" header button.
///
/// Renders each template as a card with: doctrinal_category badge, title,
/// description, interpolated `naturalLanguagePreviewTemplate`, "Esto NO"
/// antitemplate lines, and chips per vertical (§8.3).
///
/// Callers:
///   - `RulesView.emptyStateBody` — Gallery-first empty-state CTA
///   - `RuleComposerView` toolbar — keeps the "Ejemplo" lightbulb path
///     where templates are mid-flow starter seeds
public struct UniversalTemplateGallerySheet: View {
    let templates: [RuleBuilderTemplate]
    var onSelect: (RuleBuilderTemplate) -> Void
    var onCancel: () -> Void

    public init(
        templates: [RuleBuilderTemplate],
        onSelect: @escaping (RuleBuilderTemplate) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.templates = templates
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(templates, id: \.id) { template in
                        Button(action: { onSelect(template) }) {
                            templateCard(template)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Elige el patrón que se parezca a lo que quieres. Llena los huecos y actívalo.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .textCase(nil)
                }
            }
            .navigationTitle("Elige un patrón")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onCancel)
                }
            }
        }
    }

    /// Universal Beta-1 Gallery card. Renders, in order:
    ///   - doctrinal category badge (e.g. "C — Obligation")
    ///   - title (`displayNameES`)
    ///   - one-line description
    ///   - templated natural-language preview (interpolated from
    ///     `naturalLanguagePreviewTemplate` if set — falls back to
    ///     `descriptionES`)
    ///   - "Esto NO" antitemplate hints
    ///   - up to 3 vertical-example chips
    @ViewBuilder
    private func templateCard(_ template: RuleBuilderTemplate) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            if template.doctrinalCategory != "uncategorized" {
                Text(template.doctrinalCategory)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.ruulTextTertiary.opacity(0.12))
                    )
            }
            Text(template.displayNameES)
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Text(template.descriptionES)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .lineLimit(3)
            if template.naturalLanguagePreviewTemplate != nil {
                Text(RuleSentenceFormatter.preview(forTemplate: template))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .padding(RuulSpacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.ruulTextTertiary.opacity(0.06))
                    .cornerRadius(RuulSpacing.xs)
            }
            ForEach(template.whatItIsNot, id: \.self) { hint in
                HStack(alignment: .top, spacing: 4) {
                    Text("·")
                        .foregroundStyle(Color.ruulTextTertiary)
                    Text(hint)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
            }
            if !template.examplesAcrossVerticals.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(template.examplesAcrossVerticals.prefix(3)), id: \.vertical) { example in
                        Text(example.vertical)
                            .font(.caption2)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.ruulTextTertiary.opacity(0.08))
                            )
                    }
                }
            }
        }
        .padding(.vertical, RuulSpacing.xs)
    }
}
