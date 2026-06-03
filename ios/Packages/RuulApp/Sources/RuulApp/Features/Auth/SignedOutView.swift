import SwiftUI
import RuulCore

/// F.2 — pantalla de entrada: OTP por teléfono o email.
/// `anon` no entra: el único camino a la app es verificar un OTP real.
public struct SignedOutView: View {
    let authService: any AuthService

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
                    destinationForm
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
}

/// F.2 — splash mientras carga la sesión o el person actor.
public struct SessionLoadingView: View {
    let message: String

    public init(message: String = "Cargando tu sesión…") {
        self.message = message
    }

    public var body: some View {
        LoadingStateView(title: message)
            .background(Color(uiColor: .systemBackground))
    }
}

#Preview("Signed out") {
    SignedOutView(authService: MockAuthService())
}

#Preview("Loading") {
    SessionLoadingView()
}
