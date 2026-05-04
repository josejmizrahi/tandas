import SwiftUI
import AuthenticationServices
import Supabase

struct PhoneVerifyView: View {
    @Environment(FounderOnboardingCoordinator.self) private var coord
    @State private var phoneInput: String = ""
    @State private var nonce: String = AppleNonceGen.generate()
    @State private var appleError: String?

    var body: some View {
        OnboardingScreenTemplate(
            mesh: .cool,
            progress: progressValue,
            stepCount: FounderStep.allCases.count,
            title: "Confirma tu número",
            subtitle: "Verifica con Apple o teléfono para guardar todo.",
            primaryCTA: ("Enviar código", coord.isLoading, sendCode),
            canContinue: !phoneInput.trimmingCharacters(in: .whitespaces).isEmpty
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                appleSignInSection
                divider
                phoneSection
            }
        }
    }

    private var appleSignInSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
                request.nonce = AppleNonceGen.sha256(nonce)
            } onCompletion: { result in
                handleAppleCompletion(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .clipShape(Capsule())

            if let appleError {
                Text(appleError)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulSemanticError)
            }
        }
    }

    private var divider: some View {
        HStack(spacing: RuulSpacing.s3) {
            Rectangle().fill(Color.ruulBorderSubtle).frame(height: 1)
            Text("o")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
            Rectangle().fill(Color.ruulBorderSubtle).frame(height: 1)
        }
    }

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            RuulPhoneField(
                text: $phoneInput,
                label: "Tu número",
                error: errorMessage
            )
            Text("Te llamamos primero por WhatsApp. Si no llega, te mandamos un SMS.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var progressValue: Double {
        Double(FounderStep.phoneVerify.index) / Double(FounderStep.allCases.count - 1)
    }

    private var errorMessage: String? {
        if case .otpSendFailed = coord.error { return coord.error?.localizedDescription }
        return nil
    }

    private func sendCode() {
        guard let e164 = PhoneFormatter.smartE164(phoneInput) else { return }
        coord.phoneE164 = e164
        Task { await coord.advanceFromPhoneVerify() }
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                appleError = "No pudimos leer las credenciales de Apple."
                return
            }
            let captured = nonce
            Task {
                do {
                    let client = SupabaseEnvironment.shared
                    _ = try await client.auth.signInWithIdToken(
                        credentials: OpenIDConnectCredentials(
                            provider: .apple,
                            idToken: token,
                            nonce: captured
                        )
                    )
                    await coord.completeViaApple()
                } catch {
                    appleError = "No pudimos verificar con Apple: \(error.localizedDescription)"
                }
            }
        case .failure:
            // User cancelled — no-op (button reappears, can retry).
            break
        }
    }
}

