import SwiftUI
import AuthenticationServices
import CryptoKit
import RuulCore

/// Phone-OTP sign-in for the Foundation shell. Uses the existing
/// `AuthService` actor from `RuulCore/Supabase/AuthService.swift` — no
/// direct Supabase calls. Apple sign-in + email OTP are deferred until
/// after the Foundation loop closes end-to-end on device.
///
/// State machine: `.enterPhone` → `.enterCode` → (success closes the
/// view via `SessionStore`'s stream observation in `RuulAppShell`).
struct SignInWithOTPView: View {
    let container: DependencyContainer

    @State private var step: Step = .enterPhone
    @State private var phone: String = "+52"
    @State private var code: String = ""
    @State private var isWorking: Bool = false
    @State private var error: UserFacingError?
    /// Raw nonce kept across the round-trip with Apple: we send its
    /// SHA-256 to ASAuthorizationAppleIDRequest, then forward the raw
    /// nonce to Supabase together with the returned identity token.
    @State private var appleRawNonce: String?

    private enum Step: Equatable {
        case enterPhone
        case enterCode(sentTo: String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch step {
                    case .enterPhone:
                        TextField("Teléfono", text: $phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .autocorrectionDisabled()
                    case .enterCode(let sentTo):
                        Text("Te mandamos un código a \(sentTo).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("Código de 6 dígitos", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                }

                Section {
                    Button(action: primaryAction) {
                        HStack {
                            if isWorking {
                                ProgressView()
                            }
                            Text(primaryLabel)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(isPrimaryDisabled)
                }

                if case .enterCode(let sentTo) = step {
                    Section {
                        Button("Usar otro número") {
                            step = .enterPhone
                            code = ""
                        }
                        Button("Reenviar código a \(sentTo)") {
                            Task { await sendCode(phoneNumber: sentTo) }
                        }
                    }
                }

                Section {
                    SignInWithAppleButton(
                        onRequest: { request in
                            let raw = AppleAuth.randomNonce()
                            appleRawNonce = raw
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = AppleAuth.sha256(raw)
                        },
                        onCompletion: { result in
                            Task { await handleAppleCompletion(result) }
                        }
                    )
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                } header: {
                    Text("O entra con")
                }
            }
            .navigationTitle("Entrar a Ruul")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                error?.title ?? "",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                actions: {
                    Button("OK") { error = nil }
                },
                message: {
                    Text(error?.message ?? "")
                }
            )
        }
    }

    private var primaryLabel: String {
        switch step {
        case .enterPhone: return "Enviar código"
        case .enterCode: return "Verificar"
        }
    }

    private var isPrimaryDisabled: Bool {
        if isWorking { return true }
        switch step {
        case .enterPhone: return phone.count < 10
        case .enterCode: return code.count < 6
        }
    }

    private func primaryAction() {
        Task {
            switch step {
            case .enterPhone:
                await sendCode(phoneNumber: phone)
            case .enterCode(let sentTo):
                await verify(phoneNumber: sentTo, otp: code)
            }
        }
    }

    private func sendCode(phoneNumber: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await container.authService.sendPhoneOTP(phoneNumber)
            step = .enterCode(sentTo: phoneNumber)
        } catch {
            self.error = UserFacingError.from(error)
        }
    }

    private func verify(phoneNumber: String, otp: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await container.authService.verifyPhoneOTP(phoneNumber, code: otp)
            // SessionStore subscribed to the auth stream in RuulAppShell will
            // pick up the new session and the shell's switch will rotate to
            // .signedIn automatically. Nothing to do here on success.
        } catch {
            self.error = UserFacingError.from(error)
        }
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = appleRawNonce
            else {
                error = UserFacingError(message: "Apple no devolvió un token válido. Vuelve a intentar.")
                return
            }
            isWorking = true
            defer { isWorking = false }
            do {
                _ = try await container.signInWithApple(idToken: idToken, nonce: nonce)
                appleRawNonce = nil
                // Shell rotates via SessionStore on the next stream emit.
            } catch {
                self.error = UserFacingError.from(error)
            }
        case .failure(let raw):
            let nsError = raw as NSError
            // ASAuthorizationError.canceled = 1001 — silent (user backed out).
            if nsError.domain == ASAuthorizationError.errorDomain && nsError.code == ASAuthorizationError.canceled.rawValue {
                return
            }
            error = UserFacingError.from(raw)
        }
    }
}

/// Sign In with Apple nonce helpers. The raw nonce is sent to Supabase's
/// `signInWithIdToken`; the SHA-256 hashed version goes into the
/// `ASAuthorizationAppleIDRequest`. Apple bakes the hash into the JWT it
/// returns, so Supabase verifies the round trip by hashing the raw nonce
/// on its end.
private enum AppleAuth {
    static func randomNonce(length: Int = 32) -> String {
        let chars: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
