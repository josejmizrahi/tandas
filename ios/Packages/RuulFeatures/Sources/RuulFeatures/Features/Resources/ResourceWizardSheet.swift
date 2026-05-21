import SwiftUI
import RuulUI
import RuulCore

/// Universal ResourceWizard sheet. Five-step polymorphic flow that
/// handles every resource type the registry knows about via a single
/// set of UI components (TypePicker / BuilderFieldRenderer / capability
/// toggle list / rule template picker / review card).
///
/// Founder framing 2026-05-10: resources are created from composable
/// capabilities + rules, not vertical flows. Steps:
///   1. typePicker — ¿qué quieres crear?
///   2. fields     — info básica (per-builder)
///   3. options    — capacidades (toggle + sub-config)
///   4. rules      — acuerdos sugeridos por capacidad activa
///   5. review     — confirmar y crear
public struct ResourceWizardSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator: ResourceWizardCoordinator
    public var onCreated: ((UUID) -> Void)?

    public init(group: RuulCore.Group, suggestedDate: Date = .now.addingTimeInterval(86_400), onCreated: ((UUID) -> Void)? = nil) {
        self.onCreated = onCreated
        // Coordinator built with a placeholder registry; replaced in
        // onAppear once AppState is in scope.
        _coordinator = State(initialValue: ResourceWizardCoordinator(
            group: group,
            registry: ResourceBuilderRegistry(builders: [])
        ))
        _ = suggestedDate
    }

    public var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        leadingButton
                    }
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Inline CTA lives at the bottom of each step;
                        // toolbar slot reserved for utility (e.g.
                        // "Saltar" on the suggested rules step).
                        EmptyView()
                    }
                }
                .animation(.smooth, value: coordinator.step)
        }
        .task {
            // Reseat coordinator with the real registry from AppState
            // PLUS the template's defaultCapabilities map. Founder
            // framing 2026-05-11: the wizard's auto-on caps come from
            // the template, never from a Swift switch.
            await rebuildCoordinatorWithTemplate()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.step {
        case .typePicker:
            WizardTypePicker(
                group: coordinator.group,
                registry: coordinator.registry,
                onSelect: { type in coordinator.selectType(type) }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))

        case .fields:
            fieldsContent
                .transition(.move(edge: .trailing).combined(with: .opacity))

        case .options:
            optionsContent
                .transition(.move(edge: .trailing).combined(with: .opacity))

        case .rules:
            rulesContent
                .transition(.move(edge: .trailing).combined(with: .opacity))

        case .review:
            reviewContent
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    // MARK: - Step 2: Fields

    @ViewBuilder
    private var fieldsContent: some View {
        if let builder = coordinator.selectedBuilder {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    wizardCoverHero(for: builder)
                    headerForBuilder(builder)
                    fieldStack(builder: builder)
                    RuulButton(
                        "Continuar",
                        style: .primary,
                        size: .large,
                        fillsWidth: true,
                        action: { coordinator.advanceFromFields() }
                    )
                    .disabled(!coordinator.canAdvanceFromFields)
                    .padding(.top, RuulSpacing.md)
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xxl)
            }
        }
    }

    /// Procedural mesh-gradient cover preview keyed off the resource
    /// type. Anchors the wizard step in visual identity the way Luma's
    /// create form does — the user always sees "what kind of thing
    /// they're building" before they fill anything in. Same gradient
    /// for every resource of a given type so the cover reads as a
    /// stamp, not a per-event picker (which lives elsewhere).
    private func wizardCoverHero(for builder: any ResourceBuilder) -> some View {
        let cover = coverFor(type: builder.resourceType)
        return RuulCoverView(cover)
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.hero, style: .continuous))
    }

    private func coverFor(type: ResourceType) -> RuulCover {
        switch type {
        case .event:   return .sunset
        case .fund:    return .mint
        case .asset:   return .ember
        case .space:   return .lilac
        case .slot:    return .ocean
        case .right:   return .midnight
        case .unknown: return .clay
        }
    }

    /// Walks the builder's required fields and groups consecutive
    /// date/time/dateTime kinds into a single timeline card (Luma-style
    /// "Comenzar / Fin" pattern). Non-date fields fall through to the
    /// existing renderer one per row. Honors the same `dependsOn` gate
    /// the renderer applies so conditional fields stay hidden.
    @ViewBuilder
    private func fieldStack(builder: any ResourceBuilder) -> some View {
        let groups = groupedFields(builder.requiredFields)
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                switch group {
                case .single(let field):
                    BuilderFieldRenderer(
                        field: field,
                        values: basicFieldsBinding()
                    )
                case .timeline(let fields):
                    timelineCard(fields: fields)
                }
            }
        }
    }

    private func basicFieldsBinding() -> Binding<[String: JSONConfig]> {
        Binding(
            get: { coordinator.basicFields },
            set: { coordinator.basicFields = $0 }
        )
    }

    /// Wizard-step grouping. A run of ≥2 date-shaped fields becomes a
    /// single timeline card; a single date field stays as `.single` so
    /// it renders with the regular `BuilderFieldRenderer` chrome.
    private enum FieldGroup {
        case single(BuilderField)
        case timeline([BuilderField])
    }

    private func groupedFields(_ fields: [BuilderField]) -> [FieldGroup] {
        var out: [FieldGroup] = []
        var run: [BuilderField] = []
        for field in fields {
            if Self.isDateLike(field.kind) {
                run.append(field)
            } else {
                if run.count >= 2 { out.append(.timeline(run)) }
                else { run.forEach { out.append(.single($0)) } }
                run.removeAll(keepingCapacity: true)
                out.append(.single(field))
            }
        }
        if run.count >= 2 { out.append(.timeline(run)) }
        else { run.forEach { out.append(.single($0)) } }
        return out
    }

    private static func isDateLike(_ kind: BuilderField.Kind) -> Bool {
        kind == .date || kind == .time || kind == .dateTime
    }

    /// Timeline card: vertical line with a dot per date row, mirroring
    /// Luma's "Comenzar / Fin" treatment. The first dot is a filled
    /// circle, subsequent dots are hollow rings to convey progression.
    private func timelineCard(fields: [BuilderField]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.offset) { idx, field in
                timelineRow(field: field, isFirst: idx == 0, isLast: idx == fields.count - 1)
                if idx < fields.count - 1 {
                    Divider().padding(.leading, RuulSpacing.xxl + RuulSpacing.md)
                }
            }
        }
        .padding(.vertical, RuulSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func timelineRow(field: BuilderField, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .center, spacing: RuulSpacing.md) {
            timelineMarker(isFirst: isFirst, isLast: isLast)
                .frame(width: RuulSpacing.lg)
            HStack {
                Text(field.label)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: RuulSpacing.sm)
                DatePicker(
                    "",
                    selection: dateBinding(for: field),
                    displayedComponents: dateComponents(for: field.kind)
                )
                .labelsHidden()
                .datePickerStyle(.compact)
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    /// Vertical timeline rail: solid line through the dot. Filled dot
    /// for the first row, hollow ring for the rest. Trims the line at
    /// the top of the first row and the bottom of the last row so the
    /// rail doesn't bleed past the card edges.
    private func timelineMarker(isFirst: Bool, isLast: Bool) -> some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color(.separator))
                    .frame(width: 1.5)
                Rectangle()
                    .fill(isLast ? Color.clear : Color(.separator))
                    .frame(width: 1.5)
            }
            Circle()
                .strokeBorder(Color.ruulAccent, lineWidth: 2)
                .background(
                    Circle().fill(isFirst ? Color.ruulAccent : Color.clear)
                )
                .frame(width: 10, height: 10)
        }
    }

    private func dateBinding(for field: BuilderField) -> Binding<Date> {
        Binding(
            get: {
                guard case let .string(raw)? = coordinator.basicFields[field.key] else {
                    return .now.addingTimeInterval(86_400)
                }
                return BuilderFieldRenderer.parseDateString(raw) ?? .now.addingTimeInterval(86_400)
            },
            set: { newDate in
                coordinator.basicFields[field.key] = .string(
                    BuilderFieldRenderer.formatDate(newDate, kind: field.kind)
                )
            }
        )
    }

    private func dateComponents(for kind: BuilderField.Kind) -> DatePickerComponents {
        switch kind {
        case .date:     return [.date]
        case .time:     return [.hourAndMinute]
        case .dateTime: return [.date, .hourAndMinute]
        default:        return [.date, .hourAndMinute]
        }
    }

    private func headerForBuilder(_ builder: any ResourceBuilder) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.ruulAccent.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: builder.icon)
                    .font(.body)
                    .foregroundStyle(Color.ruulAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(builder.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text(builder.summary)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    // MARK: - Step 3: Options

    @ViewBuilder
    private var optionsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                Text("¿Qué más quieres que pase?")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .padding(.leading, RuulSpacing.xxs)
                if coordinator.availableCapabilityBlocks.isEmpty {
                    emptyCapabilitiesView
                } else {
                    ForEach(coordinator.availableCapabilityBlocks, id: \.id) { block in
                        capabilityRow(for: block)
                    }
                }
                if let error = coordinator.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .padding(.top, RuulSpacing.sm)
                }
                RuulButton(
                    optionsAdvanceLabel,
                    style: .primary,
                    size: .large,
                    fillsWidth: true,
                    action: { coordinator.advanceFromOptions() }
                )
                .disabled(!coordinator.canSubmit)
                .padding(.top, RuulSpacing.md)
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
    }

    private var emptyCapabilitiesView: some View {
        VStack(spacing: RuulSpacing.sm) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Color.secondary)
            Text("Listo, no necesitas configurar nada más.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xl)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large))
    }

    private func capabilityRow(for block: any CapabilityDefinition) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: RuulSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.displayName)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    Text(block.summary)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { coordinator.isCapabilityEnabled(block.id) },
                    set: { _ in coordinator.toggleCapability(block.id) }
                ))
                .labelsHidden()
                .tint(Color.ruulAccent)
            }
            .padding(RuulSpacing.md)
            // Inline sub-config: render every capability's `requiredFields`
            // via BuilderFieldRenderer when the cap is enabled. Founder
            // framing 2026-05-11 — declarative, not per-capability view
            // code. Tier 1.1 (2026-05-12): filter by `dependsOn` so
            // conditional fields (recurrence's count/untilDate) appear
            // only when their parent's value matches.
            if coordinator.isCapabilityEnabled(block.id), !block.requiredFields.isEmpty {
                let configForBlock = coordinator.capabilityConfigs[block.id] ?? [:]
                let visibleFields = block.requiredFields.filter { field in
                    guard let dep = field.dependsOn else { return true }
                    return configForBlock[dep.key] == dep.equalsValue
                }
                if !visibleFields.isEmpty {
                    Divider().padding(.horizontal, RuulSpacing.md)
                    VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                        ForEach(Array(visibleFields.enumerated()), id: \.offset) { _, field in
                            BuilderFieldRenderer(
                                field: field,
                                values: capabilityConfigBinding(for: block.id)
                            )
                        }
                    }
                    .padding(RuulSpacing.md)
                    .transition(.opacity)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }

    /// Two-way binding into `coordinator.capabilityConfigs[blockId]`
    /// with a default of `[:]`. Lets BuilderFieldRenderer write per-
    /// capability sub-config without per-block plumbing.
    private func capabilityConfigBinding(for blockId: String) -> Binding<[String: JSONConfig]> {
        Binding(
            get: { coordinator.capabilityConfigs[blockId] ?? [:] },
            set: { coordinator.capabilityConfigs[blockId] = $0 }
        )
    }

    // MARK: - Step 4: Rules (suggested rules per enabled capability)

    @ViewBuilder
    private var rulesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                universalsSection
                additionalOptionsSection
                RuulButton(
                    rulesAdvanceLabel,
                    style: .primary,
                    size: .large,
                    fillsWidth: true,
                    action: { coordinator.advanceFromRules() }
                )
                .padding(.top, RuulSpacing.md)
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
    }

    /// Legacy capability-suggested rules section, now reduced to options
    /// that don't yet have a universal counterpart (notification reminders,
    /// rotation auto-skip). Rendered as "Acciones adicionales" to signal
    /// it's complementary to the canonical universals above.
    /// Per UniversalRuleTemplates.md §14 Fase 2 (de-duplication).
    @ViewBuilder
    private var additionalOptionsSection: some View {
        if coordinator.hasNonUniversalSuggestedRules {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Acciones adicionales para lo que activaste arriba — recordatorios y reglas específicas.")
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, RuulSpacing.xxs)
            rulesByCapability
        }
    }

    /// Universal Rule Templates section — sits ABOVE the legacy
    /// per-capability "Acuerdos sugeridos". Per UniversalRuleTemplates.md
    /// §14 Fase 2, the wizard surfaces universals so users see the
    /// canonical patterns during create-resource (not only via the
    /// post-create Gallery). Each pick is published as a separate
    /// rule_version scoped to the new resource after submit.
    /// Renders nothing when no universals are compatible with this
    /// resource type (e.g. early Pass-2 types whose trigger shapes
    /// haven't been registered yet).
    @ViewBuilder
    private var universalsSection: some View {
        let compatible = coordinator.compatibleUniversalTemplates(shapeRegistry: app.ruleShapeRegistry)
        if !compatible.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Patrones universales")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                Text("Patrones de coordinación que sirven en muchos grupos. Elige los que apliquen — se activan en este \(coordinator.selectedBuilder?.displayName.lowercased() ?? "recurso") cuando lo crees.")
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(compatible, id: \.id) { template in
                        universalRow(template: template)
                    }
                }
            }
        }
    }

    private func universalRow(template: RuleBuilderTemplate) -> some View {
        let isOn = coordinator.isUniversalSelected(template.id)
        return HStack(alignment: .top, spacing: RuulSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                if template.doctrinalCategory != "uncategorized" {
                    Text(template.doctrinalCategory)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                Text(template.displayNameES)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                if template.naturalLanguagePreviewTemplate != nil {
                    Text(RuleSentenceFormatter.preview(forTemplate: template))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(template.descriptionES)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { _ in coordinator.toggleUniversal(template.id) }
            ))
            .labelsHidden()
            .tint(Color.ruulAccent)
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var rulesByCapability: some View {
        // Filtered to options without a universal counterpart — universal-
        // mapped options surface in the universalsSection above. Per
        // UniversalRuleTemplates.md §14 Fase 2 (de-duplication).
        let grouped = Dictionary(grouping: coordinator.nonUniversalSuggestedRules, by: { $0.block.id })
        // Preserve the catalog order (availableCapabilityBlocks) instead
        // of the dictionary's arbitrary order.
        let orderedBlocks = coordinator.availableCapabilityBlocks
            .filter { coordinator.isCapabilityEnabled($0.id) && grouped[$0.id] != nil }
        ForEach(orderedBlocks, id: \.id) { block in
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text(block.displayName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(grouped[block.id] ?? [], id: \.template.slug) { pair in
                        suggestedRuleRow(block: pair.block, template: pair.template)
                    }
                }
            }
        }
    }

    private func suggestedRuleRow(block: any CapabilityDefinition, template: CapabilityRuleOption) -> some View {
        let isOn = coordinator.isSuggestedRuleSelected(blockId: block.id, slug: template.slug)
        return HStack(alignment: .top, spacing: RuulSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.displayName)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                Text(template.summary)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { _ in coordinator.toggleSuggestedRule(blockId: block.id, slug: template.slug) }
            ))
            .labelsHidden()
            .tint(Color.ruulAccent)
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    // MARK: - Step 5: Review

    @ViewBuilder
    private var reviewContent: some View {
        if let builder = coordinator.selectedBuilder {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    reviewHeader(builder: builder)
                    reviewFields(builder: builder)
                    reviewCapabilities()
                    reviewRules()
                    if let error = coordinator.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                            .padding(.top, RuulSpacing.sm)
                    }
                    RuulButton(
                        coordinator.isCreating ? "Creando…" : submitLabel,
                        style: .primary,
                        size: .large,
                        isLoading: coordinator.isCreating,
                        fillsWidth: true,
                        action: {
                            Task { await submit() }
                        }
                    )
                    .disabled(!coordinator.canSubmit)
                    .padding(.top, RuulSpacing.md)
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xxl)
            }
        }
    }

    private func reviewHeader(builder: any ResourceBuilder) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            headerForBuilder(builder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private func reviewFields(builder: any ResourceBuilder) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Detalles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
            VStack(spacing: 0) {
                ForEach(Array(builder.requiredFields.enumerated()), id: \.offset) { idx, field in
                    HStack(alignment: .firstTextBaseline) {
                        Text(field.label)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                        Spacer()
                        Text(displayValue(for: field))
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(RuulSpacing.md)
                    if idx < builder.requiredFields.count - 1 {
                        Divider().padding(.leading, RuulSpacing.md)
                    }
                }
            }
            .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func reviewCapabilities() -> some View {
        let enabled = coordinator.availableCapabilityBlocks
            .filter { coordinator.isCapabilityEnabled($0.id) }
        if !enabled.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Opciones activas")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(enabled, id: \.id) { block in
                        HStack(spacing: RuulSpacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.ruulAccent)
                            Text(block.displayName)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                            Spacer()
                        }
                        .padding(.horizontal, RuulSpacing.md)
                        .padding(.vertical, RuulSpacing.sm)
                        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func reviewRules() -> some View {
        // Review pulls from THREE buckets: explicit universal picks,
        // capability picks that map to a universal (also publish via
        // canonical path), and remaining non-universal capability picks
        // (legacy createInitialRules path). All three show as "ACUERDOS
        // QUE APLICAN" so the user sees one consolidated list.
        let universalById = Dictionary(uniqueKeysWithValues:
            coordinator.universalTemplates.map { ($0.id, $0) })
        let universalNames: [String] = coordinator.selectedUniversalTemplateIds
            .compactMap { universalById[$0]?.displayNameES }
        let capUniversalNames: [String] = coordinator.selectedCapabilityUniversalPublishes
            .compactMap { universalById[$0.universalTemplateId]?.displayNameES }
        let legacyNames: [String] = coordinator.nonUniversalSuggestedRules
            .filter { coordinator.isSuggestedRuleSelected(blockId: $0.block.id, slug: $0.template.slug) }
            .map(\.template.displayName)
        let allNames = (universalNames + capUniversalNames + legacyNames).sorted()
        if !allNames.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Acuerdos que aplican")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(allNames, id: \.self) { name in
                        HStack(alignment: .top, spacing: RuulSpacing.sm) {
                            Image(systemName: "circle.dashed.inset.filled")
                                .foregroundStyle(Color.ruulAccent)
                                .padding(.top, 2)
                            Text(name)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                            Spacer()
                        }
                        .padding(.horizontal, RuulSpacing.md)
                        .padding(.vertical, RuulSpacing.sm)
                        .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                    }
                }
            }
        }
    }

    /// Renders a basicFields value as a human-readable string for the
    /// review screen. Date/time values format as a localized date+time;
    /// numbers as plain digits; strings pass through.
    private func displayValue(for field: BuilderField) -> String {
        guard let value = coordinator.basicFields[field.key] else { return "—" }
        switch value {
        case .string(let s):
            if field.kind == .date || field.kind == .dateTime || field.kind == .time,
               let parsed = ISO8601DateFormatter().date(from: s) {
                return (field.kind == .date) ? parsed.ruulMediumDate : parsed.ruulMediumDateTime
            }
            return s.isEmpty ? "—" : s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .bool(let b):   return b ? "Sí" : "No"
        case .null:          return "—"
        case .array, .object: return "—"
        }
    }

    // MARK: - Toolbar / state helpers

    private var title: String {
        switch coordinator.step {
        case .typePicker: return "¿Qué quieres crear?"
        case .fields:     return coordinator.selectedBuilder?.displayName ?? "Nuevo"
        case .options:    return "Opciones"
        case .rules:      return "Reglas sugeridas"
        case .review:     return "Revisa y crea"
        }
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch coordinator.step {
        case .typePicker:
            Button("Cancelar") { dismiss() }
                .foregroundStyle(Color.secondary)
        case .fields, .options, .rules, .review:
            Button {
                coordinator.goBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Atrás")
                }
                .foregroundStyle(Color.secondary)
            }
        }
    }

    private var optionsAdvanceLabel: String {
        // When step 4 has nothing to show (no legacy capability rules AND
        // no universal templates apply), skip it — CTA goes to Revisar.
        coordinator.hasAnyRulesStepContent ? "Continuar a reglas" : "Revisar"
    }

    private var rulesAdvanceLabel: String {
        let count = coordinator.selectedSuggestedRules.count
        if count == 0 { return "Revisar (sin reglas)" }
        return "Revisar con \(count) regla\(count == 1 ? "" : "s")"
    }

    private var submitLabel: String {
        if coordinator.enabledCapabilities.isEmpty {
            return "Crear"
        }
        let rules = coordinator.selectedSuggestedRules.count
        if rules > 0 {
            return "Crear con \(coordinator.enabledCapabilities.count) opciones · \(rules) reglas"
        }
        return "Crear con \(coordinator.enabledCapabilities.count) opciones"
    }

    private func submit() async {
        let ok = await coordinator.submit()
        if ok {
            let id = coordinator.createdResourceId
            // Post-create: publish each selected universal template
            // scoped to the new resource. Failures don't block the
            // resource creation — caller already sees the resource;
            // we just don't dismiss until the publish loop completes
            // so the user knows their picks were processed.
            if let id { _ = await publishSelectedUniversals(resourceId: id) }
            await MainActor.run {
                if let id { onCreated?(id) }
                dismiss()
            }
        }
    }

    /// Looks up the active group's template via `TemplateRegistry`,
    /// pulls its `config.defaultCapabilities` map, and rebuilds the
    /// coordinator with both the real registry and the template-driven
    /// defaults. Falls back to an empty map when the template isn't
    /// available yet (offline / pre-auth) — wizard opens with nothing
    /// pre-toggled in that case, matching the safe-default behavior.
    private func rebuildCoordinatorWithTemplate() async {
        var defaults: [String: [String]] = [:]
        if let templateId = coordinator.group.baseTemplate,
           let template = await app.templateRegistry.template(id: templateId),
           let declared = template.config.defaultCapabilities {
            defaults = declared
        }
        let real = ResourceWizardCoordinator(
            group: coordinator.group,
            registry: app.resourceBuilders,
            defaultCapabilitiesByType: defaults,
            // Universal Beta-1 templates surfaced in step 4 above the
            // legacy capability-suggested rules. The coordinator filters
            // these by resource_type via compatibleUniversalTemplates(...).
            universalTemplates: app.ruleTemplatesForGallery
        )
        coordinator = real
    }

    /// Publishes each selected universal template scoped to the
    /// freshly-created resource. Called from `submit()` after
    /// `coordinator.submit()` succeeds. Two sources:
    ///   1. `selectedUniversalTemplateIds` — picks from the explicit
    ///      "PATRONES UNIVERSALES" section (uses universal's defaults).
    ///   2. `selectedCapabilityUniversalPublishes` — picks from the
    ///      legacy "POR CAPACIDAD" section that map to a universal
    ///      (UniversalRuleTemplates.md §14 Fase 2 — pipeline unification).
    ///      Capability-side defaults (e.g. amount=150) override the
    ///      universal's defaults so per-vertical tuning is preserved.
    /// Individual failures bubble up as a warning list; the resource
    /// itself is still created.
    private func publishSelectedUniversals(resourceId: UUID) async -> [String] {
        guard let repo = app.ruleTemplateRepo else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: coordinator.universalTemplates.map { ($0.id, $0) })
        var failures: [String] = []

        // 1. Explicit universal picks (UI section "PATRONES UNIVERSALES").
        for templateId in coordinator.selectedUniversalTemplateIds {
            guard let template = byId[templateId] else { continue }
            do {
                _ = try await repo.publishRuleVersion(
                    groupId: coordinator.group.id,
                    templateId: templateId,
                    shapeParams: template.defaultParams,
                    scope: .resource(resourceId),
                    title: template.displayNameES,
                    changeReason: "Activado al crear el recurso"
                )
            } catch {
                failures.append(template.displayNameES)
            }
        }

        // 2. Legacy capability picks mapped to a universal.
        for entry in coordinator.selectedCapabilityUniversalPublishes {
            guard let template = byId[entry.universalTemplateId] else { continue }
            let merged = mergedParams(universalDefaults: template.defaultParams, overrides: entry.defaultConfig)
            do {
                _ = try await repo.publishRuleVersion(
                    groupId: coordinator.group.id,
                    templateId: entry.universalTemplateId,
                    shapeParams: merged,
                    scope: .resource(resourceId),
                    title: template.displayNameES,
                    changeReason: "Activado al crear el recurso (desde capacidad)"
                )
            } catch {
                failures.append(template.displayNameES)
            }
        }
        return failures
    }

    /// Merges a CapabilityRuleOption's `defaultConfig` ([String:String])
    /// onto a universal template's `defaultParams` (JSONConfig.object).
    /// String values that parse as Int become `.int`; others become
    /// `.string`. Keys not in `overrides` keep the universal default.
    private func mergedParams(universalDefaults: JSONConfig, overrides: [String: String]) -> JSONConfig {
        var dict: [String: JSONConfig]
        if case .object(let existing) = universalDefaults {
            dict = existing
        } else {
            dict = [:]
        }
        for (key, rawValue) in overrides {
            if let asInt = Int(rawValue) {
                dict[key] = .int(asInt)
            } else {
                dict[key] = .string(rawValue)
            }
        }
        return .object(dict)
    }
}

// MARK: - WizardCategory

/// Six display categories shown as horizontal chips in the TypePicker step.
/// Types can appear in multiple categories (e.g. `.event` is in both
/// `.popular` and `.coordination`). The mapping is intentionally simple for
/// Pass 2; Pass 3 polish can refine based on telemetry or group template.
private enum WizardCategory: String, CaseIterable, Identifiable {
    case popular
    case coordination
    case money
    case sharedThings
    case governance
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .popular:      return "Populares"
        case .coordination: return "Coordinación"
        case .money:        return "Dinero"
        case .sharedThings: return "Cosas compartidas"
        case .governance:   return "Decisiones"
        case .custom:       return "Custom"
        }
    }

    var types: [ResourceType] {
        switch self {
        case .popular:      return [.event, .fund]
        case .coordination: return [.event, .slot]
        case .money:        return [.fund]
        case .sharedThings: return [.asset, .space]
        case .governance:   return [.right]
        case .custom:       return [.event, .fund, .asset, .space, .slot, .right]
        }
    }
}

// MARK: - WizardTypePicker

/// Step 1 of the ResourceWizard: categorized tile grid.
///
/// Renders a horizontal row of category chips (`WizardCategory`) and a
/// 2-column tile grid for the types in the selected category. Tiles for
/// types that don't yet have a registered builder appear disabled with a
/// "Próximamente" badge — consistent with the founder rule "Create Resource
/// must never lie."
///
/// Pass 2: `CapabilityResolver.creatableTypes(group:)` returns all 6
/// canonical types; the registry's `isImplemented(_:)` gates tappability.
private struct WizardTypePicker: View {
    let group: RuulCore.Group
    let registry: ResourceBuilderRegistry
    let onSelect: (ResourceType) -> Void

    @State private var selectedCategory: WizardCategory = .popular
    private let resolver = CapabilityResolver()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                categoryChips
                tileGrid
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
    }

    // MARK: Category chips

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.xs) {
                ForEach(WizardCategory.allCases) { cat in
                    chipButton(cat)
                }
            }
        }
    }

    private func chipButton(_ cat: WizardCategory) -> some View {
        Button {
            withAnimation(.smooth) { selectedCategory = cat }
        } label: {
            Text(cat.label)
                .font(.footnote)
                .padding(.horizontal, RuulSpacing.md)
                .padding(.vertical, RuulSpacing.xs)
                .background(
                    Capsule()
                        .fill(selectedCategory == cat
                              ? Color.ruulAccent
                              : Color.ruulSurface)
                )
                .foregroundStyle(selectedCategory == cat
                                 ? Color.ruulTextInverse
                                 : Color.secondary)
                .overlay(
                    Capsule()
                        .stroke(selectedCategory == cat
                                ? Color.clear
                                : Color(.separator),
                                lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .animation(.smooth, value: selectedCategory)
    }

    // MARK: Tile grid

    private var creatableSet: Set<ResourceType> {
        Set(resolver.creatableTypes(group: group))
    }

    private var typesInCategory: [ResourceType] {
        selectedCategory.types.filter { creatableSet.contains($0) }
    }

    private var tileGrid: some View {
        LazyVGrid(
            columns: [.init(.adaptive(minimum: 140), spacing: RuulSpacing.sm)],
            spacing: RuulSpacing.sm
        ) {
            ForEach(typesInCategory, id: \.self) { type in
                typeTile(type)
            }
        }
    }

    @ViewBuilder
    private func typeTile(_ type: ResourceType) -> some View {
        let chrome = ResourceTypeChrome.resolve(type)
        let implemented = registry.isImplemented(type)
        if implemented {
            Button {
                onSelect(type)
            } label: {
                tileContent(type: type, chrome: chrome, isImplemented: true)
            }
            .buttonStyle(.plain)
        } else {
            tileContent(type: type, chrome: chrome, isImplemented: false)
                .accessibilityLabel("\(type.humanLabel), próximamente")
                .accessibilityHint("Este recurso aún no se puede crear.")
                .accessibilityAddTraits(.isStaticText)
                .allowsHitTesting(false)
                .opacity(0.50)
        }
    }

    private func tileContent(type: ResourceType, chrome: ResourceTypeChrome, isImplemented: Bool) -> some View {
        VStack(spacing: RuulSpacing.xs) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: chrome.symbol)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(isImplemented ? chrome.semanticColor : Color(.tertiaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isImplemented {
                    Text("Pronto")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                }
            }
            Text(type.humanLabel)
                .font(.footnote)
                .foregroundStyle(isImplemented ? Color.primary : Color(.tertiaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .padding(RuulSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }
}
