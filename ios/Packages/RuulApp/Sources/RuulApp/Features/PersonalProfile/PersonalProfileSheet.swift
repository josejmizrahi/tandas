import SwiftUI
import RuulCore

/// Root sheet for the caller's account — opened from the avatar button
/// on `GroupListView`'s toolbar (will move to the global avatar slot
/// when the shell lands in D3). Combines identity hero + sub-page
/// links (PersonalSettingsView · AccountSecurityView) + Cerrar sesión.
///
/// Pattern: Settings.app — grouped list inside a NavigationStack so
/// sub-pages push, and the sheet itself dismisses via the Listo
/// toolbar button.
struct PersonalProfileSheet: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingSignOut: Bool = false

    var body: some View {
        NavigationStack {
            List {
                heroSection
                accountSection
                preferencesSection
                dangerSection
            }
            .navigationTitle(L10n.PersonalProfile.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PersonalProfileDestination.self) { destination in
                switch destination {
                case .settings:
                    PersonalSettingsView()
                case .accountSecurity:
                    AccountSecurityView(session: currentSession)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.PersonalProfile.close)) {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: profileEditBinding) {
                EditProfileView(
                    store: container.profileStore,
                    mode: container.profileStore.requiresProfileCompletion ? .onboarding : .edit
                )
            }
            .confirmationDialog(
                Text(L10n.PersonalProfile.signOutConfirmTitle),
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    Task {
                        await container.sessionStore.signOut()
                        dismiss()
                    }
                } label: {
                    Text(L10n.PersonalProfile.signOutAction)
                }
                Button(role: .cancel) {} label: {
                    Text(L10n.PersonalProfile.cancel)
                }
            } message: {
                Text(L10n.PersonalProfile.signOutConfirmMessage)
            }
            .task {
                await container.profileStore.refreshIfNeeded()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(spacing: 12) {
                avatar
                    .frame(width: 96, height: 96)

                VStack(spacing: 4) {
                    Text(container.profileStore.resolvedDisplayName)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let username = container.profileStore.profile?.username,
                       !username.isEmpty {
                        Text("@\(username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let bio = container.profileStore.profile?.bio,
                   !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Button {
                container.profileStore.isEditPresented = true
            } label: {
                Label(L10n.PersonalProfile.editProfile, systemImage: "person.crop.circle")
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = container.profileStore.profile?.avatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    avatarFallback
                @unknown default:
                    avatarFallback
                }
            }
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    @ViewBuilder
    private var avatarFallback: some View {
        ZStack {
            Circle().fill(.thinMaterial)
            Text(initials)
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    private var initials: String {
        let raw = container.profileStore.resolvedDisplayName
        let parts = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "?" }
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        let joined = letters.joined()
        return joined.isEmpty ? "?" : joined.uppercased()
    }

    @ViewBuilder
    private var accountSection: some View {
        Section(L10n.PersonalProfile.accountSection) {
            NavigationLink(value: PersonalProfileDestination.accountSecurity) {
                Label(L10n.PersonalProfile.accountSecurityRow, systemImage: "lock.shield")
            }
        }
    }

    @ViewBuilder
    private var preferencesSection: some View {
        Section(L10n.PersonalProfile.preferencesSection) {
            NavigationLink(value: PersonalProfileDestination.settings) {
                Label(L10n.PersonalProfile.settingsRow, systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder
    private var dangerSection: some View {
        Section(L10n.PersonalProfile.dangerSection) {
            Button(role: .destructive) {
                isConfirmingSignOut = true
            } label: {
                Label(L10n.PersonalProfile.signOut, systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    // MARK: - Helpers

    private var currentSession: AppSession? {
        if case .signedIn(let session) = container.sessionStore.state {
            return session
        }
        return nil
    }

    private var profileEditBinding: Binding<Bool> {
        Binding(
            get: { container.profileStore.isEditPresented },
            set: { container.profileStore.isEditPresented = $0 }
        )
    }

    private enum PersonalProfileDestination: Hashable {
        case settings
        case accountSecurity
    }
}
