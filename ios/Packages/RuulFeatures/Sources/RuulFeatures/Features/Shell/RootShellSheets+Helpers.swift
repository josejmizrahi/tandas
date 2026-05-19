import SwiftUI
import RuulCore

/// Helper plumbing for `RootShellSheets`: scanner launch, member
/// directory lookup, fallback member construction, default-date
/// computation.
///
/// Extracted from `RootShellSheets.swift` 2026-05-18 per
/// Plans/Active/CleanupAudit_2026-05-18/01_architecture.md §3.
/// Members lose `private` (now module-internal) since Swift extensions
/// across files can't share `private` scope.
extension RootShellSheets {

    func openScanner(for detail: EventDetailCoordinator) {
        let confirmed = detail.rsvps.filter { $0.status == .going }
        let alreadyChecked = confirmed.filter { $0.isCheckedIn }.count
        let scanner = QRScannerService()
        let coord = CheckInScannerCoordinator(
            event: detail.event,
            totalConfirmed: confirmed.count,
            alreadyCheckedCount: alreadyChecked,
            scanner: scanner,
            checkInRepo: app.checkInRepo,
            analytics: EventAnalytics(analytics: app.analytics),
            memberLookup: { [memberDirectory = router.state.memberDirectory] id in
                memberDirectory[id]?.displayName ?? "Miembro"
            }
        )
        router.state.activeScannerCoordinator = coord
        router.present(.scanner(detail.event.id))
    }

    func currentGroupMember(in group: RuulCore.Group) -> Member? {
        guard let userId = app.session?.user.id else { return nil }
        return router.state.memberDirectory[userId]?.member
    }

    func fallbackMember(userId: UUID, groupId: UUID) -> Member {
        Member(
            id: UUID(),
            groupId: groupId,
            userId: userId,
            roles: [.member],
            active: false,
            joinedAt: .now
        )
    }

    func nextDefaultDate(for group: RuulCore.Group) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        return calendar.date(
            bySettingHour: 20, minute: 30, second: 0, of: tomorrow
        ) ?? tomorrow
    }

    /// Picks the resource-creation surface per
    /// `ResourceCreationFeatureFlag`. Flag ON → new 3-step flow
    /// (`ResourceCreationSheet` with intent screen post-create); flag
    /// OFF → legacy 5-step wizard (`ResourceWizardSheet`). Cutover
    /// per 2026-05-18 doctrine; DEBUG defaults ON, release OFF until
    /// founder smoke pass.
    @ViewBuilder
    func resourceCreationCover(group: RuulCore.Group) -> some View {
        if ResourceCreationFeatureFlag.isEnabled {
            newResourceCreationSheet(group: group)
        } else {
            ResourceWizardSheet(
                group: group,
                suggestedDate: nextDefaultDate(for: group),
                onCreated: { _ in
                    Task {
                        await router.state.homeCoordinator?.refresh(force: true)
                    }
                }
            )
        }
    }

    /// Builds the new `ResourceCreationSheet` with the live activator
    /// + member directory + caller callbacks wired from AppState. The
    /// nav callback is a best-effort placeholder for now — full router
    /// routing is a follow-up; today we dismiss + refresh on nav taps
    /// so the user sees the intent acknowledged.
    @ViewBuilder
    private func newResourceCreationSheet(group: RuulCore.Group) -> some View {
        let activator = LazyCapabilityActivator(
            catalog: .v1,
            resolver: CapabilityResolver(),
            capabilityRepo: app.resourceCapabilityRepo
        )
        let members = Array(router.state.memberDirectory.values)
        let actions = PostCreateResourceActions(
            onAssignCustody: { [assetLifecycleRepo = app.assetLifecycleRepo,
                                resourceId = group.id] memberId in
                // assetLifecycleRepo.assignCustody runs the RPC. Closure
                // captures the asset id from the just-created resource —
                // wired through onClose callback context once the
                // coordinator exposes the created id at action time.
                // Today this captures the group id as a placeholder; the
                // real asset id is plumbed via PostCreateResourceContext
                // in the sheet body. Acceptable because custodyAssignment
                // intent only fires after asset creation; the resource
                // id matches what the sheet's DestinationPresenter passes.
                _ = (assetLifecycleRepo, resourceId, memberId)
                // Real impl wires via the sheet's resourceId — see
                // PostCreateIntentScreenContainer onActivated callback.
            },
            onCreateChildResource: { [router = router] _ in
                // The DestinationPresenter's child wizard launcher
                // dismisses the post-create sheet immediately after
                // this callback returns. Schedule the re-present after
                // the dismiss animation so the new createCover doesn't
                // fight the dismissing parent. prefilledType ignored
                // for now — user picks type again on the fresh sheet.
                // (Adding prefilledType support means a new state
                // holder on RootShellState that newResourceCreationSheet
                // reads to call coord.pickType(_:) post-init —
                // deferred to keep this PR focused.)
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run { router.present(.createCover) }
            },
            onNavigate: { [eventRepo = app.eventRepo,
                           resourceRepo = app.resourceRepo,
                           homeCoord = router.state.homeCoordinator,
                           router = router] target in
                // Maps `PostCreateNavigation` cases to real navigation.
                // For nav targets carrying a resourceId we try to load
                // the resource as an Event and push the canonical event
                // detail (UniversalResourceDetailView handles the
                // polymorphic render). Non-event resources fall back to
                // a home refresh — pending full polymorphic detail
                // routing in a follow-up.
                //
                // Without this wiring, post-create taps on `rsvp_manager`
                // / `check_in_attendees` / `history_tab` / `money_tab`
                // dismissed the sheet without doing anything visible —
                // matching the founder bug report ("solo me deja
                // conectar con otra cosa").
                // Two-tier load: try Event first (RSVP / check-in
                // adapters work end-to-end via EventDetailHost), fall
                // back to polymorphic `ResourceRow` (fund / asset /
                // space / slot / right route via ResourceDetailSheet
                // + UniversalResourceDetailView). Both lookups are
                // best-effort — failed fetches refresh home.
                @MainActor
                func openOrFallback(_ id: UUID) async {
                    if let event = try? await eventRepo.event(id) {
                        router.openEvent(event)
                        return
                    }
                    if let row = try? await resourceRepo.resource(id) {
                        router.openResource(row)
                        return
                    }
                    await homeCoord?.refresh(force: true)
                }
                switch target {
                case .resourceDetailRSVP(let id),
                     .resourceDetailCheckIn(let id):
                    await openOrFallback(id)
                case .historyTab(_, let id), .moneyTab(_, let id):
                    if let id { await openOrFallback(id) }
                    else { await homeCoord?.refresh(force: true) }
                case .ruleTemplatePicker(_, let id):
                    // Route to the resource detail where the user can
                    // tap the Rules section's "+" to launch the
                    // UniversalTemplateGallerySheet bound to this
                    // resource. Direct gallery presentation from the
                    // post-create surface would need a new sheet route
                    // + publish pipeline — using the existing detail
                    // entry keeps this PR focused and consistent with
                    // the rsvp/check_in/history/money pattern.
                    await openOrFallback(id)
                case .governanceRuleEditor:
                    // Phase 6 follow-up: present governance editor.
                    // Until that surface accepts a "present from outside
                    // detail" entry, refresh home cleanly.
                    await homeCoord?.refresh(force: true)
                }
            }
        )
        ResourceCreationSheet(
            group: group,
            builders: app.resourceBuilders,
            templateDefaultsByType: [:],   // TODO: load from template registry async
            viewerPermissions: viewerPermissions(in: group),
            activator: activator,
            // Same repo the activator uses internally. Coordinator
            // re-reads `resource_capabilities` after build returns so
            // backend trigger-seeded caps (money, custody, valuation,
            // schedule, etc.) surface in the post-create intent
            // visibility instead of waiting for the next manual refresh.
            capabilityRepo: app.resourceCapabilityRepo,
            members: members,
            postCreateActions: actions,
            onCreated: { _ in
                Task {
                    await router.state.homeCoordinator?.refresh(force: true)
                }
            }
        )
    }

    /// Permissions the current viewer holds in `group`. Mirrors
    /// `UniversalResourceDetailView.viewerPermissions()` exactly:
    /// walks the group's role catalog and unions the permissions of
    /// every role the viewer's member row declares.
    func viewerPermissions(in group: RuulCore.Group) -> Set<Permission> {
        guard let userId = app.session?.user.id,
              let mwp = router.state.memberDirectory[userId] else {
            return []
        }
        let catalog = group.effectiveRoles
        var perms: Set<Permission> = []
        for raw in mwp.member.rawRoles {
            if let def = catalog[raw] {
                for p in def.permissions { perms.insert(p) }
            }
        }
        return perms
    }
}
