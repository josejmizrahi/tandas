import SwiftUI

struct InvitedVerifyView: View {
    @Environment(InvitedOnboardingCoordinator.self) private var coord
    @State private var phoneInput: String = ""

    var body: some View {
        OnboardingScreenTemplate(
            mesh: .aqua,
            progress: progressValue,
            stepCount: InvitedStep.allCases.count,
            title: "Confirma tu número",
            subtitle: "Para mandarte recordatorios y multas si aplica.",
            primaryCTA: ("Enviar código", coord.isLoading, sendCode),
            canContinue: !phoneInput.trimmingCharacters(in: .whitespaces).isEmpty
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s4) {
                RuulPhoneField(
                    text: $phoneInput,
                    label: "Tu número",
                    error: errorMessage
                )
                Text("Te llamamos primero por WhatsApp. Si no llega, te mandamos un SMS.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }

    private var progressValue: Double {
        Double(InvitedStep.phoneVerify.index) / Double(InvitedStep.allCases.count - 1)
    }

    private var errorMessage: String? {
        if case .otpSendFailed = coord.error { return coord.error?.localizedDescription }
        return nil
    }

    private func sendCode() {
        guard let e164 = PhoneFormatter.smartE164(phoneInput) else { return }
        coord.phoneE164 = e164
        Task { await coord.advanceFromPhoneVerify() }
    }
}
