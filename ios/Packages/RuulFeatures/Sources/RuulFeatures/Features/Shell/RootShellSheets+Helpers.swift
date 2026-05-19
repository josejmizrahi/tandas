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
            onAssignCustody: { [assetLifecycleRepo = app.assetLifecycleRepo] resourceId, memberId in
                // Now wired end-to-end: DestinationPresenter passes the
                // real resource id captured from
                // PostCreateIntentScreenContainer (resourceId from the
                // .postCreate phase), so the RPC targets the just-
                // created asset correctly. Pre-fix this closure
                // captured group.id as a placeholder which was wrong.
                try await assetLifecycleRepo.assignCustody(
                    asset: resourceId, to: memberId, notes: nil
                )
            },
            onCreateChildResource: { [router = router] _ in
                // Detach + pop-first ordering: parent createCover must
                // leave activeRoutes before we re-push, otherwise
                // router.present(.createCover) no-ops (contains check)
                // and the subsequent onClose-driven dismissTop loop
                // strips the just-pushed cover. Same shape as
                // onNavigate above — detached Task survives the parent
                // sheet's teardown cancelling the launcher's .task.
                // prefilledType ignored for now — user picks type again
                // on the fresh sheet.
                Task { @MainActor in
                    while router.state.contains(.createCover) {
                        router.state.dismissTop()
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    router.present(.createCover)
                }
            },
            onNavigate: { [eventRepo = app.eventRepo,
                           resourceRepo = app.resourceRepo,
                           homeCoord = router.state.homeCoordinator,
                           router = router] target in
                // CRITICAL ordering: createCover MUST be popped from
                // activeRoutes BEFORE the destination is pushed, and
                // the actual push MUST run in a detached Task so it
                // survives the sheet teardown cancelling navLauncher's
                // .task.
                //
                // Why: boolBinding(.createCover).set(false) iterates
                // `while contains(.createCover) { dismissTop() }` —
                // dismissTop removes the LAST element, not the named
                // one. If we push .eventDetail first, activeRoutes is
                // [.createCover, .eventDetail], and the loop's first
                // pop removes .eventDetail (top of stack), then pops
                // .createCover. Both vanish; nothing presents.
                // Pop createCover first → activeRoutes = []; sleep so
                // SwiftUI animates the dismiss; then push the target,
                // which presents cleanly against the now-empty cover
                // slot.
                Task { @MainActor in
                    while router.state.contains(.createCover) {
                        router.state.dismissTop()
                    }
                    try? await Task.sleep(for: .milliseconds(400))

                    @MainActor
                    func openOrFallback(_ id: UUID, initialAction: PendingEventInitialAction? = nil) async {
                        if let event = try? await eventRepo.event(id) {
                            if let initialAction {
                                router.openEvent(event, initialAction: initialAction)
                            } else {
                                router.openEvent(event)
                            }
                            return
                        }
                        if let row = try? await resourceRepo.resource(id) {
                            router.openResource(row)
                            return
                        }
                        await homeCoord?.refresh(force: true)
                    }

                    switch target {
                    case .resourceDetailRSVP(let id):
                        // "Invitar gente" → auto-open the share sheet so
                        // the user immediately gets the invite link to
                        // send to friends, instead of landing on the
                        // event Overview with no obvious next step.
                        await openOrFallback(id, initialAction: .share)
                    case .resourceDetailCheckIn(let id):
                        // "Pasar lista" → auto-launch the QR scanner.
                        // The scanner lives on its own RootShellState
                        // slot (CheckInScannerCoordinator); EventDetailHost
                        // routes the auto-open via its onScannerOpen
                        // callback once the coordinator finishes
                        // bootstrap.
                        await openOrFallback(id, initialAction: .scanner)
                    case .historyTab(_, let id), .moneyTab(_, let id):
                        if let id { await openOrFallback(id) }
                        else { await homeCoord?.refresh(force: true) }
                    case .ruleTemplatePicker(_, let id):
                        await openOrFallback(id)
                    case .governanceRuleEditor:
                        router.openGroupRulesSettings()
                    }
                }
            }
        )
        ResourceCreationSheet(
            group: group,
            builders: app.resourceBuilders,
            // Static init value left empty — the real defaults flow
            // through `templateDefaultsLoader` below which runs right
            // before create() so the registry's async lookup doesn't
            // block sheet construction. When no template id is set on
            // the group, loader returns `[:]` and silent-attach falls
            // back to the variant's declared set alone.
            templateDefaultsByType: [:],
            viewerPermissions: viewerPermissions(in: group),
            activator: activator,
            // Same repo the activator uses internally. Coordinator
            // re-reads `resource_capabilities` after build returns so
            // backend trigger-seeded caps (money, custody, valuation,
            // schedule, etc.) surface in the post-create intent
            // visibility instead of waiting for the next manual refresh.
            capabilityRepo: app.resourceCapabilityRepo,
            // Coordinator hydrates `attachedResource` post-build so
            // RecordValuationSheet et al. (accept asset: ResourceRow)
            // stop falling back to placeholder.
            resourceRepo: app.resourceRepo,
            // Async loader invoked right before create() so the group's
            // template config drives silent-attach. Cenas template
            // (or any future template) declaring defaultCapabilities
            // for `event` now actually auto-enables those caps on
            // every event created from the new flow.
            templateDefaultsLoader: { [templateRegistry = app.templateRegistry] group in
                guard let templateId = group.baseTemplate,
                      let template = await templateRegistry.template(id: templateId),
                      let declared = template.config.defaultCapabilities
                else { return [:] }
                return declared
            },
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
