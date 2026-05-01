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
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Brand.Surface.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Brand.Layout.sectionGap) {
                Spacer().frame(height: 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Escribe el código")
                        .font(Brand.Typography.heroTitle)
                        .foregroundStyle(Brand.Surface.textPrimary)
                    Text("Lo enviamos a \(channel.label).")
                        .font(Brand.Typography.body)
                        .foregroundStyle(Brand.Surface.textSecondary)
                }

                otpRow

                if let errorMessage {
                    Text(errorMessage)
                        .font(Brand.Typography.caption)
                        .foregroundStyle(.red)
                }

                resendButton

                Spacer()
            }
            .padding(.horizontal, Brand.Layout.pagePadH)
            .padding(.bottom, 32)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.Surface.textPrimary)
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Brand.Surface.canvas, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            startResendTimer()
            isFocused = true
        }
        .onDisappear { resendTimer?.cancel() }
        .sensoryFeedback(.success, trigger: feedbackTrigger)
    }

    private var otpRow: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    OTPSlot(char: char(at: i), isFocused: isFocused && i == code.count)
                }
            }
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.001)
                .frame(width: 1, height: 1)
                .onChange(of: code) { _, newValue in
                    let cleaned = String(newValue.prefix(6).filter(\.isNumber))
                    if cleaned != newValue { code = cleaned }
                    if cleaned.count == 6 && !isVerifying {
                        Task { await verify() }
                    }
                }
                .disabled(isVerifying)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private var resendButton: some View {
        Button {
            Task { await resend() }
        } label: {
            Text(resendIn > 0 ? "Reenviar en \(resendIn)s" : "Reenviar código")
                .font(Brand.Typography.captionEmph)
                .foregroundStyle(resendIn > 0 ? Brand.Surface.textTertiary : Brand.accent)
        }
        .disabled(resendIn > 0)
    }

    private func char(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
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

private struct OTPSlot: View {
    let char: String
    let isFocused: Bool

    var body: some View {
        Text(char.isEmpty ? " " : char)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .foregroundStyle(Brand.Surface.textPrimary)
            .frame(width: 46, height: 56)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                    .fill(Brand.Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                    .stroke(isFocused ? Brand.accent : Brand.Surface.border, lineWidth: isFocused ? 1.5 : 1)
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: char)
    }
}
