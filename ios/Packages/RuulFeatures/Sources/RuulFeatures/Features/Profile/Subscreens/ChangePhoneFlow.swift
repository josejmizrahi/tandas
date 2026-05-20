import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct ChangePhoneFlow: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .enterPhone
    @State private var newPhone = ""
    @State private var otp = ""
    @State private var sending = false
    @State private var error: String?

    private enum Step { case enterPhone, enterOTP }

    public init() {}

    public var body: some View {
        NavigationStack {
            switch step {
            case .enterPhone: enterPhoneStep
            case .enterOTP:   enterOTPStep
            }
        }
    }

    private var enterPhoneStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Tu nuevo número")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            TextField("+52 55 1234 5678", text: $newPhone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            if let error { errorLabel(error) }
            Spacer()
            Button("Enviar código") { Task { await sendOTP() } }
                .buttonStyle(.borderedProminent)
                .disabled(sending || newPhone.isEmpty)
        }
        .padding(RuulSpacing.lg)
        .ruulSheetToolbar("Cambiar teléfono")
    }

    private var enterOTPStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Código enviado a \(newPhone)")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            TextField("000000", text: $otp)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            if let error { errorLabel(error) }
            Spacer()
            Button("Confirmar") { Task { await confirm() } }
                .buttonStyle(.borderedProminent)
                .disabled(sending || otp.count < 4)
        }
        .padding(RuulSpacing.lg)
        .navigationTitle("Verificar código")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func errorLabel(_ msg: String) -> some View {
        Text(msg)
            .font(.footnote)
            .foregroundStyle(Color.red)
    }

    private func sendOTP() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await app.auth.startPhoneChange(newPhone)
            step = .enterOTP
        } catch {
            self.error = "No pudimos enviar el código. Verifica el número."
        }
    }

    private func confirm() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await app.auth.confirmPhoneChange(otp: otp, newPhone: newPhone)
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "Código inválido."
        }
    }
}
