import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct ChangeEmailFlow: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .enterEmail
    @State private var newEmail = ""
    @State private var otp = ""
    @State private var sending = false
    @State private var error: String?

    private enum Step { case enterEmail, enterOTP }

    public init() {}

    public var body: some View {
        NavigationStack {
            switch step {
            case .enterEmail: enterEmailStep
            case .enterOTP:   enterOTPStep
            }
        }
    }

    private var enterEmailStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Tu nuevo correo")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            TextField("nombre@dominio.com", text: $newEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            if let error {
                Text(error).ruulTextStyle(RuulTypography.footnote).foregroundStyle(Color.ruulNegative)
            }
            Spacer()
            Button("Enviar código") { Task { await sendOTP() } }
                .buttonStyle(.borderedProminent)
                .disabled(sending || newEmail.isEmpty)
        }
        .padding(RuulSpacing.lg)
        .ruulSheetToolbar("Cambiar correo")
    }

    private var enterOTPStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Código enviado a \(newEmail)")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            TextField("000000", text: $otp)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            if let error {
                Text(error).ruulTextStyle(RuulTypography.footnote).foregroundStyle(Color.ruulNegative)
            }
            Spacer()
            Button("Confirmar") { Task { await confirm() } }
                .buttonStyle(.borderedProminent)
                .disabled(sending || otp.count < 4)
        }
        .padding(RuulSpacing.lg)
        .navigationTitle("Verificar código")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendOTP() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await app.auth.startEmailChange(newEmail)
            step = .enterOTP
        } catch {
            self.error = "No pudimos enviar el código. Verifica el correo."
        }
    }

    private func confirm() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await app.auth.confirmEmailChange(otp: otp, newEmail: newEmail)
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "Código inválido."
        }
    }
}
