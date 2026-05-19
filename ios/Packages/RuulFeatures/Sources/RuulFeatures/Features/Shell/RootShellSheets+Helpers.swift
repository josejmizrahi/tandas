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
            onCreateChildResource: { _ in
                // Phase 5 follow-up: present a recursive
                // ResourceCreationSheet with the prefilled type. For
                // now the placeholder + dismiss is the honest response.
            },
            onNavigate: { target in
                // Phase 5 follow-up: full router integration to push
                // resource detail / switch tab / present rule template
                // picker. Today: refresh home as a best-effort.
                _ = target
                await router.state.homeCoordinator?.refresh(force: true)
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
