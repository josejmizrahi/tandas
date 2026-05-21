import SwiftUI
import RuulUI
import RuulCore

/// Step 2 of the new ResourceCreationSheet. Lists the variants the
/// `ResourceVariantRegistry` declares for the chosen type. Each row
/// surfaces the variant's icon, human name, one-line summary, and the
/// founder-voice examples ("Cena · Reunión · Brindis") that anchor the
/// abstract variant to concrete things the user recognizes.
///
/// Doctrine 2026-05-18: variants are universal, not vertical. The user
/// sees "Inmueble", not "Casa de campo de Mizrahi" — vertical specifics
/// arrive after creation via the post-create intent screen and resource
/// detail.
struct ResourceVariantPicker: View {
    let coordinator: ResourceCreationCoordinator
    let type: ResourceType

    private var variants: [ResourceVariant] {
        coordinator.variants.pickableVariants(for: type)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                heading
                if variants.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: RuulSpacing.sm) {
                        ForEach(variants) { variant in
                            variantRow(variant)
                        }
                    }
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("¿Qué tipo de \(type.humanLabel.lowercased())?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("Elige el más parecido. Cualquiera funciona.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: RuulSpacing.sm) {
            Image(systemName: "tray")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            Text("Por ahora no hay variantes para \(type.humanLabel.lowercased()).")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xl)
    }

    private func variantRow(_ variant: ResourceVariant) -> some View {
        Button {
            coordinator.pickVariant(variant)
        } label: {
            HStack(alignment: .top, spacing: RuulSpacing.md) {
                iconBadge(variant.icon)
                VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                    Text(variant.humanName)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(variant.summary)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !variant.examples.isEmpty {
                        examplesLine(variant.examples)
                    }
                }
                Spacer(minLength: RuulSpacing.xs)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconBadge(_ symbol: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.ruulAccent.opacity(0.15))
                .frame(width: 40, height: 40)
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Color.ruulAccent)
        }
    }

    /// Comma-separated examples line. Kept as plain text rather than
    /// chips so multi-line wrapping behaves naturally inside the card
    /// and the layout doesn't fight RuulSeparatedRows / DynamicType.
    private func examplesLine(_ examples: [String]) -> some View {
        Text(examples.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(Color(.tertiaryLabel))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, RuulSpacing.xxs)
    }
}
