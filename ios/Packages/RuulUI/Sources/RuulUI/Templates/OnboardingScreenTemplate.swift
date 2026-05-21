import SwiftUI

/// Full-screen template for an onboarding step. Combines mesh background +
/// `OnboardingStepContainer` + optional skip toolbar item.
public struct OnboardingScreenTemplate<Content: View>: View {
    private let progress: Double
    private let title: String
    private let subtitle: String?
    private let primaryCTA: (label: String, isLoading: Bool, perform: () -> Void)?
    private let secondaryCTA: (label: String, perform: () -> Void)?
    private let onSkip: (() -> Void)?
    private let canContinue: Bool
    private let content: () -> Content

    public init(
        progress: Double,
        title: String,
        subtitle: String? = nil,
        primaryCTA: (label: String, isLoading: Bool, perform: () -> Void)? = nil,
        secondaryCTA: (label: String, perform: () -> Void)? = nil,
        onSkip: (() -> Void)? = nil,
        canContinue: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.progress = progress
        self.title = title
        self.subtitle = subtitle
        self.primaryCTA = primaryCTA
        self.secondaryCTA = secondaryCTA
        self.onSkip = onSkip
        self.canContinue = canContinue
        self.content = content
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            OnboardingStepContainer(
                progress: progress,
                title: title,
                subtitle: subtitle,
                primaryCTA: primaryCTA,
                secondaryCTA: secondaryCTA,
                canContinue: canContinue,
                content: content
            )
        }
        .toolbar {
            if let onSkip {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Saltar", action: onSkip)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }
}

#if DEBUG
#Preview("OnboardingScreenTemplate") {
    NavigationStack {
        OnboardingScreenTemplate(
            progress: 0.6,
            title: "¿Cómo te llaman?",
            subtitle: "Así te van a ver tus grupos.",
            primaryCTA: ("Continuar", false, { }),
            onSkip: { }
        ) {
            RuulTextField("Tu nombre", text: .constant("Jose"), label: "Nombre")
        }
    }
}
#endif
