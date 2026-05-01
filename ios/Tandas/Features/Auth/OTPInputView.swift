import SwiftUI

struct OTPInputView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let channel: OTPChannel

    @State private var code: String = ""
    @State private var isVerifying: Bool = false
    @State private var errorMessage: String?
    @State private var resendIn: Int = 30
    @State private var resendTimer: Task<Void, Never>?
    @State private var feedbackTrigger: Int = 0

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: Brand.Spacing.xl) {
                header
                OTPInput(code: $code, disabled: isVerifying)
                    .onChange(of: code) { _, newValue in
                        if newValue.count == 6 && !isVerifying { Task { await verify() } }
                    }
                if let errorMessage {
                    Text(errorMessage).font(.tandaCaption).foregroundStyle(.red)
                }
                resendButton
                Spacer()
            }
            .padding(.horizontal, Brand.Spacing.xl)
            .padding(.top, Brand.Spacing.xxl)
        }
        .toolbar { ToolbarItem(placement: .topBarLeading) { backButton } }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear { startResendTimer() }
        .onDisappear { resendTimer?.cancel() }
        .sensoryFeedback(.success, trigger: feedbackTrigger)
    }

    private var header: some View {
        VStack(spacing: Brand.Spacing.s) {
            Text("Escribe el código")
                .font(.tandaHero).foregroundStyle(.white)
            Text("Te lo enviamos a \(Text(channel.label).fontWeight(.semibold).foregroundStyle(.white))")
                .font(.tandaBody)
                .foregroundStyle(.white.opacity(0.7))
        }
        .multilineTextAlignment(.center)
    }

    private var resendButton: some View {
        Button {
            Task { await resend() }
        } label: {
            Text(resendIn > 0 ? "Reenviar en \(resendIn)s" : "Reenviar código")
                .font(.tandaCaption).foregroundStyle(.white.opacity(resendIn > 0 ? 0.4 : 0.85))
                .underline(resendIn == 0)
        }
        .disabled(resendIn > 0)
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text(channel.isPhone ? "Cambiar número" : "Cambiar email")
            }
            .font(.tandaBody)
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func verify() async {
        isVerifying = true
        errorMessage = nil
        defer { isVerifying = false }
        do {
            switch channel {
            case .phone(let phone):
                _ = try await app.auth.verifyPhoneOTP(phone, code: code)
            case .email(let email):
                _ = try await app.auth.verifyEmailOTP(email, code: code)
            }
            feedbackTrigger &+= 1
            // AuthGate will navigate automatically once session changes
        } catch {
            errorMessage = "Código incorrecto. Vuelve a intentarlo."
            code = ""
        }
    }

    private func resend() async {
        do {
            switch channel {
            case .phone(let p): try await app.auth.sendPhoneOTP(p)
            case .email(let e): try await app.auth.sendEmailOTP(e)
            }
            startResendTimer()
        } catch {
            errorMessage = "No se pudo reenviar. Espera un momento."
        }
    }

    private func startResendTimer() {
        resendIn = 30
        resendTimer?.cancel()
        resendTimer = Task {
            while !Task.isCancelled && resendIn > 0 {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { resendIn -= 1 }
            }
        }
    }
}
