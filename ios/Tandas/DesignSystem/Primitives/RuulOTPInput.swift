import SwiftUI

/// 6-box OTP input with paste support, auto-fill from SMS, and shake-on-error.
public struct RuulOTPInput: View {
    @Binding private var code: String
    private let length: Int
    private let onComplete: ((String) -> Void)?
    @Binding private var hasError: Bool

    @FocusState private var isFocused: Bool
    @State private var shakeOffset: CGFloat = 0

    public init(
        code: Binding<String>,
        length: Int = 6,
        hasError: Binding<Bool> = .constant(false),
        onComplete: ((String) -> Void)? = nil
    ) {
        self._code = code
        self.length = length
        self._hasError = hasError
        self.onComplete = onComplete
    }

    public var body: some View {
        ZStack {
            HStack(spacing: RuulSpacing.s2) {
                ForEach(0..<length, id: \.self) { index in
                    OTPSlot(
                        char: char(at: index),
                        isFocused: isFocused && index == code.count,
                        hasError: hasError
                    )
                }
            }
            .offset(x: shakeOffset)

            // Hidden text field captures actual input.
            TextField("", text: Binding(
                get: { code },
                set: { newValue in
                    let cleaned = String(newValue.prefix(length).filter(\.isNumber))
                    code = cleaned
                    if cleaned.count == length {
                        onComplete?(cleaned)
                    }
                }
            ))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.001)
                .frame(width: 1, height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
        .onChange(of: hasError) { _, newValue in
            if newValue { triggerShake() }
        }
    }

    private func handleChange(_ raw: String) {
        let cleaned = String(raw.prefix(length).filter(\.isNumber))
        code = cleaned
        if cleaned.count == length {
            onComplete?(cleaned)
        }
    }

    private func char(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }

    private func triggerShake() {
        let amplitudes: [CGFloat] = [-12, 12, -8, 8, -4, 4, 0]
        for (i, amp) in amplitudes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                withAnimation(.spring(response: 0.12, dampingFraction: 0.55)) {
                    shakeOffset = amp
                }
            }
        }
    }
}

private struct OTPSlot: View {
    let char: String
    let isFocused: Bool
    let hasError: Bool

    var body: some View {
        ZStack {
            Text(char.isEmpty ? " " : char)
                .ruulTextStyle(RuulTypography.monoLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .scaleEffect(char.isEmpty ? 0.85 : 1.0)
                .opacity(char.isEmpty ? 0 : 1)
                .animation(.ruulSnappy, value: char)
        }
        .frame(width: 46, height: 56)
        .ruulGlass(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous),
            material: .regular,
            tint: tintColor,
            interactive: false
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(strokeColor, lineWidth: 1.5)
        )
        .animation(.ruulSnappy, value: isFocused)
        .animation(.ruulSnappy, value: hasError)
    }

    private var tintColor: Color? {
        if hasError { return Color.ruulSemanticError.opacity(0.25) }
        if isFocused { return Color.ruulAccentPrimary.opacity(0.20) }
        return nil
    }

    private var strokeColor: Color {
        if hasError { return .ruulSemanticError }
        if isFocused { return .ruulAccentPrimary }
        return .ruulBorderSubtle
    }
}

#if DEBUG
private struct RuulOTPInputPreview: View {
    @State var code = ""
    @State var hasError = false

    var body: some View {
        VStack(spacing: RuulSpacing.s7) {
            Spacer()
            Text("Código de verificación").ruulTextStyle(RuulTypography.headline)
            RuulOTPInput(code: $code, hasError: $hasError) { _ in
                hasError.toggle()
            }
            RuulButton("Trigger error") { hasError = true }
            Spacer()
        }
        .padding(RuulSpacing.s5)
        .background(Color.ruulBackgroundCanvas)
    }
}

#Preview("RuulOTPInput") {
    RuulOTPInputPreview()
}
#endif
