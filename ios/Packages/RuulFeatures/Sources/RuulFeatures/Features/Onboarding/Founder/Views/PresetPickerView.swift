import SwiftUI
import RuulUI
import RuulCore

/// Step 3 of the founder onboarding (Founder Welcome Flow S1).
/// 3 cards: Reuniones recurrentes / Activo compartido / Empezar de cero.
public struct PresetPickerView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var selected: OnboardingPreset?

    public init() {}

    public var body: some View {
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.allCases.count,
            title: "¿Para qué será \(coord.draft.name.isEmpty ? "tu grupo" : coord.draft.name)?",
            subtitle: "Elige cómo arrancar. Puedes agregar más después.",
            // W3-B2: explicit "Continuar" CTA — previously the screen
            // auto-advanced 350ms after tap, making the preset choice
            // irreversible without a back button. Audit B "Bad defaults".
            primaryCTA: continueCTA,
            canContinue: selected != nil
        ) {
            VStack(spacing: RuulSpacing.md) {
                ForEach(OnboardingPreset.all) { preset in
                    presetCard(for: preset)
                }
            }
        }
    }

    /// Show the primary CTA only after a preset is tapped; until then
    /// the card itself is the only affordance. Locked while the
    /// coordinator is materializing the group.
    private var continueCTA: (String, Bool, () -> Void)? {
        guard let preset = selected else { return nil }
        return ("Continuar", coord.isLoading, {
            Task { await coord.selectPreset(preset) }
        })
    }

    private var progressValue: Double {
        Double(FounderStep.preset.index) / Double(FounderStep.allCases.count - 1)
    }

    private func presetCard(for preset: OnboardingPreset) -> some View {
        let isSelected = selected?.id == preset.id
        return Button {
            // W3-B2: tap only selects — the explicit "Continuar" CTA
            // performs the irreversible action. Removed the 350ms
            // DispatchQueue auto-advance.
            withAnimation(.ruulSnappy) { selected = preset }
        } label: {
            HStack(alignment: .top, spacing: RuulSpacing.md) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.ruulAccent.opacity(0.15) : Color.ruulSurface)
                        .frame(width: 48, height: 48)
                    Image(systemName: preset.icon)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(isSelected ? Color.ruulAccent : Color.ruulTextSecondary)
                }
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    Text(preset.displayName)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(preset.summary)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.leading)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(preset.sampleResources, id: \.self) { sample in
                            HStack(spacing: RuulSpacing.xxs) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 4))
                                    .foregroundStyle(Color.ruulTextTertiary)
                                Text(sample)
                                    .ruulTextStyle(RuulTypography.caption)
                                    .foregroundStyle(Color.ruulTextTertiary)
                            }
                        }
                    }
                    .padding(.top, RuulSpacing.xxs)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.ruulAccent)
                        .font(.system(size: 22))
                        .transition(.scale.combined(with: .opacity))
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
                    .stroke(isSelected ? Color.ruulAccent : Color.ruulSeparator,
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(coord.isLoading)
        .opacity(coord.isLoading && !isSelected ? 0.5 : 1.0)
    }
}
