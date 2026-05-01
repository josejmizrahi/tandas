import SwiftUI
import AuthenticationServices

enum AuthMethod: String, CaseIterable, Identifiable {
    case phone, email
    var id: String { rawValue }
    var label: String { self == .phone ? "Teléfono" : "Email" }
}

@MainActor
@Observable
final class AuthViewModel {
    var method: AuthMethod = .phone
    var phone: String = "+52"
    var email: String = ""
    var isSending: Bool = false
    var errorMessage: String?
    var pendingChannel: OTPChannel?

    let auth: any AuthService

    init(auth: any AuthService) { self.auth = auth }

    func sendOTP() async {
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            switch method {
            case .phone:
                let phoneTrim = phone.trimmingCharacters(in: .whitespaces)
                guard phoneTrim.hasPrefix("+") && phoneTrim.count >= 10 else {
                    errorMessage = "Número inválido. Usa formato +52…"
                    return
                }
                try await auth.sendPhoneOTP(phoneTrim)
                pendingChannel = .phone(phoneTrim)
            case .email:
                let emailTrim = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard emailTrim.contains("@") else {
                    errorMessage = "Email inválido."
                    return
                }
                try await auth.sendEmailOTP(emailTrim)
                pendingChannel = .email(emailTrim)
            }
        } catch {
            errorMessage = "No se pudo enviar el código. Intenta de nuevo."
        }
    }
}

enum OTPChannel: Identifiable, Hashable {
    case phone(String), email(String)

    var id: String {
        switch self { case .phone(let p): "phone:\(p)"; case .email(let e): "email:\(e)" }
    }

    var label: String {
        switch self { case .phone(let p): p; case .email(let e): e }
    }

    var isPhone: Bool { if case .phone = self { true } else { false } }
}
