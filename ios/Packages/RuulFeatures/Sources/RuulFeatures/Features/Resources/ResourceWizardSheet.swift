import SwiftUI
import RuulUI
import RuulCore

/// Universal ResourceWizard sheet. Three-step flow that handles every
/// resource type the registry knows about via a single set of UI
/// components (TypePicker / BuilderFieldRenderer / CapabilityToggleList).
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
                        if coordinator.step == .options {
                            Button("Crear") {
                                Task { await submit() }
                            }
                            .disabled(!coordinator.canSubmit)
                        }
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
                    HStack(spacing: RuulSpacing.sm) {
                        RuulButton(
                            "Crear así",
                            style: .glass,
                            size: .large,
                            fillsWidth: true,
                            action: {
                                Task { await submit() }
                            }
                        )
                        .disabled(!coordinator.canAdvanceFromFields)
                        RuulButton(
                            "Más opciones",
                            style: .primary,
                            size: .large,
                            fillsWidth: true,
                            action: { coordinator.advanceFromFields() }
                        )
                        .disabled(!coordinator.canAdvanceFromFields || coordinator.availableCapabilityBlocks.isEmpty)
                    }
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
                Text("Capacidades")
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
                    submitLabel,
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

    private var emptyCapabilitiesView: some View {
        VStack(spacing: RuulSpacing.sm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(Color.ruulTextSecondary)
            Text("No hay opciones extra para este tipo.")
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

    // MARK: - Toolbar / state helpers

    private var title: String {
        switch coordinator.step {
        case .typePicker: return "¿Qué quieres crear?"
        case .fields:     return coordinator.selectedBuilder?.displayName ?? "Nuevo"
        case .options:    return "Opciones"
        }
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch coordinator.step {
        case .typePicker:
            Button("Cancelar") { dismiss() }
                .foregroundStyle(Color.ruulTextSecondary)
        case .fields, .options:
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

    private var submitLabel: String {
        if coordinator.enabledCapabilities.isEmpty {
            return "Crear"
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
