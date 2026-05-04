import SwiftUI
import OSLog

/// Admin-only sheet to edit a group's runtime configuration. Mirrors the
/// fields the founder onboarding sets (vocabulary, fines on/off, rotation
/// mode) so admins can change those once-set defaults later. Backed by
/// `update_group_config` RPC — no schema changes needed.
///
/// Out of scope for V1: editing group name (no RPC), editing cover image
/// (needs cover picker UI), editing frequency_type / frequency_config
/// (richer date/time UI), member management (kick / promote), regenerating
/// invite code, deleting / archiving the group. All deferred to V1.5.
struct GroupSettingsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let group: Group

    @State private var eventLabel: String = ""
    @State private var finesEnabled: Bool = true
    @State private var rotationMode: RotationMode = .autoOrder
    @State private var isSaving: Bool = false
    @State private var error: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "groups.settings")

    var onSaved: ((Group) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s6) {
                    vocabularySection
                    finesSection
                    rotationSection
                    if let error {
                        Text(error)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulSemanticError)
                    }
                    saveButton
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.top, RuulSpacing.s5)
                .padding(.bottom, RuulSpacing.s7)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.ruulBackgroundCanvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Editar grupo")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackgroundCanvas, for: .navigationBar)
        }
        .onAppear { hydrateFromGroup() }
    }

    // MARK: - Sections

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            sectionLabel("VOCABULARIO")
            Text("Cómo le llamás a los eventos del grupo. Aparece en todos los textos.")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
            RuulTextField(
                "ej: cena",
                text: $eventLabel,
                label: "Palabra"
            )
        }
    }

    private var finesSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            sectionLabel("MULTAS")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aplicar multas")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(finesEnabled
                         ? "Las reglas activas generan multas automáticamente."
                         : "Las reglas se evalúan pero no se cobran.")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                Toggle("", isOn: $finesEnabled)
                    .labelsHidden()
                    .tint(Color.ruulAccentPrimary)
            }
            .padding(RuulSpacing.s4)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 1)
            )
        }
    }

    private var rotationSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            sectionLabel("ANFITRIÓN")
            RuulSegmentedControl(
                selection: $rotationMode,
                segments: RotationMode.allCases.map { ($0, segmentLabel(for: $0)) }
            )
            Text(rotationMode.description)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private func segmentLabel(for mode: RotationMode) -> String {
        switch mode {
        case .autoOrder: return "Auto"
        case .manual:    return "Manual"
        case .noHost:    return "Sin"
        }
    }

    private var saveButton: some View {
        RuulButton(
            "Guardar cambios",
            style: .primary,
            size: .large,
            isLoading: isSaving,
            fillsWidth: true,
            action: save
        )
        .disabled(!hasChanges)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .ruulTextStyle(RuulTypography.footnote)
            .foregroundStyle(Color.ruulTextSecondary)
            .padding(.leading, RuulSpacing.s1)
    }

    private var hasChanges: Bool {
        let trimmed = eventLabel.trimmingCharacters(in: .whitespaces)
        return trimmed != group.eventVocabulary
            || finesEnabled != group.finesEnabled
            || rotationMode != group.rotationMode
    }

    private func hydrateFromGroup() {
        eventLabel = group.eventVocabulary
        finesEnabled = group.finesEnabled
        rotationMode = group.rotationMode
    }

    private func save() {
        guard hasChanges, !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            defer { Task { @MainActor in isSaving = false } }
            let trimmed = eventLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let patch = GroupConfigPatch(
                eventLabel: trimmed.isEmpty ? nil : trimmed,
                finesEnabled: finesEnabled,
                rotationMode: rotationMode
            )
            do {
                let updated = try await app.groupsRepo.updateConfig(groupId: group.id, patch: patch)
                await app.refreshProfileAndGroups()
                await MainActor.run {
                    onSaved?(updated)
                    dismiss()
                }
            } catch {
                log.warning("update group config failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.error = "No pudimos guardar los cambios: \(error.localizedDescription)"
                }
            }
        }
    }
}
