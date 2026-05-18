import Foundation

/// Session lifecycle: cold start, profile/group refresh, sign-out
/// (with token revoke). The auth session stream is the trigger for
/// every transition; downstream surfaces consult `session` /
/// `isBootstrapping` to gate rendering.
///
/// Extracted from `AppState.swift` 2026-05-18 per
/// Plans/Active/CleanupAudit_2026-05-18/01_architecture.md §2.1
/// (god-object split). All stored state these methods mutate (session,
/// profile, groups, isBootstrapping, bootstrapError) lives on the
/// class declaration since class extensions can't add stored state.
public extension AppState {

    func start() async {
        for await s in auth.sessionStream {
            self.session = s
            if s != nil {
                // Verify the cached JWT still maps to a live auth.users row.
                // If the user was deleted server-side (DB wipe, manual delete),
                // the Keychain token is stale: PostgREST 401s silently and
                // AuthGate strands the user in a zombie-authenticated state.
                // Force sign-out and let AuthGate route to SignInView.
                let valid = await auth.verifySession()
                if !valid {
                    try? await auth.signOut()
                    self.session = nil
                    self.profile = nil
                    self.groups = []
                    self.isBootstrapping = false
                    continue
                }
                // list_modules() RPC is grant-restricted to authenticated;
                // refresh the catalog only once we have a session. v1Fallback
                // covers the pre-auth surface.
                async let modules:   Void = loadModuleRegistry()
                async let shapes:    Void = loadRuleShapeRegistry()
                async let templates: Void = loadRuleTemplates()
                _ = await (modules, shapes, templates)
                await refreshProfileAndGroups()
                await refreshPendingPlaceholderClaims()
                // Beta 1 W3 E-3.1: open cross-device realtime channels
                // once we have a session. RLS scopes incoming rows so a
                // single un-filtered channel per table is enough.
                await multiDeviceChangeFeed?.start()
            } else {
                self.profile = nil
                self.groups = []
                await multiDeviceChangeFeed?.stop()
            }
            self.isBootstrapping = false
        }
    }

    func refreshProfileAndGroups() async {
        bootstrapError = nil
        do {
            async let pTask = profileRepo.loadMine()
            async let gTask = groupsRepo.listMine()
            async let tTask: Void = templateRegistry.refresh()
            let (p, g) = try await (pTask, gTask)
            await tTask
            self.profile = p
            self.groups = g
        } catch {
            self.bootstrapError = "\(error)"
            self.profile = Profile(
                id: session?.user.id ?? UUID(),
                displayName: "",
                avatarUrl: nil,
                phone: session?.user.phone
            )
            self.groups = []
        }
    }

    /// Sign out + revoke the device's APNs token in one step. Use this
    /// everywhere instead of calling `auth.signOut()` directly: a bare
    /// `auth.signOut` leaves the `notification_tokens` row owned by the
    /// now-gone session, so a shared device that swaps users keeps
    /// receiving pushes addressed to the original account.
    ///
    /// The revoke is best-effort — failures are logged inside
    /// `NotificationService.revokeTokenIfRegistered()` but never block the
    /// sign-out. The user always ends up logged out client-side even if
    /// the server-side revoke didn't reach the DB.
    func signOut() async throws {
        await notifications?.revokeTokenIfRegistered()
        await multiDeviceChangeFeed?.stop()
        try await auth.signOut()
    }
}
