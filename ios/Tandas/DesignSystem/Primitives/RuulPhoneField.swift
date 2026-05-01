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
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            if let label {
                Text(label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            HStack(spacing: RuulSpacing.s2) {
                countryButton
                Divider().frame(height: 22)
                TextField("Tu número", text: $text)
                    .ruulTextStyle(RuulTypography.body)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($isFocused)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            .padding(.horizontal, RuulSpacing.s4)
            .padding(.vertical, RuulSpacing.s3)
            .background(Color.ruulBackgroundRecessed, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .animation(.ruulSnappy, value: isFocused)
            .animation(.ruulSnappy, value: error)

            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulSemanticError)
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
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
    }

    private var borderColor: Color {
        if error != nil { return .ruulSemanticError }
        if isFocused    { return .ruulAccentPrimary }
        return .ruulBorderSubtle
    }

    private var borderWidth: CGFloat {
        (error != nil || isFocused) ? 1.5 : 1.0
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
        VStack(spacing: RuulSpacing.s4) {
            RuulPhoneField(text: $phone, label: "Tu número")
            Text(verbatim: "E.164: \(RuulPhoneField(text: .constant(phone)).e164 ?? "—")")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
            RuulPhoneField(text: $withError, defaultCountry: .usa, label: "Con error", error: "Número muy corto")
        }
        .padding(RuulSpacing.s5)
        .background(Color.ruulBackgroundCanvas)
    }
}

#Preview("RuulPhoneField") {
    RuulPhoneFieldPreview()
}
#endif
