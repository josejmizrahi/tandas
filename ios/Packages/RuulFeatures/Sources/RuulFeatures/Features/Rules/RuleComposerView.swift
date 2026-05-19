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
    @Environment(AppState.self) private var app
    public var onPublished: (RuleVersionPublishResult) -> Void
    public var onCancel: () -> Void
    @State private var showStarterPicker = false
    /// §22.4: gates the destructive "drop OR/NOT structure" prompt
    /// when the user toggles Avanzado OFF on a non-flat tree.
    @State private var showAdvancedExitConfirm = false

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
                    guidedProgressStrip
                    nameSection
                    triggerSection
                    conditionsSection
                    exceptionsSection
                    consequencesSection
                    membershipFilterSection
                    previewSection
                    if let error = coord.error {
                        Text(error)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulWarning)
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.s12)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(coord.editingRuleId == nil ? "Componer acuerdo" : "Editar acuerdo")
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
                UniversalTemplateGallerySheet(
                    templates: coord.starterTemplates,
                    onSelect: { template in
                        coord.loadStarterTemplate(template)
                        showStarterPicker = false
                    },
                    onCancel: { showStarterPicker = false }
                )
            }
            // Loads the active roster so the §22.5 membership filter
            // picker has names to show. No-op on re-appear; failures
            // log silently (picker just stays empty).
            .task {
                await coord.loadAvailableMembers(using: app.groupsRepo)
            }
        }
    }

    // MARK: Sections

    /// Mini-progress chips arriba del form. Visualiza las 3 piezas
    /// requeridas para publicar una regla (disparador + consecuencia
    /// son obligatorias; condiciones son opcionales pero recomendadas).
    /// Cada chip:
    ///   - dot verde + texto normal cuando la pieza ya está
    ///   - dot gris + texto sub cuando falta
    /// El usuario escanea al instante qué le falta antes de publicar.
    private var guidedProgressStrip: some View {
        let triggerDone = coord.draft.trigger != nil
        let conditionDone = !coord.draft.conditions.isEmpty
        let consequenceDone = !coord.draft.consequences.isEmpty
        return HStack(spacing: RuulSpacing.sm) {
            progressChip(label: "Disparador", done: triggerDone, required: true)
            progressChip(label: "Condiciones", done: conditionDone, required: false)
            progressChip(label: "Consecuencia", done: consequenceDone, required: true)
            Spacer(minLength: 0)
        }
        .padding(.bottom, RuulSpacing.xs)
    }

    private func progressChip(label: String, done: Bool, required: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(done ? Color.ruulPositive : (required ? Color.ruulTextTertiary : Color.ruulSeparator))
                .frame(width: 6, height: 6)
            Text(label)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(done ? Color.ruulTextSecondary : Color.ruulTextTertiary)
        }
    }

    /// Helper text below a sectionLabel. Explica por qué la pieza
    /// existe sin meterle un help icon — el usuario ve la guía sin
    /// tap extra. Solo se renderiza cuando hay copy útil.
    @ViewBuilder
    private func sectionHint(_ text: String) -> some View {
        Text(text)
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

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
            sectionLabel("Cuándo sucede")
            sectionHint("El momento que hace que el acuerdo corra. Sin elegir cuándo, nunca se activa.")
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
                    Text("No hay momentos compatibles con este recurso")
                        .ruulTextStyle(RuulTypography.caption)
                }
            } label: {
                pickerLabel(
                    text: coord.draft.trigger == nil ? "Elegir cuándo" : "Cambiar cuándo",
                    systemImage: coord.draft.trigger == nil ? "plus.circle" : "arrow.triangle.2.circlepath"
                )
            }
        }
    }

    private var conditionsSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel(coord.isAdvancedMode
                             ? "Condiciones (todas / cualquiera / ninguna)"
                             : "Condiciones (todas se cumplen)")
                Spacer(minLength: 0)
                advancedToggle
            }
            sectionHint(coord.isAdvancedMode
                        ? "Agrupa condiciones con 'cualquiera' o márcalas como 'ninguna' desde el menú ⋯. Sin agrupar, todas se combinan con 'todas'."
                        : "Filtros adicionales. Sin condiciones, el acuerdo aplica siempre que suceda.")
            if coord.isAdvancedMode, let tree = coord.draft.conditionsTree {
                conditionTreeView(tree, depth: 0)
            } else {
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
        // Confirmation when toggling Avanzado OFF would drop OR/NOT.
        .confirmationDialog(
            "Aplanar agrupaciones",
            isPresented: $showAdvancedExitConfirm,
            titleVisibility: .visible
        ) {
            Button("Aplanar (perder estructura)", role: .destructive) {
                coord.exitAdvancedMode()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Hay agrupaciones de 'cualquiera' / 'ninguna'. Aplanar las quita y deja solo la lista plana de condiciones.")
        }
    }

    /// Section-header toggle that flips between Simple (flat list) and
    /// Avanzado (AND/OR/NOT tree). When the user turns it OFF and the
    /// tree carries structure, asks for confirmation before flattening.
    @ViewBuilder
    private var advancedToggle: some View {
        Toggle(isOn: Binding(
            get: { coord.isAdvancedMode },
            set: { newValue in
                if newValue {
                    coord.enterAdvancedMode()
                } else if coord.advancedHasStructure {
                    showAdvancedExitConfirm = true
                } else {
                    coord.exitAdvancedMode()
                }
            }
        )) {
            Text("Avanzado")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
    }

    /// Recursive renderer for an AND/OR/NOT tree. `depth` drives the
    /// indent — each level offsets by `RuulSpacing.md` so the user
    /// reads structure as visual nesting.
    // Recursive renderer — return AnyView to break the opaque-type
    // self-reference cycle (some View inferred from a body that calls
    // itself recursively can't be inferred).
    private func conditionTreeView(_ node: ShapeNode, depth: Int) -> AnyView {
        switch node {
        case .leaf(let instance):
            if let shape = coord.shape(id: instance.shapeId) {
                return AnyView(
                    HStack(alignment: .top, spacing: RuulSpacing.xs) {
                        ShapeInstanceRow(
                            shape: shape,
                            instance: instance,
                            onConfigChange: { key, value in
                                coord.updateConfig(forShapeInstanceId: instance.id, key: key, value: value)
                            },
                            onRemove: { coord.removeCondition(id: instance.id) }
                        )
                        leafActionsMenu(leafId: instance.id)
                    }
                    .padding(.leading, CGFloat(depth) * RuulSpacing.md)
                )
            }
            return AnyView(EmptyView())
        case .and(let id, let children), .or(let id, let children):
            let isOr: Bool = { if case .or = node { return true } else { return false } }()
            return AnyView(
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    HStack(spacing: RuulSpacing.xs) {
                        Text(isOr ? "Cualquiera de estas:" : "Todas estas:")
                            .ruulTextStyle(RuulTypography.captionBold)
                            .foregroundStyle(isOr ? Color.ruulAccent : Color.ruulTextSecondary)
                        Spacer(minLength: 0)
                        opActionsMenu(opId: id, canToggle: true)
                    }
                    .padding(.leading, CGFloat(depth) * RuulSpacing.md)
                    ForEach(children) { child in
                        conditionTreeView(child, depth: depth + 1)
                    }
                }
            )
        case .not(let id, let child):
            return AnyView(
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    HStack(spacing: RuulSpacing.xs) {
                        Text("Ninguna se cumple:")
                            .ruulTextStyle(RuulTypography.captionBold)
                            .foregroundStyle(Color.ruulWarning)
                        Spacer(minLength: 0)
                        opActionsMenu(opId: id, canToggle: false)
                    }
                    .padding(.leading, CGFloat(depth) * RuulSpacing.md)
                    conditionTreeView(child, depth: depth + 1)
                }
            )
        }
    }

    /// Per-leaf actions menu in Avanzado mode. Lets the user wrap the
    /// leaf with the next sibling as OR (composer's "A AND (B OR C)"
    /// flow) or wrap it in NOT.
    @ViewBuilder
    private func leafActionsMenu(leafId: UUID) -> some View {
        Menu {
            Button {
                coord.wrapWithNextAsOR(id: leafId)
            } label: {
                Label("Combinar con siguiente (cualquiera)", systemImage: "rectangle.connected.to.line.below")
            }
            Button {
                coord.wrapAsNOT(id: leafId)
            } label: {
                Label("Marcar como 'ninguna' (negar)", systemImage: "exclamationmark.octagon")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .ruulTextStyle(RuulTypography.subheadMedium)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.top, RuulSpacing.xs)
                .accessibilityLabel("Acciones para esta condición")
        }
    }

    /// Per-op-node actions menu (AND / OR / NOT). Lets the user flip
    /// AND ⇄ OR and unwrap the grouping. NOT can be unwrapped but
    /// can't be toggled (NOT has no AND/OR sibling shape).
    @ViewBuilder
    private func opActionsMenu(opId: UUID, canToggle: Bool) -> some View {
        Menu {
            if canToggle {
                Button {
                    coord.toggleAndOr(id: opId)
                } label: {
                    Label("Cambiar: todas ↔ cualquiera", systemImage: "arrow.left.arrow.right")
                }
            }
            Button(role: .destructive) {
                coord.unwrapGrouping(id: opId)
            } label: {
                Label("Quitar agrupación", systemImage: "rectangle.dashed")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
                .accessibilityLabel("Acciones para esta agrupación")
        }
    }

    private var exceptionsSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            sectionLabel("Excepto cuando…")
            sectionHint("Casos en los que el acuerdo no debe aplicar aunque las condiciones se cumplan.")
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
            sectionHint("Qué pasa cuando el acuerdo aplica: cobrar multa, emitir warning, etc.")
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

    /// Optional "Solo para X" filter (§22.5 / mig 00250). Hidden when
    /// no members loaded — preview / test contexts don't surface a
    /// picker because there's nothing to pick from. Selecting "Todos
    /// los miembros" clears the filter.
    @ViewBuilder
    private var membershipFilterSection: some View {
        if !coord.availableMembers.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                sectionLabel("Solo para un miembro (opcional)")
                Menu {
                    Button(action: { coord.setMembershipFilter(nil) }) {
                        Label("Todos los miembros", systemImage: "person.3.fill")
                    }
                    ForEach(coord.availableMembers) { member in
                        Button(action: { coord.setMembershipFilter(member.member.id) }) {
                            Label(member.displayName, systemImage: "person.fill")
                        }
                    }
                } label: {
                    pickerLabel(
                        text: membershipFilterLabel,
                        systemImage: coord.draft.membershipFilter == nil ? "person.3" : "person.fill"
                    )
                }
            }
        }
    }

    private var membershipFilterLabel: String {
        guard let id = coord.draft.membershipFilter else {
            return "Aplica a todos los miembros"
        }
        let name = coord.memberDisplayName(forMembershipId: id) ?? "este miembro"
        return "Solo para \(name)"
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
        // inspiration) and Vision §rules. Passes a name resolver so the
        // membership prefix (§22.5) shows the real name, not a UUID.
        RuleSentenceFormatter.sentence(
            for: coord.draft,
            registry: coord.shapeRegistry,
            singleLine: false,
            memberNameProvider: { coord.memberDisplayName(forMembershipId: $0) }
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

// Gallery sheet implementation lives in UniversalTemplateGallerySheet.swift —
// shared between RulesView (empty-state Gallery-first CTA) and the composer's
// "Ejemplo" toolbar action above.
