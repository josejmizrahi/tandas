import SwiftUI
import OSLog
import RuulUI
import RuulCore

/// Minimal "join an existing group" flow for users who already have an
/// account. Just asks for a 6-char invite code and calls join_group_by_code.
/// Skips the entire invited onboarding flow (welcome / identity / phoneVerify
/// / OTP / tour) since the user is already authed.
public struct JoinGroupSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var isSubmitting: Bool = false
    @State private var error: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "groups.join")

    public var onJoined: (RuulCore.Group) -> Void

    public init(onJoined: @escaping (RuulCore.Group) -> Void) {
        self.onJoined = onJoined
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    header
                    codeField
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                    RuulButton(
                        "Unirme",
                        style: .primary,
                        size: .large,
                        isLoading: isSubmitting,
                        fillsWidth: true,
                        action: submit
                    )
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .ruulAmbientScreen(palette: nil)
            .ruulSheetToolbar("Unirme con código")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("¿Cuál es el código?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("El fundador del grupo te lo compartió. Suele tener 6 caracteres.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
    }

    private var codeField: some View {
        RuulTextField(
            "ABC123",
            text: $code,
            label: "Código de invitación"
        )
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled(true)
    }

    private func submit() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { Task { @MainActor in isSubmitting = false } }
            do {
                let group = try await app.groupsRepo.joinByCode(trimmed)
                await app.refreshProfileAndGroups()
                await MainActor.run {
                    app.activeGroupId = group.id
                    dismiss()
                    onJoined(group)
                }
            } catch {
                log.warning("join group failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.error = "No pudimos unirte: código inválido o expirado."
                }
            }
        }
    }
}
