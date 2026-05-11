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
                .background(Color.ruulBackground.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        leadingButton
                    }
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // Inline CTA lives at the bottom of each step;
                        // toolbar slot reserved for utility (e.g.
                        // "Saltar" on the suggested rules step).
                        EmptyView()
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color.ruulBackground, for: .navigationBar)
                .animation(.ruulSnappy, value: coordinator.step)
        }
        .onAppear {
            // Reseat coordinator with the real registry from AppState.
            let real = ResourceWizardCoordinator(
                group: coordinator.group,
                registry: app.resourceBuilders
            )
            coordinator = real
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.step {
        case .typePicker:
            ResourceTypePickerView(registry: coordinator.registry) { _, builder in
                coordinator.selectBuilder(builder)
            }
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
                    headerForBuilder(builder)
                    ForEach(Array(builder.requiredFields.enumerated()), id: \.offset) { _, field in
                        BuilderFieldRenderer(
                            field: field,
                            values: Binding(
                                get: { coordinator.basicFields },
                                set: { coordinator.basicFields = $0 }
                            )
                        )
                    }
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

    private func headerForBuilder(_ builder: any ResourceBuilder) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.ruulAccent.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: builder.icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.ruulAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(builder.displayName)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(builder.summary)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }

    // MARK: - Step 3: Options

    @ViewBuilder
    private var optionsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                Text("¿Qué más quieres que pase?")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
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
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulNegative)
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
                .font(.system(size: 32))
                .foregroundStyle(Color.ruulTextSecondary)
            Text("Listo, no necesitas configurar nada más.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xl)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
    }

    private func capabilityRow(for block: any CapabilityBlock) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: RuulSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.displayName)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(block.summary)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
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
            // Inline config sub-card: shown when the capability is on and
            // has tunable parameters. V1 only the recurrence block has this.
            if coordinator.isCapabilityEnabled(block.id), block.id == "recurrence" {
                Divider().padding(.horizontal, RuulSpacing.md)
                recurrenceInlineConfig
                    .padding(RuulSpacing.md)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(Color.ruulSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 1)
        )
    }

    private var recurrenceInlineConfig: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Frecuencia")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                Picker("Frecuencia", selection: Binding(
                    get: { coordinator.recurrenceFrequency },
                    set: { coordinator.recurrenceFrequency = $0 }
                )) {
                    Text("Semanal").tag("weekly")
                    Text("Cada 2 semanas").tag("biweekly")
                    Text("Mensual").tag("monthly")
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Día")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                Picker("Día", selection: Binding(
                    get: { coordinator.recurrenceDayOfWeek },
                    set: { coordinator.recurrenceDayOfWeek = $0 }
                )) {
                    Text("Dom").tag(0)
                    Text("Lun").tag(1)
                    Text("Mar").tag(2)
                    Text("Mié").tag(3)
                    Text("Jue").tag(4)
                    Text("Vie").tag(5)
                    Text("Sáb").tag(6)
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Hora")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                DatePicker(
                    "Hora",
                    selection: Binding(
                        get: {
                            var comps = DateComponents()
                            comps.hour = coordinator.recurrenceHour
                            comps.minute = coordinator.recurrenceMinute
                            return Calendar.current.date(from: comps) ?? .now
                        },
                        set: { newDate in
                            let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                            coordinator.recurrenceHour = comps.hour ?? 20
                            coordinator.recurrenceMinute = comps.minute ?? 0
                        }
                    ),
                    displayedComponents: [.hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
            }
        }
    }

    // MARK: - Step 4: Rules (suggested rules per enabled capability)

    @ViewBuilder
    private var rulesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                Text("Estos acuerdos van con las capacidades que escogiste. Apaga lo que no quieras.")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .padding(.leading, RuulSpacing.xxs)
                rulesByCapability
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

    @ViewBuilder
    private var rulesByCapability: some View {
        // Group templates by their owning block.id so the user sees a
        // section per capability — "RSVP / Multas / etc." — with the
        // toggleable rule rows nested under each header.
        let grouped = Dictionary(grouping: coordinator.availableSuggestedRules, by: { $0.block.id })
        // Preserve the catalog order (availableCapabilityBlocks) instead
        // of the dictionary's arbitrary order.
        let orderedBlocks = coordinator.availableCapabilityBlocks
            .filter { coordinator.isCapabilityEnabled($0.id) && grouped[$0.id] != nil }
        ForEach(orderedBlocks, id: \.id) { block in
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text(block.displayName.uppercased())
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(grouped[block.id] ?? [], id: \.template.slug) { pair in
                        suggestedRuleRow(block: pair.block, template: pair.template)
                    }
                }
            }
        }
    }

    private func suggestedRuleRow(block: any CapabilityBlock, template: RuleTemplate) -> some View {
        let isOn = coordinator.isSuggestedRuleSelected(blockId: block.id, slug: template.slug)
        return HStack(alignment: .top, spacing: RuulSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.displayName)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(template.summary)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
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
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
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
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulNegative)
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
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.large)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    private func reviewFields(builder: any ResourceBuilder) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("DETALLES")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(spacing: 0) {
                ForEach(Array(builder.requiredFields.enumerated()), id: \.offset) { idx, field in
                    HStack(alignment: .firstTextBaseline) {
                        Text(field.label)
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulTextSecondary)
                        Spacer()
                        Text(displayValue(for: field))
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(RuulSpacing.md)
                    if idx < builder.requiredFields.count - 1 {
                        Divider().padding(.leading, RuulSpacing.md)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func reviewCapabilities() -> some View {
        let enabled = coordinator.availableCapabilityBlocks
            .filter { coordinator.isCapabilityEnabled($0.id) }
        if !enabled.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("OPCIONES ACTIVAS")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(enabled, id: \.id) { block in
                        HStack(spacing: RuulSpacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.ruulAccent)
                            Text(block.displayName)
                                .ruulTextStyle(RuulTypography.body)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, RuulSpacing.md)
                        .padding(.vertical, RuulSpacing.sm)
                        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func reviewRules() -> some View {
        let selected = coordinator.availableSuggestedRules.filter { pair in
            coordinator.isSuggestedRuleSelected(blockId: pair.block.id, slug: pair.template.slug)
        }
        if !selected.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("ACUERDOS QUE APLICAN")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(selected, id: \.template.slug) { pair in
                        HStack(alignment: .top, spacing: RuulSpacing.sm) {
                            Image(systemName: "circle.dashed.inset.filled")
                                .foregroundStyle(Color.ruulAccent)
                                .padding(.top, 2)
                            Text(pair.template.displayName)
                                .ruulTextStyle(RuulTypography.body)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, RuulSpacing.md)
                        .padding(.vertical, RuulSpacing.sm)
                        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
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
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "es_MX")
                formatter.dateStyle = .medium
                formatter.timeStyle = (field.kind == .date) ? .none : .short
                return formatter.string(from: parsed)
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
        case .rules:      return "Acuerdos sugeridos"
        case .review:     return "Revisa y crea"
        }
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch coordinator.step {
        case .typePicker:
            Button("Cancelar") { dismiss() }
                .foregroundStyle(Color.ruulTextSecondary)
        case .fields, .options, .rules, .review:
            Button {
                coordinator.goBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Atrás")
                }
                .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }

    private var optionsAdvanceLabel: String {
        // When no enabled capability has suggested rules, step 4 is
        // skipped — the CTA goes straight to review.
        coordinator.hasAnySuggestedRules ? "Continuar a acuerdos" : "Revisar"
    }

    private var rulesAdvanceLabel: String {
        let count = coordinator.selectedSuggestedRules.count
        if count == 0 { return "Revisar (sin acuerdos)" }
        return "Revisar con \(count) acuerdo\(count == 1 ? "" : "s")"
    }

    private var submitLabel: String {
        if coordinator.enabledCapabilities.isEmpty {
            return "Crear"
        }
        let rules = coordinator.selectedSuggestedRules.count
        if rules > 0 {
            return "Crear con \(coordinator.enabledCapabilities.count) opciones · \(rules) acuerdos"
        }
        return "Crear con \(coordinator.enabledCapabilities.count) opciones"
    }

    private func submit() async {
        let ok = await coordinator.submit()
        if ok {
            let id = coordinator.createdResourceId
            await MainActor.run {
                if let id { onCreated?(id) }
                dismiss()
            }
        }
    }
}
