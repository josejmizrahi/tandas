import SwiftUI
import RuulCore

/// P1.3 — cambio de teléfono o correo de inicio de sesión. Reutiliza el flujo
/// OTP de Supabase Auth: `start*Change` envía el código al destino NUEVO;
/// `confirm*Change` lo verifica y completa el cambio.
struct ChangeContactSheet: View {
    enum Kind: String, Identifiable {
        case phone
        case email

        var id: String { rawValue }

        var title: String { self == .phone ? "Cambiar teléfono" : "Cambiar correo" }
        var fieldPrompt: String { self == .phone ? "+52 1 55 0000 0000" : "tu@email.com" }
        var fieldLabel: String { self == .phone ? "Nuevo teléfono" : "Nuevo correo" }
    }

    let kind: Kind
    let authService: any AuthService
    /// Llamado tras confirmar — el caller refresca perfil/settings.
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newValue = ""
    @State private var code = ""
    @State private var didSendCode = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if !didSendCode {
                    Section {
                        TextField(kind.fieldPrompt, text: $newValue)
                            .keyboardType(kind == .phone ? .phonePad : .emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text(kind.fieldLabel)
                    } footer: {
                        Text("Te enviaremos un código de verificación al nuevo destino.")
                    }

                    Section {
                        Button {
                            Task { await sendCode() }
                        } label: {
                            if isWorking {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Enviar código").frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(trimmedValue.isEmpty || isWorking)
                    }
                } else {
                    Section {
                        TextField("Código de 6 dígitos", text: $code)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .font(.title3.monospacedDigit())
                    } header: {
                        Text("Te enviamos un código a \(trimmedValue)")
                    }

                    Section {
                        Button {
                            Task { await confirm() }
                        } label: {
                            if isWorking {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Confirmar cambio").frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(code.count < 6 || isWorking)

                        Button("Usar otro destino") {
                            didSendCode = false
                            code = ""
                            errorMessage = nil
                        }
                        .font(.footnote)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .ruulCompactSheet()
    }

    private var trimmedValue: String {
        newValue.trimmingCharacters(in: .whitespaces)
    }

    private func sendCode() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            switch kind {
            case .phone: try await authService.startPhoneChange(trimmedValue)
            case .email: try await authService.startEmailChange(trimmedValue)
            }
            didSendCode = true
        } catch {
            errorMessage = "No pudimos enviar el código. Revisa el dato e intenta de nuevo."
        }
    }

    private func confirm() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            switch kind {
            case .phone: try await authService.confirmPhoneChange(otp: code, newPhone: trimmedValue)
            case .email: try await authService.confirmEmailChange(otp: code, newEmail: trimmedValue)
            }
            onChanged()
            dismiss()
        } catch {
            errorMessage = "Código incorrecto o expirado. Intenta de nuevo."
        }
    }
}

#Preview("Cambiar teléfono") {
    ChangeContactSheet(kind: .phone, authService: MockAuthService(), onChanged: {})
}
