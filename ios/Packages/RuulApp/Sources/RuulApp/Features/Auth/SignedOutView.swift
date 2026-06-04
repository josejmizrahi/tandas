import SwiftUI
import RuulCore
import AuthenticationServices
import CryptoKit

/// F.2 — pantalla de entrada: Sign in with Apple u OTP por teléfono/email.
/// `anon` no entra: el único camino a la app es Apple o verificar un OTP real.
public struct SignedOutView: View {
    let authService: any AuthService

    @Environment(\.colorScheme) private var colorScheme

    private enum Channel: String, CaseIterable, Identifiable {
        case phone = "Teléfono"
        case email = "Email"
        var id: String { rawValue }
    }

    private enum Step {
        case enterDestination
        case enterCode
    }

    @State private var channel: Channel = .phone
    @State private var step: Step = .enterDestination
    @State private var destination = ""
    @State private var code = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// Nonce crudo que se hashea (SHA256) en el request de Apple y se manda en
    /// crudo a Supabase para validar el id_token.
    @State private var appleNonce: String?

    public init(authService: any AuthService) {
        self.authService = authService
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "person.3.sequence.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                    Text("Ruul")
                        .font(.largeTitle.bold())
                    Text("Tu mundo compartido: contextos, recursos,\neventos, reglas y dinero.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                switch step {
                case .enterDestination:
                    VStack(spacing: 20) {
                        appleSection
                        orDivider
                        destinationForm
                    }
                case .enterCode:
                    codeForm
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Sign in with Apple

    @ViewBuilder
    private var appleSection: some View {
        SignInWithAppleButton(.signIn) { request in
            let nonce = Self.randomNonce()
            appleNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(nonce)
        } onCompletion: { result in
            // Extraemos los Strings (Sendable) en el closure (MainActor) y solo
            // esos cruzan al Task — ASAuthorization no es Sendable.
            switch result {
            case .success(let authorization):
                guard
                    let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                    let tokenData = credential.identityToken,
                    let idToken = String(data: tokenData, encoding: .utf8),
                    let nonce = appleNonce
                else {
                    errorMessage = "No pudimos completar el inicio con Apple. Intenta de nuevo."
                    return
                }
                Task { await completeApple(idToken: idToken, nonce: nonce) }
            case .failure(let error):
                // El usuario canceló: no mostramos error.
                if let asError = error as? ASAuthorizationError, asError.code == .canceled { return }
                errorMessage = "Inicio con Apple cancelado o fallido."
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .disabled(isWorking)
    }

    @ViewBuilder
    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text("o").font(.footnote).foregroundStyle(.secondary)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
    }

    // MARK: - Paso 1: destino

    @ViewBuilder
    private var destinationForm: some View {
        VStack(spacing: 16) {
            Picker("Canal", selection: $channel) {
                ForEach(Channel.allCases) { channel in
                    Text(channel.rawValue).tag(channel)
                }
            }
            .pickerStyle(.segmented)

            TextField(
                channel == .phone ? "+52 1 55 0000 0000" : "tu@email.com",
                text: $destination
            )
            .textFieldStyle(.roundedBorder)
            .keyboardType(channel == .phone ? .phonePad : .emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button {
                Task { await sendOTP() }
            } label: {
                if isWorking {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Enviar código").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
        }
    }

    // MARK: - Paso 2: código

    @ViewBuilder
    private var codeForm: some View {
        VStack(spacing: 16) {
            Text("Te enviamos un código a\n\(destination)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Código de 6 dígitos", text: $code)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit())

            Button {
                Task { await verifyOTP() }
            } label: {
                if isWorking {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Entrar").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(code.count < 6 || isWorking)

            Button("Usar otro número o correo") {
                step = .enterDestination
                code = ""
                errorMessage = nil
            }
            .font(.footnote)
        }
    }

    // MARK: - Acciones

    private func sendOTP() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let target = destination.trimmingCharacters(in: .whitespaces)
        do {
            switch channel {
            case .phone:
                try await authService.sendPhoneOTP(target)
            case .email:
                try await authService.sendEmailOTP(target)
            }
            step = .enterCode
        } catch {
            errorMessage = "No pudimos enviar el código. Revisa el dato e intenta de nuevo."
        }
    }

    private func verifyOTP() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let target = destination.trimmingCharacters(in: .whitespaces)
        do {
            switch channel {
            case .phone:
                _ = try await authService.verifyPhoneOTP(target, code: code)
            case .email:
                _ = try await authService.verifyEmailOTP(target, code: code)
            }
            // La sesión se propaga sola vía AuthService.sessionStream → SessionStore.
        } catch {
            errorMessage = "Código incorrecto o expirado. Vuelve a intentar."
        }
    }

    private func completeApple(idToken: String, nonce: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await authService.signInWithApple(idToken: idToken, nonce: nonce)
            // La sesión se propaga sola vía AuthService.sessionStream → SessionStore.
        } catch {
            errorMessage = "No pudimos iniciar sesión con Apple. Intenta de nuevo."
        }
    }

    // MARK: - Nonce (Sign in with Apple)

    /// Nonce aleatorio (caracteres URL-safe). Se manda en crudo a Supabase y su
    /// SHA256 va en el request de Apple (anti-replay del id_token).
    /// `randomElement()` usa `SystemRandomNumberGenerator`, criptográficamente
    /// seguro en plataformas Apple.
    private static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).map { _ in charset.randomElement()! })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// F.2 — splash mientras carga la sesión o el person actor.
public struct SessionLoadingView: View {
    let message: String

    public init(message: String = "Cargando tu sesión…") {
        self.message = message
    }

    public var body: some View {
        LoadingStateView(title: message)
            .background(Theme.Surface.appBackground)
    }
}

#Preview("Signed out") {
    SignedOutView(authService: MockAuthService())
}

#Preview("Loading") {
    SessionLoadingView()
}
