import SwiftUI
import OSLog
import RuulUI
import RuulCore

/// Admin-only sheet to edit a group's runtime configuration.
///
/// Post BigBang the group is bare. Settings reduces to: vocabulary
/// (settings.eventVocabulary) + module toggles (basic_fines etc.). Rotation,
/// frequency, fund, fines configs all migrate to capability blocks /
/// module config / ResourceSeries — those flows live elsewhere (Phase 2+).
public struct GroupSettingsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let group: RuulCore.Group

    @State private var eventLabel: String = ""
    @State private var finesEnabled: Bool = true
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
    }

    private func hydrateFromGroup() {
        eventLabel = group.eventVocabulary
        finesEnabled = app.capabilityResolver.finesEnabled(in: group)
    }

    private func save() {
        guard hasChanges, !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            defer { Task { @MainActor in isSaving = false } }
            let trimmed = eventLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let priorFinesEnabled = app.capabilityResolver.finesEnabled(in: group)
            let patch = GroupConfigPatch(
                initialEventVocabulary: trimmed.isEmpty ? nil : trimmed
            )
            do {
                var updated = try await app.groupsRepo.updateConfig(groupId: group.id, patch: patch)
                if finesEnabled != priorFinesEnabled {
                    // Governance gate (mig 00113). Default policy is
                    // admin_only, so non-admins see a soft block; founders
                    // / custom admin roles proceed. vote_required isn't
                    // produceable by the seeder today — V2 adds an apply
                    // path for capability toggles via vote.
                    let decision: PolicyDecision
                    do {
                        decision = try await app.policyRepo.resolve(
                            groupId: group.id,
                            actorUserId: app.session?.user.id ?? UUID(),
                            action: .capabilityEnable,
                            targetPayload: ["capability_slug": GroupModule.basicFines.id]
                        )
                    } catch {
                        // Resolver unreachable — fall back to the existing
                        // set_group_module RLS so the primary path stays
                        // usable under network blips.
                        decision = .allowed
                    }
                    switch decision {
                    case .allowed:
                        updated = try await app.groupsRepo.setModule(
                            groupId: group.id,
                            slug: GroupModule.basicFines.id,
                            enabled: finesEnabled
                        )
                    case .adminOnly:
                        throw CapabilityGovernanceError.adminOnly
                    case .voteRequired:
                        throw CapabilityGovernanceError.voteRequired
                    case .denied(let reason):
                        throw CapabilityGovernanceError.denied(reason: reason)
                    }
                }
                await app.refreshProfileAndGroups()
                await MainActor.run {
                    onSaved?(updated)
                    dismiss()
                }
            } catch CapabilityGovernanceError.adminOnly {
                await MainActor.run {
                    self.error = "Solo los admins pueden activar o desactivar capabilities en este grupo."
                }
            } catch CapabilityGovernanceError.voteRequired {
                await MainActor.run {
                    self.error = "Este grupo requiere votación para activar capabilities. La flow llega en una próxima versión."
                }
            } catch CapabilityGovernanceError.denied(let reason) {
                await MainActor.run {
                    self.error = "No se puede cambiar esta capability: \(reason)."
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

/// Sentinel errors used by `GroupSettingsSheet.save` to bridge a
/// PolicyDecision outcome into the existing `do/catch` flow — keeps
/// each branch's user-facing copy local to the catch block.
private enum CapabilityGovernanceError: Error {
    case adminOnly
    case voteRequired
    case denied(reason: String)
}
