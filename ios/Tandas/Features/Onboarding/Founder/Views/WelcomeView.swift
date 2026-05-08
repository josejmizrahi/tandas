import SwiftUI
import RuulUI

struct WelcomeView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            VStack(spacing: RuulSpacing.xxl) {
                Spacer()
                wordmark
                VStack(spacing: RuulSpacing.sm) {
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
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.lg)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Typography wordmark — no asset. Letter-spaced lowercase, gradient fill.
    private var wordmark: some View {
        Text("ruul")
            .ruulTextStyle(RuulTypography.wordmark)
            .foregroundStyle(Color.ruulTextPrimary)
    }
}
