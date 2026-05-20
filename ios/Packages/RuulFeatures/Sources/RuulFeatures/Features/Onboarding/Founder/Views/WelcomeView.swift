import SwiftUI
import RuulUI
import RuulCore

public struct WelcomeView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            VStack(spacing: RuulSpacing.xxl) {
                Spacer()
                wordmark
                VStack(spacing: RuulSpacing.sm) {
                    Text("Bienvenido a ruul")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.center)
                    Text("Vamos a crear tu grupo en 3 minutos.")
                        .font(.body)
                        .foregroundStyle(Color.secondary)
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
            .font(.system(size: 88, weight: .bold))
            .foregroundStyle(Color.primary)
    }
}
