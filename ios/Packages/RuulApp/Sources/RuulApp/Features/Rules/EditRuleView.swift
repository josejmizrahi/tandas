import SwiftUI
import RuulCore

/// Apple-native Form for authoring a rule. Templates-only in V2-G3.1:
/// in `.text` mode this is the original body editor; in `.engine` mode
/// it renders a schema-driven shape builder (trigger → optional
/// condition → consequence) wired to the atom catalog. The view never
/// invents predicates or actions — picks come from
/// `RulesStore.availableShapes` and field values are validated server-
/// side via `validate_rule_shape`.
struct EditRuleView: View {
    @Bindable var store: RulesStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false
    @State private var isValidating: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                modePickerSection
                titleSection
                metadataSection

                switch store.draftMode {
                case .text:
                    bodySection
                case .engine:
                    engineShapeSection
                    engineConditionSection
                    engineConsequenceSection
                    validationSection
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.Rules.createTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.Rules.cancel)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(L10n.Rules.save)
                        }
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: - Shared sections

    private var modePickerSection: some View {
        Section {
            Picker(selection: modeBinding) {
                Text("Texto").tag(RuleDraftMode.text)
                Text("Con engine").tag(RuleDraftMode.engine)
            } label: {
                Text("Modo")
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(store.draftMode == .text
                 ? "Una regla en texto: la decisión sigue siendo humana."
                 : "Una regla con engine: el sistema evalúa cada evento y aplica consecuencias automáticamente.")
        }
    }

    private var titleSection: some View {
        Section {
            TextField(
                String(localized: L10n.Rules.ruleTitlePlaceholder),
                text: $store.draftTitle
            )
            .textInputAutocapitalization(.sentences)
            .submitLabel(.next)
        } header: {
            Text(L10n.Rules.ruleTitleLabel)
        }
    }

    private var metadataSection: some View {
        Section {
            Picker(selection: $store.draftType) {
                ForEach(GroupRuleType.displayOrder, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            } label: {
                Text(L10n.Rules.typeLabel)
            }
            .pickerStyle(.menu)

            Stepper(
                "\(String(localized: L10n.Rules.severityLabel)) · \(store.draftSeverity)",
                value: $store.draftSeverity,
                in: 0...5
            )
        }
    }

    private var bodySection: some View {
        Section {
            TextField(
                String(localized: L10n.Rules.bodyPlaceholder),
                text: $store.draftBody,
                axis: .vertical
            )
            .lineLimit(3...8)
        } header: {
            Text(L10n.Rules.bodyLabel)
        }
    }

    // MARK: - Engine sections

    private var engineShapeSection: some View {
        Section {
            Picker(selection: triggerBinding) {
                Text("Elegir…").tag(String?.none)
                ForEach(store.triggerShapes) { shape in
                    Text(shape.displayName).tag(String?.some(shape.shapeKey))
                }
            } label: {
                Text("Disparador")
            }
            .pickerStyle(.menu)

            if let trigger = store.selectedTrigger,
               let description = trigger.description {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Cuándo se evalúa")
        } footer: {
            if store.availableShapes.isEmpty {
                Text("Cargando catálogo de reglas…")
            } else if store.selectedTrigger == nil {
                Text("Elige qué evento dispara la evaluación.")
            }
        }
    }

    @ViewBuilder
    private var engineConditionSection: some View {
        if store.selectedTrigger != nil {
            Section {
                Picker(selection: conditionBinding) {
                    Text("Sin condición").tag(String?.none)
                    ForEach(store.compatibleConditions) { shape in
                        Text(shape.displayName).tag(String?.some(shape.shapeKey))
                    }
                } label: {
                    Text("Condición")
                }
                .pickerStyle(.menu)

                if let condition = store.selectedCondition {
                    if let description = condition.description {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(condition.fields, id: \.key) { field in
                        EngineFieldEditor(
                            field: field,
                            value: conditionFieldBinding(for: field.key)
                        )
                    }
                }
            } header: {
                Text("Filtro opcional")
            }
        }
    }

    @ViewBuilder
    private var engineConsequenceSection: some View {
        if store.selectedTrigger != nil {
            Section {
                Picker(selection: consequenceBinding) {
                    Text("Elegir…").tag(String?.none)
                    ForEach(store.compatibleConsequences) { shape in
                        Text(shape.displayName).tag(String?.some(shape.shapeKey))
                    }
                } label: {
                    Text("Consecuencia")
                }
                .pickerStyle(.menu)

                if let consequence = store.selectedConsequence {
                    if let description = consequence.description {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: consequence.execution == .sync
                              ? "bolt.fill" : "tray.and.arrow.up")
                            .foregroundStyle(.tint)
                        Text(consequence.execution == .sync
                             ? "Se ejecuta de inmediato"
                             : "Se encola (notificación)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(consequence.fields, id: \.key) { field in
                        EngineFieldEditor(
                            field: field,
                            value: consequenceFieldBinding(for: field.key)
                        )
                    }
                }
            } header: {
                Text("Qué pasa entonces")
            }
        }
    }

    @ViewBuilder
    private var validationSection: some View {
        if store.selectedTrigger != nil, store.selectedConsequence != nil {
            Section {
                Button {
                    Task {
                        isValidating = true
                        defer { isValidating = false }
                        await store.dryRunValidate()
                    }
                } label: {
                    HStack {
                        if isValidating { ProgressView() }
                        Text("Probar regla")
                    }
                }
                .disabled(isValidating)

                if let result = store.draftValidation {
                    if result.valid {
                        Label("Válida — el backend la aceptaría.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.tint)
                    } else {
                        ForEach(result.errors, id: \.path) { err in
                            Label(err.message, systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var modeBinding: Binding<RuleDraftMode> {
        Binding(
            get: { store.draftMode },
            set: { store.switchDraftMode(to: $0) }
        )
    }

    private var triggerBinding: Binding<String?> {
        Binding(
            get: { store.draftTriggerKey },
            set: { store.selectTrigger(key: $0) }
        )
    }

    private var conditionBinding: Binding<String?> {
        Binding(
            get: { store.draftConditionKey },
            set: { store.selectCondition(key: $0) }
        )
    }

    private var consequenceBinding: Binding<String?> {
        Binding(
            get: { store.draftConsequenceKey },
            set: { store.selectConsequence(key: $0) }
        )
    }

    private func conditionFieldBinding(for key: String) -> Binding<RPCJSONValue?> {
        Binding(
            get: { store.draftConditionFields[key] },
            set: { store.setConditionField(key, $0) }
        )
    }

    private func consequenceFieldBinding(for key: String) -> Binding<RPCJSONValue?> {
        Binding(
            get: { store.draftConsequenceFields[key] },
            set: { store.setConsequenceField(key, $0) }
        )
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.createDraft(groupId: groupId)
        if ok { dismiss() }
    }
}

// MARK: - Schema-driven field editor

/// Renders a single `RuleShapeField` as the appropriate Form input.
/// All values funnel through `RPCJSONValue` so the resulting jsonb
/// round-trips losslessly to the backend.
private struct EngineFieldEditor: View {
    let field: RuleShapeField
    @Binding var value: RPCJSONValue?

    var body: some View {
        switch field.type {
        case "boolean":
            Toggle(label, isOn: boolBinding)
        case "number", "integer":
            HStack {
                Text(label)
                Spacer()
                TextField("", text: numberBinding)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(field.type == "integer" ? .numberPad : .decimalPad)
                    .frame(maxWidth: 140)
            }
        case "enum":
            Picker(selection: stringBinding) {
                Text("—").tag("")
                ForEach(field.enum ?? [], id: \.self) {
                    Text($0).tag($0)
                }
            } label: {
                Text(label)
            }
            .pickerStyle(.menu)
        case "string_array":
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                TextField("Separados por coma", text: stringArrayBinding)
                    .textInputAutocapitalization(.never)
            }
        default: // string + unknown
            HStack {
                Text(label)
                Spacer()
                TextField("", text: stringBinding)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var label: String { field.label ?? field.key }

    private var stringBinding: Binding<String> {
        Binding(
            get: {
                if case .string(let s)? = value { return s }
                return ""
            },
            set: { new in
                value = new.isEmpty ? nil : .string(new)
            }
        )
    }

    private var numberBinding: Binding<String> {
        Binding(
            get: {
                if case .number(let n)? = value { return "\(n)" }
                return ""
            },
            set: { new in
                let trimmed = new.replacingOccurrences(of: ",", with: ".")
                if let dec = Decimal(string: trimmed) {
                    value = .number(dec)
                } else if new.isEmpty {
                    value = nil
                }
            }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: {
                if case .bool(let b)? = value { return b }
                return false
            },
            set: { value = .bool($0) }
        )
    }

    private var stringArrayBinding: Binding<String> {
        Binding(
            get: {
                if case .array(let arr)? = value {
                    return arr.compactMap { item -> String? in
                        if case .string(let s) = item { return s }
                        return nil
                    }.joined(separator: ", ")
                }
                return ""
            },
            set: { new in
                let parts = new
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                value = parts.isEmpty ? nil : .array(parts.map { .string($0) })
            }
        )
    }
}
