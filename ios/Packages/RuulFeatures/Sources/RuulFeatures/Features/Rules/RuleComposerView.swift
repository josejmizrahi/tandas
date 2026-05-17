import SwiftUI
import RuulUI
import RuulCore

/// Free-composition Rule Composer. Single scrollable form (not a wizard)
/// — the user iterates over name + trigger + conditions + consequences
/// in any order. Publish CTA gates on `coordinator.canPublish`.
///
/// Compatibility filtering: trigger picker only offers shapes compatible
/// with the draft's scope + resource type (delegated to the coordinator's
/// `availableTriggers`). Conditions/consequences are flat — they
/// operate on the rule target, not the scope.
public struct RuleComposerView: View {
    @Bindable var coord: RuleComposerCoordinator
    public var onPublished: (RuleVersionPublishResult) -> Void
    public var onCancel: () -> Void
    @State private var showStarterPicker = false

    public init(
        coord: RuleComposerCoordinator,
        onPublished: @escaping (RuleVersionPublishResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.coord = coord
        self.onPublished = onPublished
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    nameSection
                    triggerSection
                    conditionsSection
                    exceptionsSection
                    consequencesSection
                    previewSection
                    if let error = coord.error {
                        Text(error)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextWarning)
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.s12)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(coord.editingRuleId == nil ? "Componer regla" : "Editar regla")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onCancel)
                }
                ToolbarItem(placement: .primaryAction) {
                    // "Ejemplo" only makes sense when starting fresh.
                    // In edit mode, the rule already exists — loading an
                    // example would overwrite the user's work in progress.
                    if coord.editingRuleId == nil && !coord.starterTemplates.isEmpty {
                        Button { showStarterPicker = true } label: {
                            Label("Ejemplo", systemImage: "lightbulb")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(coord.editingRuleId == nil ? "Publicar" : "Guardar") {
                        Task {
                            if let result = await coord.publish() {
                                onPublished(result)
                            }
                        }
                    }
                    .disabled(!coord.canPublish)
                }
            }
            .sheet(isPresented: $showStarterPicker) {
                StarterTemplatePickerSheet(
                    templates: coord.starterTemplates,
                    onSelect: { template in
                        coord.loadStarterTemplate(template)
                        showStarterPicker = false
                    },
                    onCancel: { showStarterPicker = false }
                )
            }
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            sectionLabel("Nombre")
            TextField("Ej. Multa por llegar tarde", text: nameBinding)
                .textFieldStyle(.roundedBorder)
                .ruulTextStyle(RuulTypography.body)
            if let preview = coord.slugPreview {
                HStack(spacing: RuulSpacing.xxs) {
                    Image(systemName: "tag")
                        .ruulTextStyle(RuulTypography.captionBold)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .accessibilityHidden(true)
                    Text("ID: \(preview)")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
                .accessibilityLabel("Identificador estable del acuerdo: \(preview)")
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { coord.draft.name },
            set: { coord.setName($0) }
        )
    }

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            sectionLabel("Cuándo se dispara")
            if let trigger = coord.draft.trigger, let shape = coord.shape(id: trigger.shapeId) {
                ShapeInstanceRow(
                    shape: shape,
                    instance: trigger,
                    onConfigChange: { key, value in
                        coord.updateConfig(forShapeInstanceId: trigger.id, key: key, value: value)
                    },
                    onRemove: { coord.clearTrigger() }
                )
            }
            Menu {
                ForEach(coord.availableTriggers) { shape in
                    Button(action: { coord.setTrigger(shapeId: shape.id) }) {
                        Label(shape.labelES, systemImage: shape.icon ?? "bolt")
                    }
                }
                if coord.availableTriggers.isEmpty {
                    Text("Sin disparadores compatibles con este recurso")
                        .ruulTextStyle(RuulTypography.caption)
                }
            } label: {
                pickerLabel(
                    text: coord.draft.trigger == nil ? "Elegir disparador" : "Cambiar disparador",
                    systemImage: coord.draft.trigger == nil ? "plus.circle" : "arrow.triangle.2.circlepath"
                )
            }
        }
    }

    private var conditionsSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            sectionLabel("Condiciones (todas se cumplen)")
            ForEach(coord.draft.conditions) { instance in
                if let shape = coord.shape(id: instance.shapeId) {
                    ShapeInstanceRow(
                        shape: shape,
                        instance: instance,
                        onConfigChange: { key, value in
                            coord.updateConfig(forShapeInstanceId: instance.id, key: key, value: value)
                        },
                        onRemove: { coord.removeCondition(id: instance.id) }
                    )
                }
            }
            Menu {
                ForEach(coord.availableConditions) { shape in
                    Button(action: { coord.addCondition(shapeId: shape.id) }) {
                        Label(shape.labelES, systemImage: shape.icon ?? "checkmark.seal")
                    }
                }
            } label: {
                pickerLabel(text: "Agregar condición", systemImage: "plus.circle")
            }
        }
    }

    private var exceptionsSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            sectionLabel("Excepto si (cualquiera bloquea la consecuencia)")
            ForEach(coord.draft.exceptions) { instance in
                if let shape = coord.shape(id: instance.shapeId) {
                    ShapeInstanceRow(
                        shape: shape,
                        instance: instance,
                        onConfigChange: { key, value in
                            coord.updateConfig(forShapeInstanceId: instance.id, key: key, value: value)
                        },
                        onRemove: { coord.removeException(id: instance.id) }
                    )
                }
            }
            Menu {
                ForEach(coord.availableExceptions) { shape in
                    Button(action: { coord.addException(shapeId: shape.id) }) {
                        Label(shape.labelES, systemImage: shape.icon ?? "exclamationmark.octagon")
                    }
                }
            } label: {
                pickerLabel(text: "Agregar excepción", systemImage: "plus.circle")
            }
        }
    }

    private var consequencesSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            sectionLabel("Consecuencias")
            ForEach(coord.draft.consequences) { instance in
                if let shape = coord.shape(id: instance.shapeId) {
                    VStack(alignment: .leading, spacing: 0) {
                        ShapeInstanceRow(
                            shape: shape,
                            instance: instance,
                            onConfigChange: { key, value in
                                coord.updateConfig(forShapeInstanceId: instance.id, key: key, value: value)
                            },
                            onRemove: { coord.removeConsequence(id: instance.id) }
                        )
                        consequenceTargetPicker(for: instance)
                    }
                }
            }
            Menu {
                ForEach(coord.availableConsequences) { shape in
                    Button(action: { coord.addConsequence(shapeId: shape.id) }) {
                        Label(shape.labelES, systemImage: shape.icon ?? "sparkles")
                    }
                }
            } label: {
                pickerLabel(text: "Agregar consecuencia", systemImage: "plus.circle")
            }
        }
    }

    /// Sub-row that lets the user re-route this consequence to a
    /// different target (anti-tirania, §22.3). Hidden when only one
    /// option exists (no custom roles + not on event scope) — there's
    /// nothing to pick beyond the default actor.
    @ViewBuilder
    private func consequenceTargetPicker(for instance: ShapeInstance) -> some View {
        let options = coord.consequenceTargetOptions
        if options.count > 1 {
            Menu {
                ForEach(options) { opt in
                    Button(action: { coord.setConsequenceTarget(instanceId: instance.id, selector: opt.selector) }) {
                        Label(opt.label, systemImage: opt.icon)
                    }
                }
            } label: {
                HStack(spacing: RuulSpacing.xxs) {
                    Image(systemName: "arrow.right.circle")
                        .ruulTextStyle(RuulTypography.captionBold)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .accessibilityHidden(true)
                    Text("Aplica: \(coord.targetLabel(forSelector: instance.target))")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulAccent)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .ruulTextStyle(RuulTypography.captionBold)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.top, 4)
                .padding(.horizontal, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.xs)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            sectionLabel("Vista previa")
            Text(previewSentence)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(RuulSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                        .fill(Color.ruulSurface.opacity(0.5))
                )
        }
    }

    private var previewSentence: String {
        // Canonical formatter — same one used by published rule rows.
        // Renders as Halajic-style teaching sentence: "Cuando X, si Y,
        // entonces Z." per Constitution §18 (Talmud structural
        // inspiration) and Vision §rules.
        RuleSentenceFormatter.sentence(
            for: coord.draft,
            registry: coord.shapeRegistry,
            singleLine: false
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .ruulTextStyle(RuulTypography.sectionLabelLg)
            .foregroundStyle(Color.ruulTextSecondary)
    }

    private func pickerLabel(text: String, systemImage: String) -> some View {
        HStack(spacing: RuulSpacing.xs) {
            Image(systemName: systemImage)
            Text(text)
        }
        .ruulTextStyle(RuulTypography.body)
        .foregroundStyle(Color.ruulAccent)
        .padding(.vertical, RuulSpacing.sm)
        .padding(.horizontal, RuulSpacing.md)
        .background(
            Capsule().fill(Color.ruulAccent.opacity(0.12))
        )
    }
}

// MARK: - Row

/// Single shape instance with inline config editing. Renders one field
/// per `shape.configFields`; supports int / currency / string today —
/// other kinds fall back to a disabled placeholder.
private struct ShapeInstanceRow: View {
    let shape: RuleShape
    let instance: ShapeInstance
    var onConfigChange: (String, JSONConfig) -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(alignment: .top, spacing: RuulSpacing.sm) {
                if let icon = shape.icon {
                    Image(systemName: icon)
                        .ruulTextStyle(RuulTypography.subheadMedium)
                        .foregroundStyle(Color.ruulAccent)
                        .frame(width: 28, height: 28)
                        .background(Color.ruulSurface, in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(shape.labelES)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if let summary = shape.summaryES, !summary.isEmpty {
                        Text(summary)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quitar")
            }
            if !shape.configFields.isEmpty {
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    ForEach(shape.configFields, id: \.key) { field in
                        FieldRow(field: field, currentValue: currentValue(for: field.key)) { newValue in
                            onConfigChange(field.key, newValue)
                        }
                    }
                }
                .padding(.leading, RuulSpacing.lg)
            }
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private func currentValue(for key: String) -> JSONConfig? {
        guard case .object(let dict) = instance.config else { return nil }
        return dict[key]
    }
}

// MARK: - Field

private struct FieldRow: View {
    let field: RuleShapeField
    let currentValue: JSONConfig?
    var onChange: (JSONConfig) -> Void

    @State private var text: String = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(field.labelES)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                TextField(field.placeholder ?? "", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(keyboardType)
                    .ruulTextStyle(RuulTypography.body)
                    .onAppear {
                        text = renderInitial()
                    }
                    .onChange(of: text) { _, newValue in
                        if let parsed = parse(newValue) {
                            onChange(parsed)
                        }
                    }
            }
        }
    }

    private var keyboardType: UIKeyboardType {
        switch field.kind {
        case .int, .currency: return .numberPad
        case .string:         return .default
        }
    }

    private func renderInitial() -> String {
        switch currentValue {
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .bool(let b):   return String(b)
        default:             return ""
        }
    }

    private func parse(_ raw: String) -> JSONConfig? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.kind {
        case .int, .currency:
            guard let n = Int(trimmed.filter(\.isNumber)) else { return nil }
            if let min = field.min, n < min { return nil }
            if let max = field.max, n > max { return nil }
            return .int(n)
        case .string:
            return .string(trimmed)
        }
    }
}

// MARK: - Starter template picker

/// Sheet that lists curated templates as starter patterns. Picking one
/// seeds the composer's draft (replacing whatever was there). Templates
/// are not mandatory — the user can compose from scratch by just
/// closing this sheet without picking.
private struct StarterTemplatePickerSheet: View {
    let templates: [RuleBuilderTemplate]
    var onSelect: (RuleBuilderTemplate) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(templates, id: \.id) { template in
                        Button(action: { onSelect(template) }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.displayNameES)
                                    .ruulTextStyle(RuulTypography.headline)
                                    .foregroundStyle(Color.ruulTextPrimary)
                                Text(template.descriptionES)
                                    .ruulTextStyle(RuulTypography.caption)
                                    .foregroundStyle(Color.ruulTextSecondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, RuulSpacing.xs)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Cargar un ejemplo te ahorra empezar de cero. Después puedes editarlo libremente.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .textCase(nil)
                }
            }
            .navigationTitle("Empezar de un ejemplo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onCancel)
                }
            }
        }
    }
}
