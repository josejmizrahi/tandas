import SwiftUI
import SwiftData
import AuthenticationServices
import Supabase
import RuulUI
import RuulCore

/// Mode the AuthGate hands `SignInView` so the same auth surface can
/// frame itself for first-time-on-device users and for returning users
/// without two parallel screens.
///
/// Beta 1 W1-4: a brand-new device (`!hasOnboarded && session == nil`)
/// used to land on "Bienvenido de vuelta" / "Inicia sesión para volver a
/// tus grupos." — pure returning-user copy that read like the wrong
/// screen to anyone signing up for the first time. The mode here
/// switches the header and hides the "¿No tienes cuenta? Crear nueva"
/// fallback (irrelevant for someone who's already on the create path).
public enum SignInMode: Hashable, Sendable {
    /// Brand-new device, no `OnboardingCompletion` flag set. Apple
    /// Sign In + Phone OTP both auto-create accounts, so the screen
    /// frames itself as "Bienvenido a Ruul / crea tu grupo".
    case firstTime
    /// Device has completed onboarding before. Standard sign-in copy.
    case returning
}

public extension SignInMode {
    var startHeadline: String {
        switch self {
        case .firstTime: "Bienvenido a Ruul"
        case .returning: "Bienvenido de vuelta"
        }
    }

    var startSubtitle: String {
        switch self {
        case .firstTime: "Crea tu grupo o únete a uno con tu teléfono o Apple ID."
        case .returning: "Inicia sesión para volver a tus grupos."
        }
    }

    /// The "¿No tienes cuenta? Crear nueva" link only makes sense for
    /// a returning user who wants to start fresh with a different
    /// identity. In firstTime mode, the entire screen IS the create
    /// path, so the link is redundant noise.
    var showsCreateAccountLink: Bool {
        switch self {
        case .firstTime: false
        case .returning: true
        }
    }
}

/// Sign-in surface — frames itself as create-account or sign-in based on
/// `mode`. Two auth paths regardless of mode:
///
/// - **Apple Sign In** — calls `signInWithIdToken` directly on the Supabase
///   client. The LiveAuthService's authStateChanges subscription catches the
///   new session and AuthGate routes to MainTabView automatically.
/// - **Phone OTP** — uses `AuthService.sendPhoneOTP` / `verifyPhoneOTP`,
///   which is the standard sign-in (not the anon-promote) flow used during
///   onboarding. Requires Twilio/Supabase Auth phone provider configured.
///
/// In `.returning` mode, "Crear cuenta nueva" clears the has-onboarded
/// flag so AuthGate falls through to the founder onboarding flow.
public struct SignInView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var phoneInput: String = ""

    private let mode: SignInMode

    public init(mode: SignInMode = .returning) {
        self.mode = mode
    }

    @State private var phoneE164: String = ""
    @State private var otpCode: String = ""
    @State private var step: Step = .start
    @State private var nonce: String = AppleNonceGen.generate()
    @State private var error: String?
    @State private var isLoading: Bool = false
    @State private var hasOTPError: Bool = false

    public enum Step: Hashable { case start, otp }

    public var body: some View {
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
                    if mode.showsCreateAccountLink {
                        createAccountLink
                    }
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
            Text(step == .start ? mode.startHeadline : "Confirma tu código")
                .ruulTextStyle(RuulTypography.displayMedium)
                .foregroundStyle(Color.ruulTextPrimary)
            Text(step == .start
                ? mode.startSubtitle
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
                    // W2-C2: translator filters raw English from Twilio /
                    // GoTrue / network. Was "...el código: Network connection
                    // lost. (Domain=NSURLErrorDomain ...)".
                    self.error = "No pudimos enviar el código. \(error.ruulUserMessage)"
                }
                // Beta 1 W4 F-4.5: bucket-coded telemetry.
                let beta = BetaAnalytics(analytics: app.analytics)
                await beta.errorShown(code: RuulErrorTranslator.errorCode(for: error))
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
                        // W2-C2: filter raw Apple/Supabase Auth strings.
                        self.error = "No pudimos verificar con Apple. \(error.ruulUserMessage)"
                    }
                    // Beta 1 W4 F-4.5: bucket-coded telemetry.
                    let beta = BetaAnalytics(analytics: app.analytics)
                    await beta.errorShown(code: RuulErrorTranslator.errorCode(for: error))
                }
            }
        case .failure:
            // User cancelled — no-op (button reappears, can retry).
            break
        }
    }
}
