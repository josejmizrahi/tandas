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
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            if let label {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
            HStack(spacing: RuulSpacing.xs) {
                if style == .search {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                input
                    .focused($isFocused)
                    .disabled(isDisabled)
                    .foregroundStyle(Color.primary)
                if style == .password {
                    Button { isPasswordVisible.toggle() } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.md)
            // Soft glass-style fill: barely visible at rest, no border.
            // Picks up whatever ambient/material the parent surface is
            // showing through (Luma / Cerebras-meetup pattern). Focus
            // and error states surface a 1.5pt accent / negative ring
            // so the field still telegraphs interactive affordance.
            .background(
                Color(.tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
            )
            .overlay(focusRing)
            .animation(.smooth, value: isFocused)
            .animation(.smooth, value: error)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            } else if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
    }

    @ViewBuilder
    private var input: some View {
        switch style {
        case .standard:
            TextField(placeholder, text: $text)
                .font(.subheadline)
        case .email:
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.emailAddress)
        case .phone:
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
        case .numeric:
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .keyboardType(.numberPad)
        case .search:
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .password:
            if isPasswordVisible {
                TextField(placeholder, text: $text)
                    .font(.subheadline)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField(placeholder, text: $text)
                    .font(.subheadline)
                    .textContentType(.password)
            }
        }
    }

    /// Only renders a ring on focus or error so the field stays
    /// glass-quiet at rest. Resting state has no border — definition
    /// comes from the soft fill + corner radius alone.
    @ViewBuilder
    private var focusRing: some View {
        let shape = RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
        if error != nil {
            shape.stroke(Color.red, lineWidth: 1.5)
        } else if isFocused {
            shape.stroke(Color.ruulAccent, lineWidth: 1.5)
        }
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
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                RuulTextField("Tu nombre", text: $name, label: "Nombre", description: "Visible para tu grupo.")
                RuulTextField("tu@email.com", text: $email, label: "Email", style: .email, error: email.contains("@") && email.contains(".") ? nil : "Email inválido")
                RuulTextField("+5215555551234", text: $phone, label: "Teléfono", style: .phone)
                RuulTextField("Buscar grupos", text: $search, style: .search)
                RuulTextField("Contraseña", text: $password, label: "Password", style: .password)
                RuulTextField("Disabled", text: .constant("read only"), label: "Disabled", isDisabled: true)
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground)
    }
}

#Preview("RuulTextField") {
    RuulTextFieldPreview()
}
#endif
