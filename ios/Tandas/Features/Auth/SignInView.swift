import SwiftUI
import SwiftData
import AuthenticationServices
import Supabase
import RuulUI
import RuulCore

/// Sign-in surface for returning users (session is nil but the device has
/// already completed onboarding). Two paths:
///
/// - **Apple Sign In** — calls `signInWithIdToken` directly on the Supabase
///   client. The LiveAuthService's authStateChanges subscription catches the
///   new session and AuthGate routes to MainTabView automatically.
/// - **Phone OTP** — uses `AuthService.sendPhoneOTP` / `verifyPhoneOTP`,
///   which is the standard sign-in (not the anon-promote) flow used during
///   onboarding. Requires Twilio/Supabase Auth phone provider configured.
///
/// "Crear cuenta nueva" clears the has-onboarded flag so AuthGate falls
/// through to the founder onboarding flow.
struct SignInView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var phoneInput: String = ""
    @State private var phoneE164: String = ""
    @State private var otpCode: String = ""
    @State private var step: Step = .start
    @State private var nonce: String = AppleNonceGen.generate()
    @State private var error: String?
    @State private var isLoading: Bool = false
    @State private var hasOTPError: Bool = false

    enum Step: Hashable { case start, otp }

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    header
                    SwiftUI.Group {
                        switch step {
                        case .start:
                            signInOptions
                        case .otp:
                            otpEntry
                        }
                    }
                    .animation(.ruulMorph, value: step)
                    Spacer(minLength: RuulSpacing.xl)
                    createAccountLink
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.s8)
                .padding(.bottom, RuulSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(step == .start ? "Bienvenido de vuelta" : "Confirma tu código")
                .ruulTextStyle(RuulTypography.displayMedium)
                .foregroundStyle(Color.ruulTextPrimary)
            Text(step == .start
                ? "Inicia sesión para volver a tus grupos."
                : "Llega a \(PhoneFormatter.displayFormat(phoneE164)). Pégalo aquí.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    // MARK: - Start step

    private var signInOptions: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            appleButton
            divider
            phoneSection
            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
            }
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleNonceGen.sha256(nonce)
        } onCompletion: { result in
            handleAppleCompletion(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 52)
        .clipShape(Capsule())
    }

    private var divider: some View {
        HStack(spacing: RuulSpacing.sm) {
            Rectangle().fill(Color.ruulSeparator).frame(height: 1)
            Text("o")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
            Rectangle().fill(Color.ruulSeparator).frame(height: 1)
        }
    }

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            RuulPhoneField(
                text: $phoneInput,
                label: "Tu número",
                error: nil
            )
            RuulButton(
                "Enviar código",
                style: .primary,
                size: .large,
                isLoading: isLoading,
                fillsWidth: true,
                action: sendOTP
            )
            .disabled(phoneInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - OTP step

    private var otpEntry: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            RuulOTPInput(code: $otpCode, hasError: $hasOTPError) { fullCode in
                verifyOTP(fullCode)
            }
            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
            }
            HStack(spacing: RuulSpacing.sm) {
                RuulButton("Atrás", style: .secondary, size: .medium) {
                    step = .start
                    otpCode = ""
                    error = nil
                    hasOTPError = false
                }
                RuulButton(
                    "Confirmar",
                    style: .primary,
                    size: .medium,
                    isLoading: isLoading,
                    fillsWidth: true
                ) {
                    verifyOTP(otpCode)
                }
                .disabled(otpCode.count != 6)
            }
        }
    }

    // MARK: - Create account link

    private var createAccountLink: some View {
        HStack(spacing: RuulSpacing.xs) {
            Text("¿No tienes cuenta?")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Button {
                createNewAccount()
            } label: {
                Text("Crear nueva")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulAccent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Actions

    /// Opt out of "returning user" routing and start a fresh founder
    /// onboarding. Clears the persisted hasOnboarded flag (so AuthGate
    /// stops routing here) AND any stale `OnboardingProgress` row from
    /// a previous flow that didn't complete — without this, tapping
    /// "Crear nueva" can drop the user into a half-finished onboarding
    /// from a prior install instead of a clean welcome.
    private func createNewAccount() {
        OnboardingCompletion.clear()
        let manager = OnboardingProgressManager(context: modelContext)
        try? manager.clear()
    }

    private func sendOTP() {
        guard let e164 = PhoneFormatter.smartE164(phoneInput) else {
            error = "Número inválido."
            return
        }
        phoneE164 = e164
        error = nil
        isLoading = true
        Task {
            defer { Task { @MainActor in isLoading = false } }
            do {
                try await app.auth.sendPhoneOTP(e164)
                await MainActor.run {
                    step = .otp
                    otpCode = ""
                    hasOTPError = false
                }
            } catch {
                await MainActor.run {
                    self.error = "No pudimos enviar el código: \(error.localizedDescription)"
                }
            }
        }
    }

    private func verifyOTP(_ code: String) {
        guard code.count == 6, !isLoading else { return }
        isLoading = true
        error = nil
        Task {
            defer { Task { @MainActor in isLoading = false } }
            do {
                _ = try await app.auth.verifyPhoneOTP(phoneE164, code: code)
                // Success: LiveAuthService propagates the session via
                // sessionStream → AppState.session updates → AuthGate routes
                // to MainTabView. No navigation needed here.
            } catch {
                await MainActor.run {
                    self.error = "Código incorrecto."
                    self.hasOTPError = true
                }
            }
        }
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                error = "No pudimos leer las credenciales de Apple."
                return
            }
            let captured = nonce
            isLoading = true
            error = nil
            Task {
                defer { Task { @MainActor in isLoading = false } }
                do {
                    let client = SupabaseEnvironment.shared
                    _ = try await client.auth.signInWithIdToken(
                        credentials: OpenIDConnectCredentials(
                            provider: .apple,
                            idToken: token,
                            nonce: captured
                        )
                    )
                    // authStateChanges in LiveAuthService catches the new
                    // session; AuthGate routes automatically.
                } catch {
                    await MainActor.run {
                        self.error = "No pudimos verificar con Apple: \(error.localizedDescription)"
                    }
                }
            }
        case .failure:
            // User cancelled — no-op (button reappears, can retry).
            break
        }
    }
}
