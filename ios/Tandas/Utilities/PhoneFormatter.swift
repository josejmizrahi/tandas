import Foundation

/// Tiny phone helpers — full E.164 validation lives in the country picker.
enum PhoneFormatter {
    /// Normalize a raw user-typed string into digits-only.
    static func digitsOnly(_ input: String) -> String {
        input.filter(\.isNumber)
    }

    /// Build an E.164 string from a country dial code + raw input.
    static func e164(dialCode: String, rawInput: String) -> String? {
        let digits = digitsOnly(rawInput)
        guard !digits.isEmpty else { return nil }
        return "+\(dialCode)\(digits)"
    }

    /// Smart: if raw starts with `+`, treat as E.164 as-is. Else assume MX.
    static func smartE164(_ raw: String, defaultDialCode: String = "52") -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("+") {
            let digits = digitsOnly(trimmed)
            guard !digits.isEmpty else { return nil }
            return "+\(digits)"
        }
        let digits = digitsOnly(trimmed)
        guard !digits.isEmpty else { return nil }
        return "+\(defaultDialCode)\(digits)"
    }

    /// Display-friendly local format. Doesn't aim to be perfect; just adds
    /// readable spaces. For real i18n display use libphonenumber.
    static func displayFormat(_ e164: String) -> String {
        guard e164.hasPrefix("+") else { return e164 }
        let digits = digitsOnly(e164)
        guard digits.count >= 10 else { return e164 }
        // Group as +DD ... XXX XXX XXXX (last 10 digits as area + line)
        let last10 = String(digits.suffix(10))
        let dial = String(digits.dropLast(10))
        let a = String(last10.prefix(3))
        let b = String(last10.dropFirst(3).prefix(3))
        let c = String(last10.suffix(4))
        return "+\(dial) \(a) \(b) \(c)"
    }
}
