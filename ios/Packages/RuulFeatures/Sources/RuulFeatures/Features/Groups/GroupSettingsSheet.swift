import SwiftUI
import OSLog
import RuulUI
import RuulCore

/// Admin-only sheet to edit a group's runtime configuration. Mirrors the
/// fields the founder onboarding sets (vocabulary, fines on/off, rotation
/// mode) so admins can change those once-set defaults later. Backed by
/// `update_group_config` RPC — no schema changes needed.
///
/// Out of scope for V1: editing group name (no RPC), editing cover image
/// (needs cover picker UI), editing frequency_type / frequency_config
/// (richer date/time UI), member management (kick / promote), regenerating
/// invite code, deleting / archiving the group. All deferred to V1.5.
public struct GroupSettingsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let group: RuulCore.Group

    @State private var eventLabel: String = ""
    @State private var finesEnabled: Bool = true
    @State private var rotationMode: RotationMode = .autoOrder
    @State private var isSaving: Bool = false
    @State private var error: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "groups.settings")

    public var onSaved: ((RuulCore.Group) -> Void)?

    public init(group: RuulCore.Group, onSaved: ((RuulCore.Group) -> Void)? = nil) {
        self.group = group
        self.onSaved = onSaved
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    vocabularySection
                    finesSection
                    rotationSection
                    if let error {
                        Text(error)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulNegative)
                    }
                    saveButton
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
                    Text("Editar grupo")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
        .onAppear { hydrateFromGroup() }
    }

    // MARK: - Sections

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
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
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
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
    }

    private var rotationSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
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
            .padding(.leading, RuulSpacing.xxs)
    }

    private var hasChanges: Bool {
        let trimmed = eventLabel.trimmingCharacters(in: .whitespaces)
        return trimmed != group.eventVocabulary
            || finesEnabled != app.capabilityResolver.finesEnabled(in: group)
            || rotationMode != group.rotationMode
    }

    private func hydrateFromGroup() {
        eventLabel = group.eventVocabulary
        finesEnabled = app.capabilityResolver.finesEnabled(in: group)
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
