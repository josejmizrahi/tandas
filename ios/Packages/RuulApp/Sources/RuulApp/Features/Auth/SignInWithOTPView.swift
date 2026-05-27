import SwiftUI
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
}
