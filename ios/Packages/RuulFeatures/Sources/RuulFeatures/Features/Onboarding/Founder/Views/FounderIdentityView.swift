import SwiftUI
import PhotosUI
import RuulUI
import RuulCore

public struct FounderIdentityView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @Environment(AppState.self) private var app
    @State private var selectedItem: PhotosPickerItem?
    @State private var avatarImageData: Data?
    @State private var isSwitchingToSignIn: Bool = false
    @FocusState private var nameFocused: Bool

    public var body: some View {
        @Bindable var bindable = coord
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.visibleSteps.count,
            title: "¿Cómo te llamas?",
            subtitle: "Así te van a ver tus grupos.",
            primaryCTA: ("Continuar", coord.isLoading, primaryAction),
            onSkip: { Task { await coord.skipIdentity() } },
            canContinue: !coord.displayName.trimmingCharacters(in: .whitespaces).isEmpty
        ) {
            VStack(spacing: RuulSpacing.lg) {
                avatarSection
                RuulTextField(
                    "Tu nombre",
                    text: $bindable.displayName,
                    label: "Nombre"
                )
                .focused($nameFocused)
                signInEscape
                    .padding(.top, RuulSpacing.lg)
            }
        }
        .onAppear { nameFocused = true }
        .onChange(of: selectedItem) { _, newValue in
            Task { await loadAvatar(from: newValue) }
        }
    }

    /// Defensive escape hatch: a returning user whose `hasOnboarded` flag
    /// was wiped (e.g. reinstall pre-Keychain-migration, or first-launch
    /// race) lands here even though their account already exists. The
    /// link signs out any anon session created mid-flow, marks
    /// `hasOnboarded` so AuthGate routes to SignInView next render, and
    /// clears the persisted onboarding entity. Mirrors SignInView's
    /// "¿No tienes cuenta? Crear nueva" link.
    private var signInEscape: some View {
        HStack(spacing: RuulSpacing.xs) {
            Text("¿Ya tienes cuenta?")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Button {
                switchToSignIn()
            } label: {
                Text("Iniciar sesión")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulAccent)
            }
            .buttonStyle(.plain)
            .disabled(isSwitchingToSignIn)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("¿Ya tienes cuenta? Iniciar sesión")
    }

    private func switchToSignIn() {
        guard !isSwitchingToSignIn else { return }
        isSwitchingToSignIn = true
        Task {
            // Sign out the anon session if `GroupsRepository.createInitial`
            // already ran. Failure is fine — the worst case is the anon
            // lingers until the user signs in for real, at which point
            // signInWithIdToken / verifyOTP replaces it. Anon sessions
            // never get a real APNs token registered (no push perms
            // requested yet), so revokeTokenIfRegistered is a no-op here
            // — but the orchestrator stays consistent across the codebase.
            try? await app.signOut()
            // Mark the flag so AuthGate's `session==nil && hasOnboarded`
            // gate routes to SignInView. The ".onReceive" subscriber on
            // AuthGate picks up the notification synchronously.
            OnboardingCompletion.mark()
            // OnboardingProgress is cleared by AuthGate's
            // `refreshOnboardingState` once it sees the new state
            // (`isCleanLoggedOut == true`). No manual clear needed.
            await MainActor.run { isSwitchingToSignIn = false }
        }
    }

    private var progressValue: Double {
        FounderStep.identity.progressFraction
    }

    private func primaryAction() {
        Task { await coord.advanceFromIdentity() }
    }

    @ViewBuilder
    private var avatarSection: some View {
        PhotosPicker(selection: $selectedItem, matching: .images) {
            ZStack {
                if let data = avatarImageData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: RuulSize.avatarXLarge, height: RuulSize.avatarXLarge)
                        .clipShape(Circle())
                } else {
                    RuulAvatar(
                        name: coord.displayName.isEmpty ? "?" : coord.displayName,
                        size: .hero,
                        border: .glass
                    )
                }
                Image(systemName: "camera.fill")
                    .font(RuulTypography.labelSemibold.font)
                    .foregroundStyle(Color.ruulTextInverse)
                    .padding(RuulSpacing.xs)
                    .background(Color.ruulTextPrimary, in: Circle())
                    .offset(x: RuulSpacing.xxl, y: RuulSpacing.xxl)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cambiar foto")
    }

    private func loadAvatar(from item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self) {
            avatarImageData = data
            // For V1, we keep the avatar local until the founder completes
            // OTP. Upload to storage is a follow-up (not in V1 plan).
        }
    }
}
