import SwiftUI

struct WelcomeView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord

    var body: some View {
        ZStack {
            RuulMeshBackground(.cool)
            VStack(spacing: RuulSpacing.s7) {
                Spacer()
                wordmark
                VStack(spacing: RuulSpacing.s3) {
                    Text("Bienvenido a ruul")
                        .ruulTextStyle(RuulTypography.displayLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .multilineTextAlignment(.center)
                    Text("Vamos a crear tu grupo en 3 minutos.")
                        .ruulTextStyle(RuulTypography.bodyLarge)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                RuulButton("Empezar", style: .primary, size: .large, fillsWidth: true) {
                    Task { await coord.advanceFromWelcome() }
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.bottom, RuulSpacing.s5)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Typography wordmark — no asset. Letter-spaced lowercase, gradient fill.
    private var wordmark: some View {
        Text("ruul")
            .font(.system(size: 88, weight: .bold, design: .default))
            .tracking(-2)
            .foregroundStyle(
                LinearGradient(
                    colors: [.ruulAccentPrimary, .ruulAccentSecondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}
