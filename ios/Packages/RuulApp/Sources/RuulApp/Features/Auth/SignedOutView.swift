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
                    Text("Tus grupos viven, deciden y recuerdan aquí:\neventos, reglas, decisiones y dinero.")
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

                legalFooter
            }
            .padding(.horizontal, 24)
        }
    }

    /// V.2 — al entrar aceptas términos y aviso de privacidad (LFPDPPP / App Store).
    @ViewBuilder
    private var legalFooter: some View {
        VStack(spacing: 4) {
            Text("Al continuar aceptas los")
            HStack(spacing: 4) {
                Link("Términos", destination: URL(string: "https://ruul.mx/legal/terms")!)
                Text("y el")
                Link("Aviso de privacidad", destination: URL(string: "https://ruul.mx/legal/privacy")!)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 8)
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
        // 7.B.3 (audit 2026-06-14) — validar formato ANTES de pegar al backend
        // para dar feedback inmediato y diferenciar de errores de red.
        guard isValid(target, for: channel) else {
            errorMessage = channel == .phone
                ? "Revisa el número. Usa formato internacional (ej. +52 81 1234 5678)."
                : "Correo no válido. Revisa que tenga la forma nombre@dominio.com."
            return
        }
        do {
            switch channel {
            case .phone:
                try await authService.sendPhoneOTP(target)
            case .email:
                try await authService.sendEmailOTP(target)
            }
            step = .enterCode
        } catch {
            errorMessage = authErrorMessage(error, fallback:
                channel == .phone
                    ? "No pudimos enviar el código al teléfono. Intenta de nuevo en unos segundos."
                    : "No pudimos enviar el código al correo. Intenta de nuevo en unos segundos."
            )
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
            errorMessage = authErrorMessage(error, fallback: "Código incorrecto o expirado. Vuelve a pedir uno nuevo.")
        }
    }

    /// 7.B.3 — discrimina errores de red vs auth real para copy específico.
    /// Los errores de Supabase Auth con código `otp_expired` o `invalid_otp`
    /// son distintos de un `URLError` de red.
    private func authErrorMessage(_ error: Error, fallback: String) -> String {
        let ns = error as NSError
        // URLError: sin conexión / timeout.
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet:
                return "Sin conexión a internet. Revisa tu red e intenta de nuevo."
            case NSURLErrorTimedOut:
                return "El servidor tardó demasiado en responder. Intenta de nuevo."
            default:
                return "Problema de red al contactar al servidor. Intenta de nuevo."
            }
        }
        // Mensaje del backend: si menciona "rate" o "many requests", traducimos.
        let raw = error.localizedDescription.lowercased()
        if raw.contains("rate") || raw.contains("too many") {
            return "Demasiados intentos. Espera un momento antes de pedir otro código."
        }
        if raw.contains("expired") {
            return "El código ya expiró. Pide uno nuevo."
        }
        if raw.contains("invalid") && raw.contains("code") {
            return "Código incorrecto. Revisa los 6 dígitos."
        }
        return fallback
    }

    /// 7.B.3 — validación de formato lightweight cliente-side. Evita pegarle
    /// al backend con destinos obviamente inválidos.
    private func isValid(_ destination: String, for channel: Channel) -> Bool {
        switch channel {
        case .phone:
            // Mínimo viable: empieza con + y tiene al menos 8 dígitos.
            let digits = destination.filter(\.isNumber)
            return destination.hasPrefix("+") && digits.count >= 8
        case .email:
            // Mínimo viable: contiene @ y un punto después.
            guard let atIndex = destination.firstIndex(of: "@") else { return false }
            let afterAt = destination[atIndex...]
            return afterAt.contains(".") && destination.count >= 5
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
        RuulLoadingState(title: message)
            .background(Theme.Surface.appBackground)
    }
}

#Preview("Signed out") {
    SignedOutView(authService: MockAuthService())
}

#Preview("Loading") {
    SessionLoadingView()
}
