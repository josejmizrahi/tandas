import SwiftUI
import RuulUI
import RuulCore

public struct ConfirmationView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var feedback = 0

    public var onCreateFirstEvent: () -> Void
    public var onInviteMore: () -> Void
    public var onGoHome: () -> Void

    public init(onCreateFirstEvent: @escaping () -> Void, onInviteMore: @escaping () -> Void, onGoHome: @escaping () -> Void) {
        self.onCreateFirstEvent = onCreateFirstEvent
        self.onInviteMore = onInviteMore
        self.onGoHome = onGoHome
    }

    public var body: some View {
        ZStack {
            RuulMeshBackground(.violet)
            VStack(spacing: RuulSpacing.xxl) {
                Spacer()
                hero
                Spacer()
                ctaStack
                Spacer().frame(height: RuulSpacing.lg)
            }
            .padding(.horizontal, RuulSpacing.lg)
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
        VStack(spacing: RuulSpacing.md) {
            Text("Tu grupo está vivo")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)
            if let group = coord.createdGroup {
                Text("\(group.name) tiene \(coord.pendingInvites.count) miembros invitados.")
                    .font(.body)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var ctaStack: some View {
        VStack(spacing: RuulSpacing.xs) {
            RuulButton("Crear el primer evento", style: .primary, size: .large, fillsWidth: true, action: onCreateFirstEvent)
            RuulButton("Invitar más gente", style: .glass, size: .large, fillsWidth: true, action: onInviteMore)
            RuulButton("Ir al inicio", style: .plain, size: .medium, action: onGoHome)
        }
    }
}
