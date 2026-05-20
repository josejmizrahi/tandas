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
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
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
                .font(.footnote)
                .foregroundStyle(Color.secondary)
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
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                TextEditor(text: stringBinding())
                    .frame(minHeight: 80)
                    .padding(RuulSpacing.sm)
                    .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.medium)
                            .stroke(Color(.separator), lineWidth: 1)
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
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    if let helpText = field.helpText {
                        Text(helpText)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: boolBinding())
                    .labelsHidden()
                    .tint(Color.ruulAccent)
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium)
                    .stroke(Color(.separator), lineWidth: 1)
            )

        case .date, .time, .dateTime:
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text(field.label)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
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
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
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
            // Tier 5 (2026-05-13): `participants` in the rotation
            // capability is a real member multi-picker sourced from the
            // active group. Output is an ordered JSONConfig.array of
            // user_id strings — order matters because next_host_for_series
            // walks `participants[(cycle - 1) % count]` when
            // order=sequential. Any other multiPicker key still falls
            // through to the disabled placeholder until its renderer
            // path lands.
            if field.key == "participants" {
                MemberMultiPickerField(
                    label: field.label,
                    helpText: field.helpText,
                    binding: jsonArrayBinding()
                )
            } else {
                unavailableField(
                    note: "Selección múltiple no disponible — Próximamente."
                )
            }

        case .memberPicker:
            // Slice 8 (mig 00201 follow-up): wires the picker against
            // `AppState.groupsRepo.membersWithProfiles`. Output is the
            // selected member's `group_members.id` (NOT user_id) as a
            // JSONConfig.string — matches what create_right /
            // transfer_right and the other lifecycle RPCs gate on.
            MemberPickerField(
                label: field.label,
                helpText: field.helpText,
                binding: jsonValueBinding()
            )

        case .resourcePicker:
            // Slice 9: wires the picker against ResourceRepository.list
            // for the active group. Type filtering deferred until
            // BuilderField carries a `validResourceTypes` hint — current
            // consumers (SlotResourceBuilder.assetId, RightResourceBuilder
            // .targetResourceId) work fine with the flat list at typical
            // group sizes.
            ResourcePickerField(
                label: field.label,
                helpText: field.helpText,
                binding: jsonValueBinding()
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
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Color(.tertiaryLabel))
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
                Spacer(minLength: 0)
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
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

    /// Parses either a full ISO8601 timestamp (with time) or a date-only
    /// `YYYY-MM-DD` string. Returns nil when neither shape matches so the
    /// caller can fall back to a default.
    ///
    /// Order matters: full ISO datetimes must be tried FIRST. iOS's
    /// `ISO8601DateFormatter` with `[.withFullDate]` permissively accepts
    /// strings that include a time component, but silently truncates the
    /// time to midnight UTC. For a Mexico (UTC-6) user picking 7 PM local,
    /// formatDate writes `…T01:00:00Z` (UTC). If date-only parsing went
    /// first and matched, the result would be midnight UTC = 6 PM local
    /// the previous day. The DatePicker binding would re-read that value
    /// and snap back to 6 PM — the user's symptom: "no me deja escoger
    /// después de las 6 pm".
    ///
    /// The "contains T" guard short-circuits the formatter ambiguity: a
    /// string with `T` is unambiguously a full timestamp, never a
    /// date-only value.
    static func parseDateString(_ raw: String) -> Date? {
        if raw.contains("T") || raw.contains(":") {
            let full = ISO8601DateFormatter()
            if let d = full.date(from: raw) { return d }
        }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let d = dateOnly.date(from: raw) { return d }
        // Final fallback: try the full parser even when no T/: hint
        // (defensive against future serializer changes).
        let full = ISO8601DateFormatter()
        return full.date(from: raw)
    }

    /// Binds the field's raw JSONConfig value (nil-able). Used by
    /// sub-views (e.g. MemberPickerField) that prefer to own the
    /// JSONConfig shape themselves — they read/write the whole value
    /// instead of going through a typed accessor. Removing the key
    /// when value is nil keeps `values` clean for the wizard's
    /// validation path (`isFieldFilled` treats absent keys as empty).
    private func jsonValueBinding() -> Binding<JSONConfig?> {
        Binding(
            get: { values[field.key] },
            set: { newValue in
                if let v = newValue {
                    values[field.key] = v
                } else {
                    values.removeValue(forKey: field.key)
                }
            }
        )
    }

    /// Binds the field's JSONConfig value as a `[String]` of user_ids
    /// (or other primitive ids). Storage shape: `JSONConfig.array(
    /// .string("…"), .string("…"), …)`. `set` rewrites the whole
    /// array each time; the caller is responsible for de-duplication
    /// and ordering (the picker sub-view enforces both).
    private func jsonArrayBinding() -> Binding<[String]> {
        Binding(
            get: {
                guard case let .array(items)? = values[field.key] else { return [] }
                return items.compactMap { item in
                    if case let .string(s) = item { return s }
                    return nil
                }
            },
            set: { newList in
                values[field.key] = .array(newList.map { .string($0) })
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
