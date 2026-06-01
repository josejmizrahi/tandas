import SwiftUI
import RuulCore

/// Form-based editor for `groups.decision_rules`. Bound to
/// `DecisionRulesStore`; the View doesn't own the draft state.
struct EditDecisionRulesView: View {
    @Bindable var store: DecisionRulesStore
    let groupId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving: Bool = false
    @State private var quorumEnabled: Bool = false
    @State private var quorumValue: Int = 2
    // M1 motor avanzado
    @State private var isMotorExpanded: Bool = false
    @State private var thresholdEnabled: Bool = false
    @State private var thresholdValue: Double = 60
    @State private var quorumPctEnabled: Bool = false
    @State private var quorumPctValue: Double = 50
    @State private var durationEnabled: Bool = false
    @State private var durationHours: Int = 168

    private var durationLabel: String {
        if durationHours % 24 == 0 {
            return "\(durationHours / 24) días"
        }
        return "\(durationHours) horas"
    }

    var body: some View {
        NavigationStack {
            Form {
                // V2-G2 sub-slice 8 — canonical method + legitimacy live
                // here (group-level config). Per-decision sheets pick
                // these as defaults when proposing.
                Section {
                    ForEach(DecisionMethod.selectable) { method in
                        methodRow(method)
                    }
                } header: {
                    Text(L10n.DecisionRules.methodSection)
                } footer: {
                    Text(L10n.DecisionRules.methodFooter)
                }

                Section {
                    ForEach(LegitimacySource.selectable) { source in
                        legitimacyRow(source)
                    }
                } header: {
                    Text(L10n.DecisionRules.legitimacySection)
                } footer: {
                    Text(L10n.DecisionRules.legitimacyFooter)
                }

                Section(L10n.DecisionRules.quorumSection) {
                    Toggle(isOn: $quorumEnabled) {
                        Text(L10n.DecisionRules.quorumLabel)
                    }
                    if quorumEnabled {
                        Stepper(value: $quorumValue, in: 1...50) {
                            Text("\(quorumValue) miembros")
                                .monospacedDigit()
                        }
                    }
                }

                // M1 — Motor de decisiones potente. 3 controles avanzados
                // + auto-close toggle. Section colapsable para no asustar
                // en first-time edit; solo aplica a método majority/
                // supermajority (otros usan tally rules diferentes).
                Section {
                    DisclosureGroup("Motor avanzado", isExpanded: $isMotorExpanded) {
                        Toggle(isOn: $thresholdEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Umbral personalizado")
                                    .font(.body.weight(.medium))
                                Text("Override del 50.01% / 66.66% por defecto")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if thresholdEnabled {
                            HStack {
                                Text("\(Int(thresholdValue.rounded()))%")
                                    .font(.body.monospacedDigit())
                                    .frame(width: 50, alignment: .leading)
                                Slider(value: $thresholdValue, in: 1...100, step: 1)
                            }
                        }

                        Toggle(isOn: $quorumPctEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quórum como %")
                                    .font(.body.weight(.medium))
                                Text("Porcentaje de miembros activos (en vez de count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if quorumPctEnabled {
                            HStack {
                                Text("\(Int(quorumPctValue.rounded()))%")
                                    .font(.body.monospacedDigit())
                                    .frame(width: 50, alignment: .leading)
                                Slider(value: $quorumPctValue, in: 1...100, step: 1)
                            }
                        }

                        Toggle(isOn: $durationEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Duración default")
                                    .font(.body.weight(.medium))
                                Text("Horas antes de cerrar por timeout (default 7d)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if durationEnabled {
                            Stepper(value: $durationHours, in: 1...720, step: 1) {
                                Text(durationLabel)
                                    .monospacedDigit()
                            }
                        }

                        Toggle(isOn: $store.draftAutoClose) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cerrar al alcanzar umbral")
                                    .font(.body.weight(.medium))
                                Text("Si el quórum y el umbral se alcanzan, la decisión se cierra automáticamente sin esperar el timeout. Solo aplica a método majority/supermajority.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Los ajustes avanzados aplican como defaults a nuevas decisiones. Las decisiones existentes mantienen el umbral con el que se crearon.")
                        .font(.caption)
                }

                Section(L10n.DecisionRules.notesSection) {
                    TextField(
                        String(localized: L10n.DecisionRules.notesPlaceholder),
                        text: $store.draftNotes,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                historySection
            }
            .navigationTitle(L10n.DecisionRules.editTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearError()
                        dismiss()
                    } label: {
                        Text(L10n.DecisionRules.cancel)
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
                            Text(L10n.DecisionRules.save)
                        }
                    }
                    .disabled(!store.canSaveDraft || isSaving)
                }
            }
            .onAppear {
                if let q = store.draftQuorum {
                    quorumEnabled = true
                    quorumValue = max(1, q)
                } else {
                    quorumEnabled = false
                    quorumValue = 2
                }
                // M1 — hydrate motor draft state from store.
                if let t = store.draftThresholdPct {
                    thresholdEnabled = true
                    thresholdValue = t
                    isMotorExpanded = true
                }
                if let q = store.draftQuorumPct {
                    quorumPctEnabled = true
                    quorumPctValue = q
                    isMotorExpanded = true
                }
                if let d = store.draftDurationHours {
                    durationEnabled = true
                    durationHours = d
                    isMotorExpanded = true
                }
                if store.draftAutoClose {
                    isMotorExpanded = true
                }
            }
            .task { await store.refreshHistory(groupId: groupId) }
            .onChange(of: quorumEnabled) { _, enabled in
                store.draftQuorum = enabled ? quorumValue : nil
            }
            .onChange(of: quorumValue) { _, value in
                if quorumEnabled { store.draftQuorum = value }
            }
            .onChange(of: thresholdEnabled) { _, enabled in
                store.draftThresholdPct = enabled ? thresholdValue : nil
            }
            .onChange(of: thresholdValue) { _, value in
                if thresholdEnabled { store.draftThresholdPct = value }
            }
            .onChange(of: quorumPctEnabled) { _, enabled in
                store.draftQuorumPct = enabled ? quorumPctValue : nil
            }
            .onChange(of: quorumPctValue) { _, value in
                if quorumPctEnabled { store.draftQuorumPct = value }
            }
            .onChange(of: durationEnabled) { _, enabled in
                store.draftDurationHours = enabled ? durationHours : nil
            }
            .onChange(of: durationHours) { _, value in
                if durationEnabled { store.draftDurationHours = value }
            }
            .alert(
                "Se abrió una votación",
                isPresented: governanceDecisionOpenedBinding,
                presenting: governanceDecisionOpenedFromOutcome
            ) { _ in
                Button("Entendido", role: .cancel) {
                    store.clearGovernanceOutcome()
                    dismiss()
                }
            } message: { _ in
                Text("Cambiar las reglas de decisión del grupo es una decisión constitucional. Se aplicará cuando pase la votación.")
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var governanceDecisionOpenedBinding: Binding<Bool> {
        Binding(
            get: { governanceDecisionOpenedFromOutcome != nil },
            set: { newValue in
                if !newValue { store.clearGovernanceOutcome() }
            }
        )
    }

    private var governanceDecisionOpenedFromOutcome: DecisionOpenedDetails? {
        if case .decisionOpened(let details) = store.lastGovernanceOutcome {
            return details
        }
        return nil
    }

    @ViewBuilder
    private func methodRow(_ method: DecisionMethod) -> some View {
        Button {
            store.draftMethod = method
        } label: {
            optionRowContent(
                systemImage: method.systemImageName,
                label: method.label,
                subtitle: method.subtitle,
                isSelected: store.draftMethod == method
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func legitimacyRow(_ source: LegitimacySource) -> some View {
        Button {
            store.draftLegitimacySource = source
        } label: {
            optionRowContent(
                systemImage: source.systemImageName,
                label: source.label,
                subtitle: source.subtitle,
                isSelected: store.draftLegitimacySource == source
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func optionRowContent(
        systemImage: String,
        label: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        isSelected: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await store.saveDraft(groupId: groupId)
        if ok { dismiss() }
    }

    // MARK: - V3 PARTE 7c — Historial

    /// Doctrina situational: invisible cuando hay 0 versions guardadas
    /// (grupos pre-PARTE 7 nunca llamaron set_decision_rules y empiezan
    /// con jsonb '{}'); también invisible si solo hay 1 version (no hay
    /// nada a comparar todavía). El loading-skeleton SI se muestra
    /// brevemente.
    @ViewBuilder
    private var historySection: some View {
        if store.isHistoryLoading && store.history.isEmpty {
            Section("Historial") {
                ProgressView()
            }
        } else if store.history.count > 1 {
            Section("Historial") {
                ForEach(store.history) { version in
                    historyRow(version)
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ version: GroupGovernanceVersion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if version.isActive {
                    Text("Vigente")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.green.opacity(0.18)))
                        .foregroundStyle(.green)
                }
                Text(version.effectiveFrom.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let method = version.snapshot.defaultMethod {
                Text(method.label)
                    .font(.body.weight(.medium))
            }
            HStack(spacing: 8) {
                if let q = version.snapshot.quorumMin {
                    Label("Quórum: \(q)", systemImage: "person.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let actor = version.setByDisplayName, !actor.isEmpty {
                    Label(actor, systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
