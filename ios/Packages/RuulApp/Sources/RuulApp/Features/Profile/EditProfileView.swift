import SwiftUI
import RuulCore

/// Apple-native Form for editing the caller's own profile. Hosted in a
/// sheet (mode: `.onboarding` when the nudge opens it, `.edit` from the
/// account menu). Backed by `ProfileStore`; every mutation goes through
/// `update_my_profile`.
///
/// Email/phone NOT editable here — those live on `auth.users` and are
/// changed via `AuthService.startPhoneChange` / `startEmailChange` (out
/// of scope for this slice).
struct EditProfileView: View {
    @Bindable var store: ProfileStore
    let mode: Mode

    enum Mode: Equatable {
        case onboarding
        case edit
    }

    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var username: String = ""
    @State private var bio: String = ""
    @State private var isSaving: Bool = false
    @State private var didPrefill: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: L10n.Profile.displayNamePlaceholder),
                        text: $displayName
                    )
                    .textContentType(.name)
                    .submitLabel(.done)
                    .disableAutocorrection(true)
                } header: {
                    Text(L10n.Profile.displayNameLabel)
                }

                Section {
                    TextField(
                        String(localized: L10n.Profile.usernamePlaceholder),
                        text: $username
                    )
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                } header: {
                    Text(L10n.Profile.usernameLabel)
                }

                Section {
                    TextField(
                        String(localized: L10n.Profile.bioPlaceholder),
                        text: $bio,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                } header: {
                    Text(L10n.Profile.bioLabel)
                }

                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) {
                        store.clearError()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(L10n.Profile.save)
                        }
                    }
                    .disabled(isSaveDisabled)
                }
            }
        }
        .onAppear(perform: prefillIfNeeded)
        .interactiveDismissDisabled(isSaving)
    }

    private var navigationTitle: LocalizedStringResource {
        switch mode {
        case .onboarding: return L10n.Profile.onboardingTitle
        case .edit: return L10n.Profile.editTitle
        }
    }

    private var cancelTitle: LocalizedStringResource {
        switch mode {
        case .onboarding: return L10n.Profile.later
        case .edit: return L10n.Profile.cancel
        }
    }

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSaveDisabled: Bool {
        isSaving || trimmedDisplayName.isEmpty
    }

    private func prefillIfNeeded() {
        guard !didPrefill else { return }
        didPrefill = true
        if let profile = store.profile {
            displayName = profile.displayName ?? ""
            username = profile.username ?? ""
            bio = profile.bio ?? ""
        }
    }

    private func save() {
        Task {
            isSaving = true
            defer { isSaving = false }
            let ok = await store.updateProfile(
                displayName: trimmedDisplayName,
                username: username,
                bio: bio
            )
            if ok {
                dismiss()
            }
        }
    }
}

#Preview("Edit — completed profile") {
    let mock = ProfilePreviewData.completedStore()
    EditProfileView(store: mock, mode: .edit)
}

#Preview("Onboarding — empty profile") {
    let mock = ProfilePreviewData.emptyStore()
    EditProfileView(store: mock, mode: .onboarding)
}

#Preview("Dark mode") {
    EditProfileView(store: ProfilePreviewData.completedStore(), mode: .edit)
        .preferredColorScheme(.dark)
}

#Preview("Large dynamic type") {
    EditProfileView(store: ProfilePreviewData.completedStore(), mode: .edit)
        .environment(\.dynamicTypeSize, .accessibility2)
}
