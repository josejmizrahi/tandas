import SwiftUI
import RuulUI
import RuulCore

/// Dynamic SwiftUI renderer for a `BuilderField`. The engine that makes
/// every `ResourceBuilder`'s wizard step feel consistent — text + date +
/// picker controls all look the same regardless of which resource type
/// the user is creating.
///
/// Stores its value in the shared `[String: JSONConfig]` keyed by
/// `field.key` so the parent wizard can submit it to `ResourceBuilder.build`
/// without per-field plumbing.
public struct BuilderFieldRenderer: View {
    public let field: BuilderField
    @Binding public var values: [String: JSONConfig]

    public init(field: BuilderField, values: Binding<[String: JSONConfig]>) {
        self.field = field
        self._values = values
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            controlView
            if let helpText = field.helpText {
                Text(helpText)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .padding(.leading, RuulSpacing.xxs)
            }
        }
    }

    @ViewBuilder
    private func pickerView(options: [BuilderField.PickerOption]) -> some View {
        // Render as a segmented control when there are 2-4 options
        // (matches the recurrence frequency + dayOfWeek UX); otherwise
        // a menu/dropdown. The renderer uses option `value`'s JSONConfig
        // identity so int/string/bool options round-trip without
        // stringification.
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(field.label)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            if options.count <= 7 {
                Picker(field.label, selection: pickerBinding(options: options)) {
                    ForEach(options.indices, id: \.self) { i in
                        Text(options[i].label).tag(i)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Picker(field.label, selection: pickerBinding(options: options)) {
                    ForEach(options.indices, id: \.self) { i in
                        Text(options[i].label).tag(i)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    private var controlView: some View {
        switch field.kind {
        case .text:
            RuulTextField(
                field.placeholder ?? field.label,
                text: stringBinding(),
                label: field.label
            )

        case .multilineText:
            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                Text(field.label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                TextEditor(text: stringBinding())
                    .frame(minHeight: 80)
                    .padding(RuulSpacing.sm)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.medium)
                            .stroke(Color.ruulSeparator, lineWidth: 1)
                    )
            }

        case .integer, .decimal, .currency, .money:
            RuulTextField(
                field.placeholder ?? "0",
                text: stringBinding(),
                label: field.label
            )
            // Numeric keyboard hint — fine-tune per kind if needed.

        case .boolean:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if let helpText = field.helpText {
                        Text(helpText)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                Spacer()
                Toggle("", isOn: boolBinding())
                    .labelsHidden()
                    .tint(Color.ruulAccent)
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )

        case .date, .time, .dateTime:
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text(field.label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                DatePicker(
                    "",
                    selection: dateBinding(),
                    displayedComponents: dateComponents
                )
                .labelsHidden()
                .datePickerStyle(.compact)
            }

        case .duration:
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text(field.label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                RuulTextField(
                    "minutos",
                    text: stringBinding(),
                    label: nil
                )
            }

        case .picker:
            if let options = field.options, !options.isEmpty {
                pickerView(options: options)
            } else {
                // Pre-X2 fallback: catalog row without options renders
                // as a free-text field so the wizard stays usable.
                RuulTextField(
                    field.placeholder ?? field.label,
                    text: stringBinding(),
                    label: field.label
                )
            }

        case .multiPicker:
            RuulTextField(
                field.placeholder ?? field.label,
                text: stringBinding(),
                label: field.label
            )

        case .memberPicker:
            // Phase 2 will integrate the member directory. For now allow
            // free-text fallback so the wizard remains usable.
            RuulTextField(
                field.placeholder ?? "Nombre o email",
                text: stringBinding(),
                label: field.label
            )

        case .resourcePicker:
            RuulTextField(
                field.placeholder ?? "Pega el id del recurso",
                text: stringBinding(),
                label: field.label
            )
        }
    }

    // MARK: - Bindings

    private func stringBinding() -> Binding<String> {
        Binding(
            get: {
                if case let .string(s)? = values[field.key] { return s }
                if case let .int(i)? = values[field.key]    { return String(i) }
                if case let .double(d)? = values[field.key] { return String(d) }
                return ""
            },
            set: { values[field.key] = .string($0) }
        )
    }

    private func boolBinding() -> Binding<Bool> {
        Binding(
            get: {
                if case let .bool(b)? = values[field.key] { return b }
                return false
            },
            set: { values[field.key] = .bool($0) }
        )
    }

    private func dateBinding() -> Binding<Date> {
        Binding(
            get: {
                if case let .string(raw)? = values[field.key],
                   let date = ISO8601DateFormatter().date(from: raw) {
                    return date
                }
                return .now.addingTimeInterval(86_400)
            },
            set: { newDate in
                values[field.key] = .string(ISO8601DateFormatter().string(from: newDate))
            }
        )
    }

    /// Binds the field's current JSONConfig value to an option index in
    /// the provided array. The index round-trip is what gives SwiftUI
    /// stable Hashable tags while keeping the underlying `values`
    /// dictionary in its canonical JSONConfig shape.
    private func pickerBinding(options: [BuilderField.PickerOption]) -> Binding<Int> {
        Binding(
            get: {
                if let current = values[field.key],
                   let idx = options.firstIndex(where: { $0.value == current }) {
                    return idx
                }
                return 0  // First option is the implicit default.
            },
            set: { newIdx in
                guard options.indices.contains(newIdx) else { return }
                values[field.key] = options[newIdx].value
            }
        )
    }

    private var dateComponents: DatePickerComponents {
        switch field.kind {
        case .date:     return [.date]
        case .time:     return [.hourAndMinute]
        case .dateTime: return [.date, .hourAndMinute]
        default:        return [.date, .hourAndMinute]
        }
    }
}
