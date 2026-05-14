import SwiftUI
import RuulUI
import RuulCore

/// Step 1 of the Universal ResourceWizard. Cards for every resource
/// type the registry exposes (`ResourceBuilderRegistry.surfaceTypes`).
///
/// Tier 0 truth gate (2026-05-12): a card is tappable iff
/// `ResourceBuilderRegistry` has a builder registered for that type AND
/// the server-side `build_resource_from_draft` supports it. Today that
/// is exactly two: `event` and `asset`. Every other surface type
/// (slot/fund/contribution/proposal/…) appears explicitly as a
/// "Próximamente" placeholder — never as a creatable option whose
/// submit would explode in the RPC's `else raise` branch (mig 00101).
///
/// Founder framing: "Create Resource must never lie." A disabled card
/// communicating "Phase 2" is honest; a tappable card that crashes the
/// flow halfway through is not.
public struct ResourceTypePickerView: View {
    public let registry: ResourceBuilderRegistry
    public var onSelect: (ResourceType, any ResourceBuilder) -> Void

    public init(registry: ResourceBuilderRegistry, onSelect: @escaping (ResourceType, any ResourceBuilder) -> Void) {
        self.registry = registry
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.md) {
                ForEach(Array(ResourceBuilderRegistry.surfaceTypes.enumerated()), id: \.offset) { _, type in
                    typeCard(for: type)
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
    }

    @ViewBuilder
    private func typeCard(for type: ResourceType) -> some View {
        if let builder = registry.builder(for: type) {
            Button {
                onSelect(type, builder)
            } label: {
                cardContent(
                    icon: builder.icon,
                    title: builder.displayName,
                    summary: builder.summary,
                    isImplemented: true
                )
            }
            .buttonStyle(.plain)
        } else if let info = ResourceBuilderRegistry.placeholderInfo(for: type) {
            // Wrap in a non-interactive container so VoiceOver and the
            // hit-test layer both treat this card as decorative. The
            // visual `.opacity(0.55)` alone wasn't enough of a signal —
            // a user tapping a "Próximamente" card got nothing back and
            // sometimes assumed the app froze.
            cardContent(
                icon: info.icon,
                title: info.displayName,
                summary: info.summary,
                isImplemented: false
            )
            .accessibilityLabel("\(info.displayName), próximamente")
            .accessibilityHint("Este tipo de recurso aún no se puede crear.")
            .accessibilityAddTraits(.isStaticText)
            .allowsHitTesting(false)
        }
    }

    private func cardContent(icon: String, title: String, summary: String, isImplemented: Bool) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.md) {
            ZStack {
                Circle()
                    .fill(isImplemented ? Color.ruulAccent.opacity(0.15) : Color.ruulSurface)
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(RuulTypography.titleMedium.font)
                    .foregroundStyle(isImplemented ? Color.ruulAccent : Color.ruulTextTertiary)
            }
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                HStack(spacing: RuulSpacing.xs) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(isImplemented ? Color.ruulTextPrimary : Color.ruulTextTertiary)
                    if !isImplemented {
                        Text("Próximamente")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                            .padding(.horizontal, RuulSpacing.xs)
                            .padding(.vertical, 2)
                            .background(Color.ruulSurface, in: Capsule())
                            .overlay(Capsule().stroke(Color.ruulSeparator, lineWidth: 0.5))
                    }
                }
                Text(summary)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            if isImplemented {
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.labelSemibold)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
        .padding(RuulSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .fill(Color.ruulSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 1)
        )
        .opacity(isImplemented ? 1.0 : 0.55)
    }
}
