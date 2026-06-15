import SwiftUI
import RuulCore

/// R.12.C — Form engine reusable que consume `FormSchema` (FormFieldSpec[])
/// y emite values en jsonb-compatible `[String: JSONValue]`.
///
/// A diferencia de `ResourceActionFormView` (que es self-contained: stores +
/// submit pipeline + actor_ref/resource_ref pickers), `DynamicForm` solo
/// renderea los controls básicos como rows de un `Form`/`List`. El caller
/// mantiene el `values` binding y decide qué hacer al submit.
///
/// Field types soportadas en MVP de resource metadata (no incluye actor_ref/
/// resource_ref — esos están reservados para action forms con contexto cargado):
///   text · multiline · number · currency · date · datetime · boolean · picker
///   · file_url
///
/// actor_ref / resource_ref caen a TextField defensivo (no aplica al schema
/// de metadata estático del subtype).
public struct DynamicForm: View {
    public let schema: FormSchema
    @Binding public var values: [String: JSONValue]

    public init(schema: FormSchema, values: Binding<[String: JSONValue]>) {
        self.schema = schema
        self._values = values
    }

    public var body: some View {
        ForEach(schema.fields) { field in
            DynamicFormField(field: field, values: $values)
        }
    }
}

/// Una row del form dinámico. Renderea LabeledContent + control según
/// `field.type`. Marca required con asterisco rojo en el label.
public struct DynamicFormField: View {
    public let field: FormFieldSpec
    @Binding public var values: [String: JSONValue]

    public init(field: FormFieldSpec, values: Binding<[String: JSONValue]>) {
        self.field = field
        self._values = values
    }

    public var body: some View {
        switch field.type {
        case .text:
            LabeledContent {
                TextField(field.placeholder ?? "", text: stringBinding)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.sentences)
            } label: {
                labelView
            }

        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                labelView
                TextField(field.placeholder ?? "", text: stringBinding, axis: .vertical)
                    .lineLimit(3...8)
                if let help = field.helpText, !help.isEmpty {
                    Text(help).font(.caption2).foregroundStyle(.secondary)
                }
            }

        case .number:
            LabeledContent {
                TextField(field.placeholder ?? "", text: stringBinding)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            } label: {
                labelView
            }

        case .currency:
            LabeledContent {
                TextField(field.placeholder ?? "0.00", text: stringBinding)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
            } label: {
                labelView
            }

        case .date:
            DatePicker(selection: dateBinding, displayedComponents: [.date]) {
                labelView
            }

        case .datetime:
            DatePicker(selection: dateBinding, displayedComponents: [.date, .hourAndMinute]) {
                labelView
            }

        case .boolean:
            Toggle(isOn: boolBinding) {
                labelView
            }

        case .picker:
            if field.options.isEmpty {
                LabeledContent {
                    TextField(field.placeholder ?? "", text: stringBinding)
                        .multilineTextAlignment(.trailing)
                } label: {
                    labelView
                }
            } else {
                Picker(selection: stringBinding) {
                    Text("Selecciona…").tag("")
                    ForEach(field.options, id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                } label: {
                    labelView
                }
            }

        case .fileUrl:
            LabeledContent {
                TextField(field.placeholder ?? "https://…", text: stringBinding)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } label: {
                labelView
            }

        case .actorRef, .resourceRef:
            // Fallback defensivo: estos field types están reservados para
            // action forms con stores cargados (`ResourceActionFormView`),
            // no aplican al schema de metadata estático.
            LabeledContent {
                TextField(field.placeholder ?? "", text: stringBinding)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
            } label: {
                labelView
            }
        }
    }

    @ViewBuilder
    private var labelView: some View {
        if field.required {
            HStack(spacing: 2) {
                Text(field.label)
                Text("*").foregroundStyle(.red)
            }
        } else {
            Text(field.label)
        }
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { values[field.key]?.stringValue ?? "" },
            set: { values[field.key] = $0.isEmpty ? nil : .string($0) }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { values[field.key]?.boolValue ?? false },
            set: { values[field.key] = .bool($0) }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                if case .string(let s)? = values[field.key],
                   let d = ISO8601DateFormatter().date(from: s) {
                    return d
                }
                return Date()
            },
            set: { values[field.key] = .string(ISO8601DateFormatter().string(from: $0)) }
        )
    }
}
