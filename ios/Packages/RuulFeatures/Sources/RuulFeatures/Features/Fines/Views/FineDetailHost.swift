import SwiftUI
import RuulCore
import RuulUI

/// Phase E host for fine detail. Wraps `FineDetailCoordinator` and renders
/// the fine via `UniversalResourceDetailView` + `FineBlockBuilder`.
///
/// Doctrine §0 + Addendum F:
///   - Primary action (`.payFine`) lives inline in StateHero; we route
///     it to `FineRepository.payFine` → `rpc('pay_fine')`.
///   - The legacy void-fine surface (admin-only, destructive) is
///     surfaced through the overflow `.delete` slot ("Anular multa")
///     when `canVoidFine` is true, gated by the governance service.
///   - Appeal lifecycle: the `appeal` capability block emits
///     `openDestinationId = "appeal.vote"`. Tapping pushes the appeal's
///     vote screen via `onViewAppeal`.
///   - Activity feed loaded via the shared `ActivityFeedLoader` so the
///     fine's `fine_proposed` / `fine_paid` / `fine_appealed` /
///     `fine_voided` system_events surface inline at the bottom.
@MainActor
public struct FineDetailHost: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: FineDetailCoordinator

    public var onViewAppeal: ((Appeal) -> Void)?

    @State private var blocks: ResourceBlocks?
    @State private var appealSheetPresented = false
    @State private var voidSheetPresented = false
    @State private var canVoidFine: Bool = false
    /// Mirror of server's `has_permission(group_id, viewer, 'markFinePaid')`.
    /// Lets a non-debtor admin surface the "Marcar como pagada" action
    /// (FASE 3 C.2: confirma pago offline). Server still gates `pay_fine`.
    @State private var canMarkFinePaid: Bool = false
    /// "Ver más" tap on the Activity layer.
    @State private var activityHistoryPresented: Bool = false

    /// Member directory keyed by `auth.users.id` for resolving the
    /// fine's `issuedBy` field into a display name. The `Fine` model
    /// stores the issuer's user-id (not group-members.id) so we key
    /// the dictionary the same way.
    @State private var membersByUserId: [UUID: MemberWithProfile] = [:]

    public init(
        coordinator: FineDetailCoordinator,
        onViewAppeal: ((Appeal) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.onViewAppeal = onViewAppeal
    }

    public var body: some View {
        Group {
            if let blocks {
                ResourceDetailContent(config: makeConfig(blocks: blocks))
            } else {
                ZStack {
                    Color.ruulBackgroundCanvas.ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            await coordinator.refresh()
            await coordinator.trackSeen()
            canVoidFine = await computeCanVoid()
            await loadMembers()
            canMarkFinePaid = computeCanMarkFinePaid()
            await rebuildBlocks()
        }
        .onChange(of: coordinator.fine) { _, _ in
            Task { await rebuildBlocks() }
        }
        .onChange(of: coordinator.existingAppeal) { _, _ in
            Task { await rebuildBlocks() }
        }
        // FASE 3 Action Warmth (D.1 rule 1 + B.3 template). Doctrine:
        // toda acción commit dispara haptic. Pago de multa = .success
        // cuando flippa a paid. Tap haptic se dispara en el handler
        // wrap del closure de Pagar (ver makeConfig).
        .sensoryFeedback(.success, trigger: coordinator.fine.paid)
        // Appeal sheet — opened from primary action when builder emits
        // an appeal-cast intent (no current path; reserved for future
        // builder rewrite that surfaces "Apelar" as a primary action).
        .sheet(isPresented: $appealSheetPresented) {
            AppealFineSheet(
                isPresented: $appealSheetPresented,
                fine: coordinator.fine
            ) { reason in
                // FASE 3 B.2: el sheet ahora espera + reporta éxito/fail.
                coordinator.clearError()
                await coordinator.startAppeal(reason: reason)
                return coordinator.error == nil
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
        }
        // Void fine sheet — admin destructive action surfaced through
        // the overflow `.delete` slot.
        .sheet(isPresented: $voidSheetPresented) {
            if canVoidFine {
                VoidFineSheet(
                    isPresented: $voidSheetPresented,
                    coordinator: VoidFineCoordinator(
                        fine: coordinator.fine,
                        fineRepo: app.fineRepo,
                        groupsRepo: app.groupsRepo,
                        onSubmitted: { @MainActor in
                            await coordinator.refresh()
                        }
                    )
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $activityHistoryPresented) {
            ResourceActivityHistorySheet(
                groupId: coordinator.fine.groupId,
                resourceId: coordinator.fine.id,
                displayName: coordinator.fine.reason
            )
            .environment(app)
            .presentationBackground(.ultraThinMaterial)
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Block building

    @MainActor
    private func rebuildBlocks() async {
        let viewerCtx = BlockViewerContext(
            userId: coordinator.userId,
            permissions: [],  // FineBlockBuilder gates only on debtor identity
            activeModules: [],
            memberId: nil
        )
        let built = FineBlockBuilder().build(
            source: coordinator.fine,
            viewer: viewerCtx,
            now: Date()
        )

        // Post-build augmentation: load system_events for this fine so the
        // activity layer reflects the real audit trail (proposed, paid,
        // appealed, voided).
        let feed = await ActivityFeedLoader.load(
            app: app,
            groupId: coordinator.fine.groupId,
            resourceId: coordinator.fine.id
        )

        blocks = ResourceBlocks(
            identity: built.identity,
            state: built.state,
            properties: built.properties,
            capabilities: built.capabilities,
            relations: built.relations,
            activityHead: feed.entries,
            hasMoreActivity: feed.hasMore
        )
    }

    // MARK: - Dispatch

    @MainActor
    private func dispatchPrimary() async {
        guard let kind = blocks?.state.primaryAction?.kind else { return }
        switch kind {
        case .payFine:
            await coordinator.payFine()
        case .none,
             .rsvpConfirm, .rsvpCancel, .viewHostActions,
             .openContribute, .openBooking, .viewClosed,
             .exerciseRight, .castVote:
            break  // not applicable to fines (castVote is for votes only)
        }
    }

    private func openDestination(_ id: String) {
        switch id {
        case "appeal.vote":
            if let appeal = coordinator.existingAppeal {
                onViewAppeal?(appeal)
            }
        default:
            break
        }
    }

    // MARK: - ResourceBlocks → ResourceConfig

    /// Resolves an auth user id into a `Person` for the avatar slots
    /// (Doctrine v2 §3 PresenceBlock — fines now surface fined +
    /// issuer as avatar rows instead of a text "Emisor" row).
    /// Returns nil when the directory hasn't loaded yet or the user
    /// isn't a current member of the group.
    private func makePerson(forUserId userId: UUID) -> Person? {
        guard let mw = membersByUserId[userId] else { return nil }
        let name = mw.displayName
        return Person(
            id: mw.member.id.uuidString,
            name: name,
            initials: Self.personInitials(name),
            color: ResourceFamilyTint.persons.color,
            imageURL: mw.avatarURL
        )
    }

    private static func personInitials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first.flatMap { $0.first.map(String.init) } ?? ""
        let last = parts.dropFirst().last.flatMap { $0.first.map(String.init) } ?? ""
        return (first + last).uppercased()
    }

    /// Builds the `FineInput` the new `.fine(_:)` factory expects from
    /// the live coordinator state. Amount as display hero, status as
    /// label, pay/appeal inline, void in toolbar menu (admin gated).
    private func makeConfig(blocks: ResourceBlocks) -> ResourceConfig {
        let f = coordinator.fine
        let viewerIsDebtor = coordinator.isMine
        // Server gates `pay_fine` on (self-pay) OR has_permission(markFinePaid)
        // (mig 00273). We mirror that here so an admin with the permission
        // can surface the action when the debtor pays offline.
        let canPay    = !f.paid
                        && f.status == .officialized
                        && (viewerIsDebtor || canMarkFinePaid)
        let canAppeal = viewerIsDebtor
                        && coordinator.existingAppeal == nil
                        && f.status == .officialized
                        && !f.paid
        let appealStatusLabel: String? = {
            guard coordinator.existingAppeal != nil else { return nil }
            return f.status == .inAppeal ? "En curso" : "Resuelta"
        }()
        // FASE 3 Action Warmth (D.3 rule "el éxito se atribuye al humano").
        // "Pagada" es contabilidad; "Pagaste" / "Pagada por X" es coordinación.
        let humanStatusLabel: String = {
            if f.paid {
                if viewerIsDebtor { return "Pagaste" }
                if let finedName = membersByUserId[f.userId]?.displayName {
                    return "Pagada por \(finedName)"
                }
            }
            return f.status.displayLabel
        }()
        let input = FineInput(
            id: f.id.uuidString,
            reason: f.reason,
            amountFormatted: f.amountFormatted,
            statusLabel: humanStatusLabel,
            createdAtLabel: Self.relativeAgo(f.createdAt),
            finedPerson: makePerson(forUserId: f.userId),
            issuerPerson: f.issuedBy.flatMap { makePerson(forUserId: $0) },
            canPay: canPay,
            canAppeal: canAppeal,
            appealStatusLabel: appealStatusLabel,
            activity: blocks.activityHead.map(Self.mapActivityEntry)
        )
        var toolbar: [ToolbarMenuItem] = []
        if canVoidFine {
            toolbar.append(ToolbarMenuItem(label: "Anular multa", icon: "xmark.bin", role: .destructive) {
                voidSheetPresented = true
            })
        }
        // FASE 3 C.2: when a non-debtor admin (markFinePaid permission)
        // triggers the action, the verb shifts from "Pagar" (self-pay)
        // to "Marcar como pagada" (recording an offline payment). Same
        // RPC + same B.3 warmth (haptic on tap + .success on flip).
        let payLabel = viewerIsDebtor ? "Pagar" : "Marcar como pagada"
        let payPendingLabel = viewerIsDebtor ? "Pagando…" : "Marcando…"
        return withGroupContext(.fine(
            input,
            isPaying: coordinator.isMutating,
            payLabel: payLabel,
            payPendingLabel: payPendingLabel,
            onPay: {
                // FASE 3 D.1 rule 1: haptic en tap (B.3 = .medium para
                // one-shot CTAs cargadas como pagar/aprobar). El .success
                // post-éxito vive en el .sensoryFeedback del body.
                RuulHaptic.medium.trigger()
                Task { await coordinator.payFine() }
            },
            onAppeal: { appealSheetPresented = true },
            toolbarMenu: toolbar
        ))
    }

    /// Resolves the parent group from `AppState.groups` so the
    /// `GroupContextSlot` renders under the identity ribbon. Fines
    /// without a resolvable group (cross-group leak / stale cache)
    /// degrade to no context rather than render a broken header.
    private func withGroupContext(_ config: ResourceConfig) -> ResourceConfig {
        guard let group = app.groups.first(where: { $0.id == coordinator.fine.groupId }) else {
            return config
        }
        return ResourceConfig(
            identity: config.identity,
            accent: config.accent,
            hero: config.hero,
            actions: config.actions,
            sections: config.sections,
            activity: config.activity,
            toolbarMenu: config.toolbarMenu,
            groupContext: GroupContextData(
                groupName: group.name,
                groupInitials: Self.groupInitials(group.name),
                proposedBy: nil,
                proposedAt: coordinator.fine.createdAt,
                // Tap on group → dismiss the fine detail (same V1 UX as
                // votes; "open GroupHome" requires router access here).
                onTapGroup: { dismiss() }
            )
        )
    }

    private static func groupInitials(_ name: String) -> String {
        let chars = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init)
        return chars.joined().uppercased()
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .short
        return f
    }()

    private static func relativeAgo(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    @MainActor
    private func loadMembers() async {
        let rows = (try? await app.groupsRepo.membersWithProfiles(of: coordinator.fine.groupId)) ?? []
        var dir: [UUID: MemberWithProfile] = [:]
        for row in rows { dir[row.member.userId] = row }
        membersByUserId = dir
    }

    private static func mapActivityEntry(_ entry: ActivityEntry) -> ActivityItem {
        ActivityItem(
            id: entry.id.uuidString,
            title: entry.sentence,
            subtitle: nil,
            timestamp: .now,
            icon: entry.icon,
            kind: .neutral,
            prebakedRelativeTime: entry.relativeTime
        )
    }

    // MARK: - Governance gate

    @MainActor
    private func computeCanVoid() async -> Bool {
        guard let group = app.groups.first(where: { $0.id == coordinator.fine.groupId }),
              let rows = try? await app.groupsRepo.membersWithProfiles(of: coordinator.fine.groupId),
              let member = rows.first(where: { $0.member.userId == coordinator.userId })?.member,
              let decision = try? await app.governance.canPerform(
                  .voidFine, member: member, in: group, context: nil
              )
        else { return false }
        if case .allowed = decision { return true }
        return false
    }

    /// Mirrors `has_permission(group_id, viewer, 'markFinePaid')`. Reads
    /// the viewer's `rawRoles` against `group.effectiveRoles` — same
    /// resolution `GroupHomeCoordinator.hasPermission(_:)` uses. The
    /// permission lets a non-debtor admin record an offline payment;
    /// pay_fine RPC still gates the final write (mig 00273).
    private func computeCanMarkFinePaid() -> Bool {
        guard let group = app.groups.first(where: { $0.id == coordinator.fine.groupId }),
              let viewer = membersByUserId[coordinator.userId]?.member
        else { return false }
        let catalog = group.effectiveRoles
        for raw in viewer.rawRoles {
            if let def = catalog[raw], def.grants(.markFinePaid) { return true }
        }
        return false
    }
}
