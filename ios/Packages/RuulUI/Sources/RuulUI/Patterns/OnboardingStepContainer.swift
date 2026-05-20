import SwiftUI

/// Standard layout for an onboarding step.
///
/// - top: a `RuulProgressBar` showing where the user is in the flow.
/// - middle: arbitrary content.
/// - bottom: a primary CTA button, plus optional secondary CTA.
/// - optional skip button in the trailing toolbar position (caller wires the
///   toolbar item).
public struct OnboardingStepContainer<Content: View>: View {
    private let progress: Double
    private let stepCount: Int?
    private let title: String
    private let subtitle: String?
    private let primaryCTA: (label: String, isLoading: Bool, perform: () -> Void)?
    private let secondaryCTA: (label: String, perform: () -> Void)?
    private let canContinue: Bool
    private let content: () -> Content

    public init(
        progress: Double,
        stepCount: Int? = nil,
        title: String,
        subtitle: String? = nil,
        primaryCTA: (label: String, isLoading: Bool, perform: () -> Void)? = nil,
        secondaryCTA: (label: String, perform: () -> Void)? = nil,
        canContinue: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.progress = progress
        self.stepCount = stepCount
        self.title = title
        self.subtitle = subtitle
        self.primaryCTA = primaryCTA
        self.secondaryCTA = secondaryCTA
        self.canContinue = canContinue
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.sm)
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                        Text(title)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(Color.ruulTextPrimary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.body)
                                .foregroundStyle(Color.ruulTextSecondary)
                        }
                    }
                    content()
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.xxl)
            }
            ctaStack
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.md)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let stepCount {
            RuulProgressBar(value: progress, style: .steps(stepCount))
        } else {
            RuulProgressBar(value: progress)
        }
    }

    @ViewBuilder
    private var ctaStack: some View {
        VStack(spacing: RuulSpacing.xs) {
            if let primaryCTA {
                RuulButton(primaryCTA.label, style: .primary, size: .large, isLoading: primaryCTA.isLoading, fillsWidth: true, action: primaryCTA.perform)
                    .disabled(!canContinue)
            }
            if let secondaryCTA {
                RuulButton(secondaryCTA.label, style: .plain, size: .medium, action: secondaryCTA.perform)
            }
        }
    }
}

#if DEBUG
#Preview("OnboardingStepContainer") {
    OnboardingStepContainer(
        progress: 0.4,
        stepCount: 5,
        title: "¿Cómo te llaman?",
        subtitle: "Así te van a ver tus grupos.",
        primaryCTA: ("Continuar", false, { })
    ) {
        VStack(spacing: RuulSpacing.md) {
            RuulTextField("Tu nombre", text: .constant("Jose"), label: "Nombre")
        }
    }
    .background(Color.ruulBackground)
}
#endif
