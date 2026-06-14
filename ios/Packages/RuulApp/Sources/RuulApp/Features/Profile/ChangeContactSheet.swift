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
                    } footer: {
                        // 7.C.3 — "Usar otro destino" se baja a footer + style
                        // secundario para no competir con el CTA primario.
                        Button("Usar otro destino") {
                            didSendCode = false
                            code = ""
                            errorMessage = nil
                        }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
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
        // 7.C.3 — validación de formato ANTES del backend para feedback inmediato.
        guard isValid(trimmedValue) else {
            errorMessage = kind == .phone
                ? "Revisa el número. Usa formato internacional (ej. +52 81 1234 5678)."
                : "Correo no válido. Revisa que tenga la forma nombre@dominio.com."
            return
        }
        do {
            switch kind {
            case .phone: try await authService.startPhoneChange(trimmedValue)
            case .email: try await authService.startEmailChange(trimmedValue)
            }
            didSendCode = true
        } catch {
            errorMessage = changeContactErrorCopy(error, fallback:
                kind == .phone
                    ? "No pudimos enviar el código al teléfono. Intenta de nuevo."
                    : "No pudimos enviar el código al correo. Intenta de nuevo."
            )
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
            errorMessage = changeContactErrorCopy(error, fallback: "Código incorrecto o expirado. Pide uno nuevo.")
        }
    }

    /// 7.C.3 — copy específico cuando el error matchea un caso conocido
    /// (red, formato, duplicado, expirado). Fallback al copy general.
    private func changeContactErrorCopy(_ error: Error, fallback: String) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorNotConnectedToInternet {
                return "Sin conexión a internet. Revisa tu red e intenta de nuevo."
            }
            if ns.code == NSURLErrorTimedOut {
                return "El servidor tardó demasiado en responder. Intenta de nuevo."
            }
            return "Problema de red al contactar al servidor. Intenta de nuevo."
        }
        let raw = error.localizedDescription.lowercased()
        if raw.contains("already") || raw.contains("exists") || raw.contains("duplicate") {
            return kind == .phone
                ? "Este teléfono ya está en uso por otra cuenta."
                : "Este correo ya está en uso por otra cuenta."
        }
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

    /// 7.C.3 — validación lightweight cliente-side.
    private func isValid(_ value: String) -> Bool {
        switch kind {
        case .phone:
            let digits = value.filter(\.isNumber)
            return value.hasPrefix("+") && digits.count >= 8
        case .email:
            guard let atIndex = value.firstIndex(of: "@") else { return false }
            let afterAt = value[atIndex...]
            return afterAt.contains(".") && value.count >= 5
        }
    }
}

#Preview("Cambiar teléfono") {
    ChangeContactSheet(kind: .phone, authService: MockAuthService(), onChanged: {})
}
