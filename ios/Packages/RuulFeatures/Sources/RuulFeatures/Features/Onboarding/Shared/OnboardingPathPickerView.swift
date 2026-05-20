import SwiftUI
import RuulUI
import RuulCore

/// Step 0 del onboarding. Pregunta "¿Qué quieres hacer?" antes de
/// instanciar el FounderOnboardingCoordinator. Sin esto, el usuario
/// nuevo sin invite code caía directo al flujo de fundador (7 pasos),
/// y para unirse a un grupo tenía que llegar al RootShell y buscar
/// la opción — discoverability cero.
///
/// Dos paths exclusivos:
///   - **Crear un grupo nuevo** → arranca FounderOnboardingCoordinator
///   - **Unirme con código** → input inline → arranca InvitedOnboardingCoordinator
///
/// Se salta cuando hay `pendingInviteCode` (deeplink resolvió la decisión)
/// o cuando hay `OnboardingProgress` activo (restore mid-flow).
public struct OnboardingPathPickerView: View {
    public let onCreate: () -> Void
    public let onJoin: (String) -> Void

    @State private var showJoinInput = false
    @State private var inviteCode = ""

    public init(onCreate: @escaping () -> Void, onJoin: @escaping (String) -> Void) {
        self.onCreate = onCreate
        self.onJoin = onJoin
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            VStack(spacing: RuulSpacing.xxl) {
                Spacer()
                header
                Spacer()
                if showJoinInput {
                    joinInputBlock
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    pathButtons
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Spacer().frame(height: RuulSpacing.lg)
            }
            .padding(.horizontal, RuulSpacing.lg)
            .animation(.ruulMorph, value: showJoinInput)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(spacing: RuulSpacing.sm) {
            Text("ruul")
                .font(.system(size: 88, weight: .bold))
                .foregroundStyle(Color.ruulTextPrimary)
            Text(showJoinInput ? "Pega tu código" : "Bienvenido")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.center)
            Text(showJoinInput
                 ? "Te lo compartió alguien del grupo."
                 : "¿Estrenas grupo o te invitaron a uno?")
                .font(.subheadline)
                .foregroundStyle(Color.ruulTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var pathButtons: some View {
        VStack(spacing: RuulSpacing.md) {
            pathButton(
                title: "Crear un grupo nuevo",
                subtitle: "Tú armas el grupo desde cero — 2 minutos.",
                systemImage: "plus.circle.fill",
                primary: true,
                action: onCreate
            )
            pathButton(
                title: "Unirme con código",
                subtitle: "Alguien me compartió un código de invitación.",
                systemImage: "person.badge.plus",
                primary: false,
                action: { showJoinInput = true }
            )
        }
    }

    private func pathButton(
        title: String,
        subtitle: String,
        systemImage: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: RuulSpacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(primary ? Color.ruulTextInverse : Color.ruulTextPrimary)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(primary ? Color.ruulTextInverse : Color.ruulTextPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(primary ? Color.ruulTextInverse.opacity(0.8) : Color.ruulTextSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .fill(primary ? Color.ruulTextPrimary : Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(primary ? Color.clear : Color.ruulSeparator, lineWidth: 1)
            )
        }
        .buttonStyle(.ruulPress)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private var joinInputBlock: some View {
        VStack(spacing: RuulSpacing.md) {
            RuulTextField(
                "8 caracteres",
                text: $inviteCode,
                label: "Código de invitación"
            )
            RuulButton(
                "Continuar",
                style: .primary,
                size: .large,
                fillsWidth: true,
                action: submitCode
            )
            .disabled(normalizedCode.isEmpty)
            Button("Atrás") {
                showJoinInput = false
                inviteCode = ""
            }
            .font(.footnote)
            .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var normalizedCode: String {
        inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func submitCode() {
        let code = normalizedCode
        guard !code.isEmpty else { return }
        onJoin(code)
    }
}
