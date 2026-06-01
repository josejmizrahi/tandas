import SwiftUI
import RuulCore

/// D.24 — Sheet that lets a caller submit a join request to a group
/// they were NOT explicitly invited to. Counterpart to
/// `AcceptInviteSheet` (which consumes an invite code).
///
/// Input accepts either a raw UUID, a `ruul://group/<uuid>` deep link,
/// or a `https://ruul.mx/group/<uuid>` universal link. Slug-only input
/// is V2 (needs a public `group_by_slug` RPC first).
///
/// On success the group remains invisible until an admin approves —
/// the new membership is `status='requested'` and appears in the admin's
/// "Solicitudes pendientes" cluster (`MembersListView`).
public struct RequestMembershipSheet: View {
    let container: DependencyContainer
    let onComplete: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rawInput: String = ""
    @State private var message: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    public init(container: DependencyContainer, onComplete: @escaping (UUID) -> Void) {
        self.container = container
        self.onComplete = onComplete
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.GroupSwitcher.requestHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField(
                        String(localized: L10n.GroupSwitcher.requestInputPlaceholder),
                        text: $rawInput,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .lineLimit(1...3)
                }
                Section {
                    TextField(
                        String(localized: L10n.GroupSwitcher.requestMessagePlaceholder),
                        text: $message,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                }
                if let successMessage {
                    Section {
                        Label {
                            Text(successMessage)
                                .font(.callout)
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                } else if let errorMessage {
                    Section {
                        Label {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(L10n.GroupSwitcher.requestTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.GroupSwitcher.close)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.GroupSwitcher.requestSubmit)) {
                        submit()
                    }
                    .disabled(isSubmitting || rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || successMessage != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func submit() {
        guard let groupId = parseGroupId(rawInput) else {
            errorMessage = String(localized: L10n.GroupSwitcher.requestInvalidId)
            successMessage = nil
            return
        }
        isSubmitting = true
        errorMessage = nil
        successMessage = nil
        Task {
            do {
                let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
                let membershipId = try await container.groupRepository.requestMembership(
                    groupId: groupId,
                    message: trimmedMessage.isEmpty ? nil : trimmedMessage
                )
                successMessage = String(localized: L10n.GroupSwitcher.requestSuccess)
                onComplete(membershipId)
            } catch {
                errorMessage = UserFacingError.from(error).message
            }
            isSubmitting = false
        }
    }

    /// Accepts: bare UUID, `ruul://group/<uuid>`, `https://ruul.mx/group/<uuid>`.
    /// Slug resolution (`d22-test-be347a` → UUID) is V2 and requires a
    /// public `group_by_slug` RPC.
    private func parseGroupId(_ raw: String) -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = UUID(uuidString: trimmed) { return direct }
        guard let url = URL(string: trimmed),
              let link = DeepLink.parse(url),
              let gid = link.groupId
        else { return nil }
        return gid
    }
}
