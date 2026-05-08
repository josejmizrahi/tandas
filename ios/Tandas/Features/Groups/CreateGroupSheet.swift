import SwiftUI
import OSLog
import RuulUI

/// Minimal "create another group" flow for users who already have a group.
/// Skips identity / templateSelect / vocabulary / rules / invite / OTP since
/// the user is already authed and we use the dinner_recurring template
/// defaults (5 platform rules seeded automatically).
///
/// Just asks for a group name (and optional cover) and ships it.
struct CreateGroupSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var coverImageName: String?
    @State private var isSubmitting: Bool = false
    @State private var error: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "groups.create")

    var onCreated: (Group) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    header
                    nameField
                    if let error {
                        Text(error)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulNegative)
                    }
                    RuulButton(
                        "Crear grupo",
                        style: .primary,
                        size: .large,
                        isLoading: isSubmitting,
                        fillsWidth: true,
                        action: submit
                    )
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
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
                    Text("Nuevo grupo")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("¿Cómo se llama tu grupo?")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Usaremos plantilla de cena recurrente con las 5 reglas por defecto. Podrás editarlas después.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var nameField: some View {
        RuulTextField(
            "Ej: Cena de los miércoles",
            text: $name,
            label: "Nombre del grupo"
        )
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { Task { @MainActor in isSubmitting = false } }
            do {
                var draft = GroupDraft.empty
                draft.name = trimmed
                draft.template = TemplateRegistry.dinnerRecurringId
                draft.coverImageName = coverImageName
                let group = try await app.groupsRepo.createInitial(draft)
                // Seed the 5 platform rules so the rule engine fires for this
                // group too. Idempotent — skips if already platform-shape.
                _ = try? await app.ruleRepo.seedDinnerTemplateRules(groupId: group.id)
                await app.refreshProfileAndGroups()
                await MainActor.run {
                    app.activeGroupId = group.id
                    dismiss()
                    onCreated(group)
                }
            } catch {
                log.warning("create group failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.error = "No pudimos crear el grupo: \(error.localizedDescription)"
                }
            }
        }
    }
}
