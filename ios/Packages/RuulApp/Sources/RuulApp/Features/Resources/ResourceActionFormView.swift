import SwiftUI
import RuulCore

/// R.5A.F.2 — Runtime form que consume `form_schema` jsonb del descriptor.
/// Construye payload + llama `executeResourceAction`. Maneja confirmation
/// sheet si `confirmation_required=true`, y dispatch result (execute vs
/// request_decision con decision_id).
public struct ResourceActionFormView: View {
    let resourceId: UUID
    let action: ResourceDescriptorAction
    let actionForm: ResourceActionForm?
    let container: DependencyContainer
    /// Callback al cerrar exitosamente para refresh de actions en el caller.
    let onSuccess: (ExecuteResourceActionResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: JSONValue] = [:]
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var isShowingConfirmation = false
    @State private var successResult: ExecuteResourceActionResult?

    public init(
        resourceId: UUID,
        action: ResourceDescriptorAction,
        actionForm: ResourceActionForm?,
        container: DependencyContainer,
        onSuccess: @escaping (ExecuteResourceActionResult) -> Void
    ) {
        self.resourceId = resourceId
        self.action = action
        self.actionForm = actionForm
        self.container = container
        self.onSuccess = onSuccess
    }

    private var schema: FormSchema {
        guard let f = actionForm else { return FormSchema() }
        return FormSchema(from: f.formSchema)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: ActionPresentationCatalog.presentation(for: action.actionKey).symbolName)
                            .font(.title2)
                            .foregroundStyle(action.dangerous ? Color.red : Color.accentColor)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.label).font(.headline)
                            if action.isRequestDecision {
                                Text("Se abrirá una decisión grupal")
                                    .font(.caption)
                                    .foregroundStyle(.purple)
                            } else if action.dangerous {
                                Text("Acción destructiva")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                if schema.isEmpty {
                    Section {
                        Text("Esta acción no requiere datos adicionales.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } else {
                    Section("Datos") {
                        ForEach(schema.fields) { field in
                            fieldControl(field)
                        }
                    }
                }

                if let msg = errorMessage {
                    Section {
                        Text(msg).foregroundStyle(.red).font(.caption)
                    }
                }

                Section {
                    Button {
                        attemptSubmit()
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView().tint(.white)
                            } else {
                                Text(schema.submitLabel ?? action.label)
                                    .font(.body.bold())
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(action.dangerous ? .red : .accentColor)
                    .disabled(isSubmitting)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
            .navigationTitle(action.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .onAppear {
                seedDefaultsFromForm()
            }
            .alert("¿Confirmar?", isPresented: $isShowingConfirmation, presenting: confirmationMessage()) { _ in
                Button("Cancelar", role: .cancel) {}
                Button(action.dangerous ? "Sí, ejecutar" : "Continuar",
                       role: action.dangerous ? .destructive : nil) {
                    Task { await submit() }
                }
            } message: { msg in
                Text(msg)
            }
            .alert("Listo", isPresented: Binding(
                get: { successResult != nil },
                set: { if !$0 { successResult = nil } }
            ), presenting: successResult) { result in
                Button("OK") {
                    let r = result
                    onSuccess(r)
                    dismiss()
                }
            } message: { result in
                if result.isRequestDecision {
                    Text("Se abrió una decisión grupal. Los miembros con voto recibirán la solicitud.")
                } else {
                    Text("Acción ejecutada.")
                }
            }
        }
    }

    // MARK: - Field controls

    @ViewBuilder
    private func fieldControl(_ field: FormFieldSpec) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: 2) {
                Text(field.label).font(.subheadline)
                if field.required {
                    Text("*").foregroundStyle(.red).font(.subheadline)
                }
            }
            switch field.type {
            case .text:
                TextField(field.placeholder ?? field.label, text: stringBinding(for: field.key))
                    .textInputAutocapitalization(.sentences)
            case .multiline:
                TextField(field.placeholder ?? field.label, text: stringBinding(for: field.key), axis: .vertical)
                    .lineLimit(3...8)
            case .number:
                TextField(field.placeholder ?? "0", text: stringBinding(for: field.key))
                    .keyboardType(.numberPad)
            case .currency:
                TextField(field.placeholder ?? "0.00", text: stringBinding(for: field.key))
                    .keyboardType(.decimalPad)
            case .date:
                DatePicker("", selection: dateBinding(for: field.key), displayedComponents: [.date])
                    .labelsHidden()
            case .datetime:
                DatePicker("", selection: dateBinding(for: field.key), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            case .boolean:
                Toggle("", isOn: boolBinding(for: field.key)).labelsHidden()
            case .picker:
                if field.options.isEmpty {
                    TextField(field.placeholder ?? field.label, text: stringBinding(for: field.key))
                } else {
                    Picker("", selection: stringBinding(for: field.key)) {
                        Text("Selecciona…").tag("")
                        ForEach(field.options, id: \.self) { opt in
                            Text(opt).tag(opt)
                        }
                    }
                    .pickerStyle(.menu)
                }
            case .actorRef:
                TextField(field.placeholder ?? "UUID del actor", text: stringBinding(for: field.key))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            case .resourceRef:
                TextField(field.placeholder ?? "UUID del recurso", text: stringBinding(for: field.key))
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            case .fileUrl:
                TextField(field.placeholder ?? "https://…", text: stringBinding(for: field.key))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if let help = field.helpText, !help.isEmpty {
                Text(help).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key]?.stringValue ?? "" },
            set: { values[key] = .string($0) }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { values[key]?.boolValue ?? false },
            set: { values[key] = .bool($0) }
        )
    }

    private func dateBinding(for key: String) -> Binding<Date> {
        Binding(
            get: {
                if case .string(let s)? = values[key], let d = ISO8601DateFormatter().date(from: s) {
                    return d
                }
                return Date()
            },
            set: { values[key] = .string(ISO8601DateFormatter().string(from: $0)) }
        )
    }

    // MARK: - Defaults

    private func seedDefaultsFromForm() {
        guard let f = actionForm, case .object(let defaults) = f.defaultPayload else { return }
        for (k, v) in defaults where values[k] == nil {
            values[k] = v
        }
    }

    // MARK: - Submit pipeline

    private func confirmationMessage() -> String? {
        guard action.confirmationRequired || (actionForm?.confirmationRequired ?? false) else { return nil }
        if action.dangerous {
            return "Esta acción no se puede deshacer. ¿Continuar?"
        }
        if action.isRequestDecision {
            return "Se abrirá una decisión grupal. ¿Continuar?"
        }
        return "¿Ejecutar \(action.label)?"
    }

    private func attemptSubmit() {
        errorMessage = nil
        // Validar required fields
        if let missing = schema.fields.first(where: { isFieldMissing($0) }) {
            errorMessage = "Falta el campo: \(missing.label)"
            return
        }
        if confirmationMessage() != nil {
            isShowingConfirmation = true
        } else {
            Task { await submit() }
        }
    }

    private func isFieldMissing(_ field: FormFieldSpec) -> Bool {
        guard field.required else { return false }
        guard let v = values[field.key] else { return true }
        switch v {
        case .string(let s): return s.isEmpty
        case .null: return true
        default: return false
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let payload = buildPayload()
        do {
            let result = try await container.rpc.executeResourceAction(
                resourceId: resourceId,
                actionKey: action.actionKey,
                payload: payload,
                clientId: UUID()
            )
            successResult = result
        } catch {
            errorMessage = UserFacingError.from(error).message
        }
    }

    private func buildPayload() -> JSONValue {
        var out: [String: JSONValue] = [:]
        for field in schema.fields {
            guard let raw = values[field.key] else { continue }
            switch field.type {
            case .number, .currency:
                // Convertir string→number si vino como string del TextField
                if case .string(let s) = raw, let n = Double(s) {
                    out[field.key] = .number(n)
                } else {
                    out[field.key] = raw
                }
            case .actorRef where field.multiple:
                // Acumular como array
                if case .string(let s) = raw, !s.isEmpty {
                    let ids = s.split(separator: ",").map { JSONValue.string($0.trimmingCharacters(in: .whitespaces)) }
                    out[field.key] = .array(ids)
                } else {
                    out[field.key] = raw
                }
            default:
                if case .string(let s) = raw, s.isEmpty, !field.required {
                    continue  // skip empty optional strings
                }
                out[field.key] = raw
            }
        }
        return .object(out)
    }
}
