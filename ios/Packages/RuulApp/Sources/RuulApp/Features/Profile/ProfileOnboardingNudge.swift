import SwiftUI
import RuulCore

/// Compact card-row that asks the signed-in user to complete their
/// profile. Renders nothing when `store.requiresProfileCompletion`
/// is false — embedding views can drop this at the top of any list
/// without conditional `if` blocks.
///
/// Opens `EditProfileView` in `.onboarding` mode via the store's
/// `isEditPresented` binding so multiple entry points (this nudge,
/// the account menu) share one sheet.
struct ProfileOnboardingNudge: View {
    @Bindable var store: ProfileStore

    var body: some View {
        if store.requiresProfileCompletion {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(L10n.Profile.onboardingTitle)
                        .font(.headline)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.tint)
                }

                Text(L10n.Profile.onboardingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    store.isEditPresented = true
                } label: {
                    Text(L10n.Profile.complete)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }
}

#Preview("Requires completion") {
    List {
        Section {
            ProfileOnboardingNudge(store: ProfilePreviewData.emptyStore())
        }
    }
}

#Preview("Already completed (renders nothing)") {
    List {
        Section {
            ProfileOnboardingNudge(store: ProfilePreviewData.completedStore())
            Text("Other content")
        }
    }
}
