import SwiftUI
import OSLog
import RuulUI
import RuulCore

/// Minimal "create another group" flow for users who already have a group.
/// Skips identity / templateSelect / vocabulary / rules / invite / OTP since
/// the user is already authed. The group is created blank — no template,
/// no preset rules. Vocabulary / modules / rules are added on demand
/// per `doctrine: "template = preset inicial, no es cárcel"` (CLAUDE.md).
public struct CreateGroupSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var coverImageName: String?
    @State private var isSubmitting: Bool = false
    @State private var error: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "groups.create")

    public var onCreated: (RuulCore.Group) -> Void

    public init(onCreated: @escaping (RuulCore.Group) -> Void) {
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    header
                    nameField
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.red)
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
            .ruulSheetToolbar("Nuevo grupo")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("¿Cómo se llama tu grupo?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("Lo arrancamos en blanco. Vas a poder agregar reglas, módulos y vocabulario cuando los necesites.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
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
                // Blank — no template (RPC treats empty as null per mig
                // create_group_with_admin_role_column). Skip seedTemplateRules.
                draft.template = ""
                draft.coverImageName = coverImageName
                let group = try await app.groupsRepo.createInitial(draft)
                await app.refreshProfileAndGroups()
                await MainActor.run {
                    app.activeGroupId = group.id
                    dismiss()
                    onCreated(group)
                }
            } catch {
                log.warning("create group failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.error = "No pudimos crear el grupo. \(error.ruulUserMessage)"
                }
            }
        }
    }
}
