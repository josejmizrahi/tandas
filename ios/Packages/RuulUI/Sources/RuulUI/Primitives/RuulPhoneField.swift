import SwiftUI

/// Phone field with a country/dial-code picker and E.164 normalization.
///
/// The text binding contains the raw user-typed digits. The dial-code is held
/// internally and exposed via `e164` (read-only computed). Use that for
/// network calls; use `text` for what the user is typing.
public struct RuulPhoneField: View {
    @Binding private var text: String
    @State private var country: RuulCountry
    @FocusState private var isFocused: Bool

    private let label: String?
    private let error: String?

    public init(text: Binding<String>, defaultCountry: RuulCountry = .mexico, label: String? = nil, error: String? = nil) {
        self._text = text
        self._country = State(initialValue: defaultCountry)
        self.label = label
        self.error = error
    }

    /// E.164 representation: `+<dial><digits>`. Returns nil if `text` is empty.
    public var e164: String? {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return "+\(country.dialCode)\(digits)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            if let label {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
            HStack(spacing: RuulSpacing.xs) {
                countryButton
                Divider().frame(height: 22)
                TextField("Tu número", text: $text)
                    .font(.subheadline)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($isFocused)
                    .foregroundStyle(Color.primary)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.md)
            .background(
                Color(.tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
            )
            .overlay(focusRing)
            .animation(.smooth, value: isFocused)
            .animation(.smooth, value: error)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }

    private var countryButton: some View {
        Menu {
            ForEach(RuulCountry.popular) { c in
                Button {
                    country = c
                } label: {
                    Label("\(c.flag) \(c.name) +\(c.dialCode)", systemImage: country.id == c.id ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(country.flag).font(.system(size: 18))
                Text("+\(country.dialCode)")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
    }

    /// Same focus-or-error-only ring treatment as RuulTextField — the
    /// resting state is glass-quiet so inputs inside a sheet pick up
    /// whatever ambient/material the parent is showing through.
    @ViewBuilder
    private var focusRing: some View {
        let shape = RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
        if error != nil {
            shape.stroke(Color.red, lineWidth: 1.5)
        } else if isFocused {
            shape.stroke(Color.ruulAccent, lineWidth: 1.5)
        }
    }
}

public struct RuulCountry: Identifiable, Sendable, Hashable {
    public let id: String     // ISO 3166-1 alpha-2
    public let name: String
    public let dialCode: String
    public let flag: String

    public static let mexico    = RuulCountry(id: "MX", name: "México",        dialCode: "52", flag: "🇲🇽")
    public static let usa       = RuulCountry(id: "US", name: "United States", dialCode: "1",  flag: "🇺🇸")
    public static let argentina = RuulCountry(id: "AR", name: "Argentina",     dialCode: "54", flag: "🇦🇷")
    public static let colombia  = RuulCountry(id: "CO", name: "Colombia",      dialCode: "57", flag: "🇨🇴")
    public static let chile     = RuulCountry(id: "CL", name: "Chile",         dialCode: "56", flag: "🇨🇱")
    public static let peru      = RuulCountry(id: "PE", name: "Perú",          dialCode: "51", flag: "🇵🇪")
    public static let spain     = RuulCountry(id: "ES", name: "España",        dialCode: "34", flag: "🇪🇸")
    public static let brazil    = RuulCountry(id: "BR", name: "Brasil",        dialCode: "55", flag: "🇧🇷")
    public static let israel    = RuulCountry(id: "IL", name: "Israel",        dialCode: "972", flag: "🇮🇱")

    public static let popular: [RuulCountry] = [.mexico, .usa, .argentina, .colombia, .chile, .peru, .spain, .brazil, .israel]
}

#if DEBUG
private struct RuulPhoneFieldPreview: View {
    @State var phone = ""
    @State var withError = "555"

    var body: some View {
        VStack(spacing: RuulSpacing.md) {
            RuulPhoneField(text: $phone, label: "Tu número")
            Text(verbatim: "E.164: \(RuulPhoneField(text: .constant(phone)).e164 ?? "—")")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            RuulPhoneField(text: $withError, defaultCountry: .usa, label: "Con error", error: "Número muy corto")
        }
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
    }
}

#Preview("RuulPhoneField") {
    RuulPhoneFieldPreview()
}
#endif
