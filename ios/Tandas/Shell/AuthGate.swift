import SwiftUI
import RuulUI
import RuulCore
import RuulFeatures

struct AuthGate: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var modelContext
    /// Mirrors `OnboardingCompletion.hasOnboarded` (Keychain-backed). We
    /// can't use `@AppStorage` because the flag lives in Keychain so it
    /// survives reinstalls; instead we re-read it on `.task` and on the
    /// `OnboardingCompletion.didChangeNotification` published by mark/clear.
    @State private var hasOnboarded: Bool = OnboardingCompletion.hasOnboarded
    @State private var hasActiveOnboarding: Bool = false
    @State private var hasCheckedOnboarding: Bool = false

    var body: some View {
        SwiftUI.Group {
            if app.isBootstrapping || !hasCheckedOnboarding {
                BootstrappingView()
            } else if app.session == nil {
                // Sign-in-first architecture: ANY unauthenticated state
                // routes here, including a brand-new device. There is
                // no anon-session entry into onboarding anymore — the
                // pre-Apple founder flow created groups under the anon
                // user_id and `signInWithIdToken` did not always link
                // them to the verified account, leaving groups
                // orphaned to a user nobody can sign back in as.
                // SignInView handles both Apple Sign In and Phone OTP;
                // both providers auto-create users on first-use, so
                // there is no separate "create account" path.
                SignInView()
            } else if hasActiveOnboarding || isFirstTimeAuth {
                // Authenticated branch: either we're mid-onboarding
                // (entity persisted, restoring on relaunch) OR this is
                // the user's first sign-in on this account and they
                // need the guided "name your group / invite friends"
                // flow.
                //
                // Single branch (consolidated): SwiftUI keeps the
                // OnboardingRootView's @State coordinatorBundle alive
                // across `hasActiveOnboarding` flicker (the flag
                // flips false→true after the first persist). Splitting
                // into two branches with the same content caused
                // view-tree resets that dropped the user back to
                // "¿Cómo te llamas?" mid-flow.
                onboardingFlow
            } else {
                MainTabView()
            }
        }
        .task { await app.start() }
        .task { await refreshOnboardingState() }
        .onChange(of: app.session?.user.id) { _, _ in
            Task { await refreshOnboardingState() }
        }
        // Keychain has no Combine surface, so listen for the explicit
        // mark/clear notification. Without this, SignInView's "Crear
        // nueva" tap would mutate keychain but AuthGate wouldn't
        // re-render until the next session change.
        .onReceive(NotificationCenter.default.publisher(for: OnboardingCompletion.didChangeNotification)) { _ in
            hasOnboarded = OnboardingCompletion.hasOnboarded
        }
    }

    private var onboardingFlow: some View {
        OnboardingRootView(pendingInviteCode: app.pendingInviteCode) { _ in
            Task {
                app.consumePendingInvite()
                await refreshOnboardingState()
                await app.refreshProfileAndGroups()
            }
        }
    }

    /// True for an authenticated user landing on this device for the
    /// first time: real session + no groups + has NOT completed
    /// onboarding before (`hasOnboarded` keychain flag).
    ///
    /// Returning users who lost access to all their groups (left all of
    /// them, BigBang wipe, orphaned user_id) keep `hasOnboarded = true`
    /// and route into `MainTabView`'s empty state, which lets them
    /// create or join a new group without re-doing the onboarding flow
    /// (name + vocabulary etc. they've already given).
    private var isFirstTimeAuth: Bool {
        app.session != nil && app.groups.isEmpty && !hasOnboarded
    }

    @MainActor
    private func refreshOnboardingState() async {
        let manager = OnboardingProgressManager(context: modelContext)
        // Stale-entity policy under the sign-in-first architecture.
        // We only persist an OnboardingProgress while a session exists
        // and the user is genuinely in the create-first-group flow.
        // Anything else is residue:
        //   - `loggedOut`: session is nil → SignInView will take over,
        //     so any leftover onboarding row is from an abandoned flow.
        //   - `hasGroup`: at least one group loaded → the user is past
        //     the only step that creates persisted state. They belong
        //     in MainTabView, so the entity is residue.
        //
        // We deliberately do NOT clear an entity for an authenticated
        // user with `groups.isEmpty` and `!hasOnboarded`: that's the
        // mid-flow first-time founder, whose entity is *exactly* what
        // keeps the coordinator restoring at the right step on
        // relaunch.
        let loggedOut = app.session == nil
        let hasGroup = app.session != nil && !app.groups.isEmpty
        if loggedOut || hasGroup {
            try? manager.clear()
        }
        hasActiveOnboarding = (try? manager.loadActive()) != nil
        hasCheckedOnboarding = true
    }
}

struct BootstrappingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .tint(Color.ruulAccent)
        }
    }
}
