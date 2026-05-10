import SwiftUI
import RuulUI
import RuulCore

/// Progressive opt-in resource creation per OpenPlatform Taxonomy §7.
///
/// Single-screen wizard with two surfaces:
///   1. Required fields (title + date) + "Crear así" CTA — the 30-second
///      path the founder spec called out as the floor.
///   2. Collapsible "Opciones" panel with toggles for the V1 capability
///      blocks available to this group (resolver-gated).
///
/// V1 scope: event resources only. Phase 2 adds slot / fund / asset
/// builders + a resource-type picker step.
public struct ResourceWizardSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator: ResourceWizardCoordinator
    @State private var showAdvanced: Bool = false

    public var onCreated: ((UUID) -> Void)?

    public init(group: RuulCore.Group, suggestedDate: Date = .now.addingTimeInterval(86_400), onCreated: ((UUID) -> Void)? = nil) {
        self.onCreated = onCreated
        let catalog = CapabilityCatalog.v1
        let resolver = CapabilityResolver(modules: .v1Fallback)
        let availableIds = resolver.availableCapabilities(for: .event, in: group, catalog: catalog)
        let availableBlocks = availableIds.compactMap { catalog[$0] }
        // Phase-1 default: enable the V1 dinner stack (rsvp, check_in,
        // rotation) if those modules are active. Multas + reglas + appeal
        // start OFF — the user opts in explicitly.
        var defaultEnabled: Set<String> = []
        for id in ["rsvp", "check_in", "rotation"] where availableIds.contains(id) {
            defaultEnabled.insert(id)
        }
        // Note: we can't read AppState here yet (Environment isn't bound
        // until body runs), so we construct with placeholders and replace
        // the builder onAppear if needed. Simpler: pass nil-builder
        // placeholder and reseat. Since EventResourceBuilder needs
        // injected repos, we recreate the coord in onAppear with the
        // real builder.
        _coordinator = State(initialValue: ResourceWizardCoordinator(
            group: group,
            suggestedDate: suggestedDate,
            availableCapabilities: availableBlocks,
            builder: EventResourceBuilder(
                eventRepo: MockEventRepository(),  // replaced in onAppear
                ruleRepo: MockRuleRepository()
            ),
            defaultEnabled: defaultEnabled
        ))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    requiredSection
                    advancedSection
                    if let error = coordinator.error {
                        Text(error)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulNegative)
                    }
                    submitButton
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.ruulBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Crear evento")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
        .onAppear {
            // Rebuild the coordinator with the real injected builder from
            // AppState now that the environment is bound. State already
            // captured title/startsAt/enabledCapabilities defaults.
            let realBuilder = app.eventBuilder
            coordinator = ResourceWizardCoordinator(
                group: coordinator.group,
                suggestedDate: coordinator.startsAt,
                availableCapabilities: coordinator.availableCapabilities,
                builder: realBuilder,
                defaultEnabled: coordinator.enabledCapabilities
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var requiredSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            RuulTextField(
                "ej: Cena del jueves",
                text: Binding(
                    get: { coordinator.title },
                    set: { coordinator.title = $0 }
                ),
                label: "Título"
            )
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Fecha y hora")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                RuulDatePicker(
                    "Fecha",
                    date: Binding(
                        get: { coordinator.startsAt },
                        set: { coordinator.startsAt = $0 }
                    ),
                    components: [.date, .hourAndMinute]
                )
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        if !coordinator.availableCapabilities.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.md) {
                Button {
                    withAnimation { showAdvanced.toggle() }
                } label: {
                    HStack {
                        Text(showAdvanced ? "Ocultar opciones" : "Más opciones")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulAccent)
                        Spacer()
                        Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                            .foregroundStyle(Color.ruulAccent)
                    }
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                        Text("Capacidades")
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .padding(.leading, RuulSpacing.xxs)
                        ForEach(coordinator.availableCapabilities, id: \.id) { block in
                            capabilityRow(for: block)
                        }
                    }
                }
            }
        }
    }

    private func capabilityRow(for block: any CapabilityBlock) -> some View {
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
                get: { coordinator.isEnabled(block.id) },
                set: { _ in coordinator.toggleCapability(block.id) }
            ))
            .labelsHidden()
            .tint(Color.ruulAccent)
        }
        .padding(RuulSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(Color.ruulSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 1)
        )
    }

    private var submitButton: some View {
        RuulButton(
            submitLabel,
            style: .primary,
            size: .large,
            isLoading: coordinator.isCreating,
            fillsWidth: true,
            action: {
                Task {
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
        )
        .disabled(!coordinator.canSubmit)
    }

    private var submitLabel: String {
        if coordinator.enabledCapabilities.isEmpty {
            return "Crear así"
        }
        return "Crear con \(coordinator.enabledCapabilities.count) opciones"
    }
}
