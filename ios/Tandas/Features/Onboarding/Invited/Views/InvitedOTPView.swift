import SwiftUI

struct InvitedOTPView: View {
    @Environment(InvitedOnboardingCoordinator.self) private var coord
    @State private var code = ""
    @State private var hasError = false
    @State private var resendCountdown = 30
    private let resendTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        OnboardingScreenTemplate(
            mesh: .aqua,
            progress: progressValue,
            stepCount: InvitedStep.allCases.count,
            title: titleForChannel,
            subtitle: "Llega a \(PhoneFormatter.displayFormat(coord.phoneE164)). Pégalo aquí.",
            primaryCTA: ("Confirmar", coord.isLoading, submit),
            canContinue: code.count == 6
        ) {
            VStack(spacing: RuulSpacing.s5) {
                RuulOTPInput(code: $code, hasError: $hasError) { fullCode in
                    Task {
                        await coord.submitOTP(code: fullCode)
                        hasError = (coord.error != nil)
                    }
                }
                resendButton
                if let err = coord.error,
                   case .otpVerifyFailed(_, let attempts) = err,
                   attempts < 3 {
                    Text("Código incorrecto. Te quedan \(3 - attempts) intentos.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulSemanticError)
                }
                if coord.error == .otpTooManyAttempts {
                    Text("Demasiados intentos. Pide otro código.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulSemanticError)
                }
            }
        }
        .onReceive(resendTimer) { _ in
            if resendCountdown > 0 { resendCountdown -= 1 }
        }
    }

    private var progressValue: Double {
        Double(InvitedStep.otp.index) / Double(InvitedStep.allCases.count - 1)
    }

    private var titleForChannel: String {
        coord.otpChannel == .whatsapp ? "Te mandamos un código por WhatsApp" : "Te mandamos un SMS"
    }

    private var resendButton: some View {
        Button {
            resendCountdown = 30
            code = ""
            hasError = false
            coord.resetOTPAttempts()
            Task { await coord.advanceFromPhoneVerify() }
        } label: {
            Text(resendCountdown > 0 ? "Reenviar (\(resendCountdown)s)" : "Reenviar código")
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(resendCountdown > 0 ? Color.ruulTextTertiary : Color.ruulAccentPrimary)
        }
        .disabled(resendCountdown > 0)
        .buttonStyle(.plain)
    }

    private func submit() {
        guard code.count == 6 else { return }
        Task {
            await coord.submitOTP(code: code)
            hasError = (coord.error != nil)
        }
    }
}
