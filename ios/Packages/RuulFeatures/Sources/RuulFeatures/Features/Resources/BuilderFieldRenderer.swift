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
                // Tier 0 audit 2026-05-12: a `.picker` without options
                // used to fall through to a free-text RuulTextField. The
                // user would type "weekly" and the wizard would accept
                // it as a valid picker selection — a UI lie. Render a
                // disabled placeholder that surfaces the catalog gap
                // instead, so the field is visibly non-configurable.
                unavailableField(
                    note: "Selector no disponible — catálogo sin opciones."
                )
            }

        case .multiPicker:
            // Tier 0: no multi-pick UI exists yet. Free-text fallback
            // produced "Juan, María" strings the backend couldn't parse
            // into a real selection. Render disabled until a real
            // multi-pick is wired (Tier 5+).
            unavailableField(
                note: "Selección múltiple no disponible — Próximamente."
            )

        case .memberPicker:
            // Tier 0: member directory picker not wired yet. Free-text
            // produced ambiguous "name or email" strings the backend
            // couldn't resolve to a group_members.id. Render disabled
            // until the picker integrates with MembersRepository.
            unavailableField(
                note: "Selector de miembros no disponible — Próximamente."
            )

        case .resourcePicker:
            // Tier 0: cross-resource picker not wired. Asking the user
            // to paste a UUID was hostile UX; render disabled until a
            // real resource browser ships.
            unavailableField(
                note: "Selector de recurso no disponible — Próximamente."
            )
        }
    }

    /// Renders a field that the catalog declares but the renderer can't
    /// honor today. Visibly disabled with a short reason — never falls
    /// through to free text. Founder framing 2026-05-12: a half-built
    /// catalog row must look half-built, not pretend to be configurable.
    @ViewBuilder
    private func unavailableField(note: String) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text(field.label)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.ruulTextTertiary)
                Text(note)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
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
                guard case let .string(raw)? = values[field.key] else {
                    return .now.addingTimeInterval(86_400)
                }
                return Self.parseDateString(raw) ?? .now.addingTimeInterval(86_400)
            },
            set: { newDate in
                values[field.key] = .string(Self.formatDate(newDate, kind: field.kind))
            }
        )
    }

    /// Serializes `date` per `kind`. `.date` writes YYYY-MM-DD (the
    /// shape the recurrence pattern validator expects); `.time` and
    /// `.dateTime` write full ISO8601 timestamp. Centralizing
    /// serialization here keeps coordinator + sheet ignorant of kind.
    static func formatDate(_ date: Date, kind: BuilderField.Kind) -> String {
        let iso = ISO8601DateFormatter()
        switch kind {
        case .date:
            iso.formatOptions = [.withFullDate]
        default:
            // .time + .dateTime + duration: full timestamp.
            iso.formatOptions = [.withInternetDateTime]
        }
        return iso.string(from: date)
    }

    /// Parses either YYYY-MM-DD (date-only) or a full ISO8601 timestamp.
    /// Returns nil when neither shape matches so the caller can fall
    /// back to a default.
    static func parseDateString(_ raw: String) -> Date? {
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let d = dateOnly.date(from: raw) { return d }
        let full = ISO8601DateFormatter()
        if let d = full.date(from: raw) { return d }
        return nil
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
