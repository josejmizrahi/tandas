import SwiftUI

/// Text-field primitive with optional label, description, error, and icon.
public struct RuulTextField: View {
    public enum Style: Sendable, Hashable {
        case standard
        case email
        case phone
        case numeric
        case search
        case password
    }

    private let placeholder: String
    private let label: String?
    private let description: String?
    @Binding private var text: String
    private let style: Style
    private let error: String?
    private let isDisabled: Bool

    @FocusState private var isFocused: Bool
    @State private var isPasswordVisible = false

    public init(
        _ placeholder: String,
        text: Binding<String>,
        label: String? = nil,
        description: String? = nil,
        style: Style = .standard,
        error: String? = nil,
        isDisabled: Bool = false
    ) {
        self.placeholder = placeholder
        self._text = text
        self.label = label
        self.description = description
        self.style = style
        self.error = error
        self.isDisabled = isDisabled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            if let label {
                Text(label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            HStack(spacing: RuulSpacing.s2) {
                if style == .search {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                input
                    .focused($isFocused)
                    .disabled(isDisabled)
                    .foregroundStyle(Color.ruulTextPrimary)
                if style == .password {
                    Button { isPasswordVisible.toggle() } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
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
            } else if let description {
                Text(description)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
    }

    @ViewBuilder
    private var input: some View {
        switch style {
        case .standard:
            TextField(placeholder, text: $text)
                .ruulTextStyle(RuulTypography.body)
        case .email:
            TextField(placeholder, text: $text)
                .ruulTextStyle(RuulTypography.body)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.emailAddress)
        case .phone:
            TextField(placeholder, text: $text)
                .ruulTextStyle(RuulTypography.body)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
        case .numeric:
            TextField(placeholder, text: $text)
                .ruulTextStyle(RuulTypography.body)
                .keyboardType(.numberPad)
        case .search:
            TextField(placeholder, text: $text)
                .ruulTextStyle(RuulTypography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .password:
            if isPasswordVisible {
                TextField(placeholder, text: $text)
                    .ruulTextStyle(RuulTypography.body)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField(placeholder, text: $text)
                    .ruulTextStyle(RuulTypography.body)
                    .textContentType(.password)
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

#if DEBUG
private struct RuulTextFieldPreview: View {
    @State var name = ""
    @State var email = "jose@"
    @State var phone = ""
    @State var search = ""
    @State var password = "secret"
    @State var withError = "x"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                RuulTextField("Tu nombre", text: $name, label: "Nombre", description: "Visible para tu grupo.")
                RuulTextField("tu@email.com", text: $email, label: "Email", style: .email, error: email.contains("@") && email.contains(".") ? nil : "Email inválido")
                RuulTextField("+5215555551234", text: $phone, label: "Teléfono", style: .phone)
                RuulTextField("Buscar grupos", text: $search, style: .search)
                RuulTextField("Contraseña", text: $password, label: "Password", style: .password)
                RuulTextField("Disabled", text: .constant("read only"), label: "Disabled", isDisabled: true)
            }
            .padding(RuulSpacing.s5)
        }
        .background(Color.ruulBackgroundCanvas)
    }
}

#Preview("RuulTextField") {
    RuulTextFieldPreview()
}
#endif
