import SwiftUI
import RuulCore

/// Store-driven invite form for the members surface. Distinct from the
/// existing `Features/Invites/InviteMemberSheet` (slice 4b) which keeps
/// its own local `@State` because it's called from the legacy
/// GroupHomeView code path. Renamed to `MembersInviteSheet` to avoid a
/// same-module type collision while preserving the slice 4b call site.
///
/// Form sections follow the spec: Contact (email/phone), Membership
/// type, Message. Validation lives on the store via `canSubmitInvite`.
public struct MembersInviteSheet: View {
    @Bindable var store: MembersStore
    let groupId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting: Bool = false

    public init(store: MembersStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: L10n.Invite.emailPlaceholder),
                        text: $store.inviteEmail
                    )
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)

                    TextField(
                        String(localized: L10n.Invite.phonePlaceholder),
                        text: $store.invitePhone
                    )
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                } header: {
                    Text(L10n.Invite.contactSection)
                }

                Section {
                    Picker(selection: $store.inviteMembershipType) {
                        ForEach(MembershipType.invitableCases) { type in
                            Text(type.label).tag(type)
                        }
                    } label: {
                        Text(L10n.Invite.membershipTypeSection)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text(L10n.Invite.membershipTypeSection)
                }

                Section {
                    TextField(
                        String(localized: L10n.Invite.messagePlaceholder),
                        text: $store.inviteMessage,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                } header: {
                    Text(L10n.Invite.messageSection)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.Invite.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.clearInviteForm()
                        dismiss()
                    } label: {
                        Text(L10n.Invite.cancel)
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L10n.Invite.send)
                        }
                    }
                    .disabled(!store.canSubmitInvite || isSubmitting)
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let success = await store.inviteMember(groupId: groupId)
        if success { dismiss() }
    }
}

#Preview("Empty form") {
    @Previewable @State var store = MembersStore()
    return MembersInviteSheet(store: store, groupId: UUID())
}
