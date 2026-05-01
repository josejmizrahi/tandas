import SwiftUI

struct OTPInput: View {
    @Binding var code: String
    @FocusState private var isFocused: Bool
    var disabled: Bool = false

    var body: some View {
        ZStack {
            HStack(spacing: Brand.Spacing.s) {
                ForEach(0..<6, id: \.self) { index in
                    OTPSlot(char: char(at: index), focused: isFocused && index == code.count)
                }
            }
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.001)
                .frame(width: 1, height: 1)
                .onChange(of: code) { _, newValue in
                    let filtered = String(newValue.prefix(6).filter(\.isNumber))
                    if filtered != newValue { code = filtered }
                }
                .disabled(disabled)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
    }

    private func char(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }
}

private struct OTPSlot: View {
    let char: String
    let focused: Bool
    var body: some View {
        ZStack {
            Text(char.isEmpty ? " " : char)
                .font(.tandaAmount)
                .foregroundStyle(.white)
        }
        .frame(width: 46, height: 56)
        .adaptiveGlass(RoundedRectangle(cornerRadius: Brand.Radius.field), tint: focused ? Brand.accent.opacity(0.4) : nil)
    }
}
