import SwiftUI

struct ConfirmationView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var feedback = 0

    var onCreateFirstEvent: () -> Void
    var onInviteMore: () -> Void
    var onGoHome: () -> Void

    var body: some View {
        ZStack {
            RuulMeshBackground(.violet)
            VStack(spacing: RuulSpacing.s7) {
                Spacer()
                hero
                Spacer()
                ctaStack
                Spacer().frame(height: RuulSpacing.s5)
            }
            .padding(.horizontal, RuulSpacing.s5)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.success, trigger: feedback)
        .task {
            feedback &+= 1
            // Show toast if any invites were sent.
            // Toast handling is deferred — owner shows it via a state or
            // we'd inject a toast bus here. For V1, we just rely on
            // post-onboarding screens to surface this.
            await coord.finishOnboarding()
        }
    }

    private var hero: some View {
        VStack(spacing: RuulSpacing.s4) {
            Text("Tu grupo está vivo")
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.center)
            if let group = coord.createdGroup {
                Text("\(group.name) tiene \(coord.pendingInvites.count) miembros invitados.")
                    .ruulTextStyle(RuulTypography.bodyLarge)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var ctaStack: some View {
        VStack(spacing: RuulSpacing.s2) {
            RuulButton("Crear el primer evento", style: .primary, size: .large, fillsWidth: true, action: onCreateFirstEvent)
            RuulButton("Invitar más gente", style: .glass, size: .large, fillsWidth: true, action: onInviteMore)
            RuulButton("Ir al inicio", style: .plain, size: .medium, action: onGoHome)
        }
    }
}
