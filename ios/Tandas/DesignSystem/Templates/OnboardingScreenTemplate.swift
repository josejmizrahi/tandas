import SwiftUI

/// Full-screen template for an onboarding step. Combines mesh background +
/// `OnboardingStepContainer` + optional skip toolbar item.
public struct OnboardingScreenTemplate<Content: View>: View {
    private let mesh: RuulMeshBackground.Variant
    private let progress: Double
    private let stepCount: Int?
    private let title: String
    private let subtitle: String?
    private let primaryCTA: (label: String, isLoading: Bool, perform: () -> Void)
    private let secondaryCTA: (label: String, perform: () -> Void)?
    private let onSkip: (() -> Void)?
    private let canContinue: Bool
    private let content: () -> Content

    public init(
        mesh: RuulMeshBackground.Variant = .cool,
        progress: Double,
        stepCount: Int? = nil,
        title: String,
        subtitle: String? = nil,
        primaryCTA: (label: String, isLoading: Bool, perform: () -> Void),
        secondaryCTA: (label: String, perform: () -> Void)? = nil,
        onSkip: (() -> Void)? = nil,
        canContinue: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.mesh = mesh
        self.progress = progress
        self.stepCount = stepCount
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
            RuulMeshBackground(mesh)
            OnboardingStepContainer(
                progress: progress,
                stepCount: stepCount,
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
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
        }
    }
}

#if DEBUG
#Preview("OnboardingScreenTemplate") {
    NavigationStack {
        OnboardingScreenTemplate(
            mesh: .violet,
            progress: 0.6,
            stepCount: 5,
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
