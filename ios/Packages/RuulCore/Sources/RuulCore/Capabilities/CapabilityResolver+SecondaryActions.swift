import Foundation

public extension CapabilityResolver {
    /// Items for the nav bar `⋯` menu, in display order.
    ///
    /// The caller groups consecutive items by `section` to draw visual
    /// separators between sections. Items within a section appear in the
    /// order returned here.
    ///
    /// Sprint E (V15 fix): the canonical signature takes
    /// `viewerPermissions: Set<Permission>` (the set the viewer's roles
    /// grant, computed once at the call site against the catalog) plus
    /// `viewerIsEventHost: Bool` (the contextual per-event flag — host
    /// is NOT a permission, it's an assignment). Custom roles
    /// (`seat_owner`, `treasurer_aux`, …) reach the gating logic via the
    /// permissions they grant; nothing is collapsed into a single
    /// `MemberRole` enum value anymore. The legacy `viewerRole:` overload
    /// below preserves existing test fixtures.
    func secondaryActions(
        for resource: ResourceRow,
        viewerPermissions: Set<Permission>,
        viewerIsEventHost: Bool = false,
        viewerCanIssueManualFine: Bool,
        enabledCapabilities: Set<String>,
        viewerUserId: UUID? = nil
    ) -> [SecondaryAction] {
        switch resource.resourceType {
        case .event:
            return eventSecondaryActions(
                eventStatus: resource.status,
                viewerPermissions: viewerPermissions,
                viewerIsEventHost: viewerIsEventHost,
                viewerCanIssueManualFine: viewerCanIssueManualFine,
                enabledCapabilities: enabledCapabilities
            )
        case .right:
            return rightSecondaryActions(
                resource: resource,
                viewerPermissions: viewerPermissions,
                viewerUserId: viewerUserId
            )
        case .fund:
            return fundSecondaryActions(
                resource: resource,
                viewerPermissions: viewerPermissions
            )
        default:
            return commonSecondaryActions(viewerPermissions: viewerPermissions)
        }
    }

    /// LEGACY overload (Sprint E.3 transitional). Delegates to the
    /// permissions-based canonical method. Kept so test fixtures that
    /// pass `viewerRole: .founder | .host | .member` continue to work
    /// without churn. New call sites must use the `viewerPermissions:`
    /// overload above. Will be removed once tests migrate.
    func secondaryActions(
        for resource: ResourceRow,
        viewerRole: MemberRole,
        viewerCanIssueManualFine: Bool,
        enabledCapabilities: Set<String>,
        viewerUserId: UUID? = nil
    ) -> [SecondaryAction] {
        secondaryActions(
            for: resource,
            viewerPermissions: Self.legacyPermissions(for: viewerRole),
            viewerIsEventHost: viewerRole == .host,
            viewerCanIssueManualFine: viewerCanIssueManualFine,
            enabledCapabilities: enabledCapabilities,
            viewerUserId: viewerUserId
        )
    }

    /// Static mapping from the legacy `MemberRole` enum to the permission
    /// set founder/admin roles carry in the default catalog (mirrors
    /// server defaults from mig 00262 + 00255). `.member`, `.host`,
    /// `.observer`, `.arbiter` get an empty set — host bypass is
    /// carried separately via `viewerIsEventHost`.
    static func legacyPermissions(for role: MemberRole) -> Set<Permission> {
        switch role {
        case .founder, .admin:
            return [
                .modifyGovernance, .modifyRules, .modifyMembers,
                .assignRoles, .removeMember,
                .issueFine, .voidFine, .markFinePaid, .closeAppeal,
                .createVotes, .castVote,
                .manageEvents, .manageModules,
                .transferRight, .delegateRight, .revokeRight,
                .suspendRight, .exerciseRight,
                .fundContribute, .fundWithdraw, .fundAudit,
                .expenseSubmit, .expenseApprove
            ]
        case .treasurer:
            return [.fundContribute, .fundWithdraw, .fundAudit,
                    .expenseSubmit, .expenseApprove,
                    .issueFine, .markFinePaid]
        case .member, .host, .observer, .arbiter:
            return [.createVotes, .castVote]
        }
    }

    /// Menu for `fund` resources. Admin-only Registrar gasto + Archivar
    /// plus the universal Compartir floor. Lock / unlock are surfaced
    /// inline in MoneySectionView's fundLockRow (gated on
    /// viewerIsAdmin + resource.type=fund) — keeping every fund admin
    /// control grouped with the dinero card avoids two menus pointing
    /// at the same lifecycle.
    private func fundSecondaryActions(
        resource: ResourceRow,
        viewerPermissions: Set<Permission>
    ) -> [SecondaryAction] {
        var items: [SecondaryAction] = []

        items.append(SecondaryAction(
            label: "Compartir",
            symbol: "square.and.arrow.up",
            section: .primary,
            kind: .share
        ))

        // Sprint E (V15): permission-based gating instead of role-name
        // compare. Registrar gasto → fundWithdraw. Archivar → modifyGovernance
        // (matches server-side archive_resource gate after mig 00291).
        if viewerPermissions.contains(.fundWithdraw) {
            items.append(SecondaryAction(
                label: "Registrar gasto",
                symbol: "arrow.up.circle",
                section: .money,
                kind: .recordExpenseFromFund
            ))
        }
        if viewerPermissions.contains(.modifyGovernance) {
            items.append(SecondaryAction(
                label: "Archivar",
                symbol: "archivebox",
                section: .danger,
                kind: .archive,
                isDestructive: true
            ))
        }

        return items
    }

    // MARK: - Per-type builders

    private func eventSecondaryActions(
        eventStatus: String,
        viewerPermissions: Set<Permission>,
        viewerIsEventHost: Bool,
        viewerCanIssueManualFine: Bool,
        enabledCapabilities: Set<String>
    ) -> [SecondaryAction] {
        var items: [SecondaryAction] = []

        // Sprint E (V15): permission-based gating. Host bypass kept via
        // explicit viewerIsEventHost flag — host is a contextual assignment,
        // not a permission. manageEvents covers "admin can edit/close/cancel
        // any event"; host gets the same bypass for their own event.
        let isHost    = viewerIsEventHost
        let isAdmin   = viewerPermissions.contains(.manageEvents)

        // --- Primary section: universal actions ---
        if isHost || isAdmin {
            items.append(SecondaryAction(
                label: "Editar detalles",
                symbol: "pencil",
                section: .primary,
                kind: .editDetails
            ))
        }
        items.append(SecondaryAction(
            label: "Compartir",
            symbol: "square.and.arrow.up",
            section: .primary,
            kind: .share
        ))
        items.append(SecondaryAction(
            label: "Agregar al calendario",
            symbol: "calendar.badge.plus",
            section: .primary,
            kind: .addToCalendar
        ))
        items.append(SecondaryAction(
            label: "Pase de Wallet",
            symbol: "wallet.pass",
            section: .primary,
            kind: .generateWalletPass
        ))

        // --- Host section: host management actions ---
        if isHost {
            let isClosedOrCancelled = (eventStatus == "completed" || eventStatus == "cancelled")
            if !isClosedOrCancelled {
                items.append(SecondaryAction(
                    label: "Recordar a invitados",
                    symbol: "bell.badge",
                    section: .host,
                    kind: .remindAttendees
                ))
                items.append(SecondaryAction(
                    label: "Cerrar evento",
                    symbol: "checkmark.seal",
                    section: .host,
                    kind: .closeEvent
                ))
                items.append(SecondaryAction(
                    label: "Cancelar evento",
                    symbol: "xmark.octagon",
                    section: .host,
                    kind: .cancelEvent,
                    isDestructive: true
                ))
            } else {
                // Mig 00295: host or manageEvents can reverse close/cancel
                // (server enforces permission). Replace close/cancel with
                // reopen for closed/cancelled events.
                items.append(SecondaryAction(
                    label: "Reabrir evento",
                    symbol: "arrow.uturn.backward.circle",
                    section: .host,
                    kind: .reopenEvent
                ))
            }
        }

        // --- Money section: ledger and fines ---
        if enabledCapabilities.contains("ledger") {
            items.append(SecondaryAction(
                label: "Ledger",
                symbol: "list.bullet.rectangle",
                section: .money,
                kind: .openLedger
            ))
        }
        if viewerCanIssueManualFine {
            items.append(SecondaryAction(
                label: "Multa manual",
                symbol: "exclamationmark.triangle",
                section: .money,
                kind: .issueManualFine,
                isDestructive: true
            ))
        }

        // --- Governance section: rules and capabilities ---
        if enabledCapabilities.contains("rules") || enabledCapabilities.contains("appeal_voting") {
            items.append(SecondaryAction(
                label: "Acuerdos",
                symbol: "doc.text",
                section: .governance,
                kind: .openRules
            ))
        }

        // --- Danger section: destructive admin actions ---
        // Archive uses the same modifyGovernance gate as the server-side
        // archive_resource RPC (mig 00291).
        if viewerPermissions.contains(.modifyGovernance) {
            items.append(SecondaryAction(
                label: "Archivar",
                symbol: "archivebox",
                section: .danger,
                kind: .archive,
                isDestructive: true
            ))
        }

        return items
    }

    /// Menu for `right` resources. Action visibility depends on:
    ///   - resource.metadata.transferable / delegable / status
    ///   - viewer's role (founder gets admin-only revoke/suspend/restore)
    ///   - whether viewer is the holder or active delegate (Exercise)
    ///
    /// Affirmative-only: actions that would fail server-side are hidden
    /// rather than shown disabled. A user with no claim sees only
    /// "Compartir"; a holder of a non-transferable right doesn't see
    /// the Transfer button. Mirrors the spec stance "el usuario NO debe
    /// ver complejidad legal" — the menu lists what THIS member can
    /// actually do with THIS right today.
    private func rightSecondaryActions(
        resource: ResourceRow,
        viewerPermissions: Set<Permission>,
        viewerUserId: UUID?
    ) -> [SecondaryAction] {
        var items: [SecondaryAction] = []
        let metadata = resource.metadata

        // Sprint E (V15): per-action permission gates instead of "isAdmin"
        // proxy. Each right action ships its own permission (mig 00255 +
        // 00291): transferRight, delegateRight, revokeRight, suspendRight,
        // exerciseRight. Edit details + archive use modifyGovernance.
        let canEdit     = viewerPermissions.contains(.modifyGovernance)
        let canTransfer = viewerPermissions.contains(.transferRight)
        let canDelegate = viewerPermissions.contains(.delegateRight)
        let canSuspend  = viewerPermissions.contains(.suspendRight)
        let canRestore  = viewerPermissions.contains(.suspendRight)
        let canRevoke   = viewerPermissions.contains(.revokeRight)

        let isActive = resource.status == "active"
        let isRevoked = resource.status == "revoked"
        let isSuspended = metadata["suspended_until"]?.stringValue != nil
            || metadata["suspended_at"]?.stringValue != nil

        let holderUserId: UUID? = {
            guard let raw = metadata["holder_user_id"]?.stringValue else { return nil }
            return UUID(uuidString: raw)
        }()
        let delegateUserId: UUID? = {
            guard let raw = metadata["delegate_user_id"]?.stringValue else { return nil }
            return UUID(uuidString: raw)
        }()
        let isHolder = viewerUserId != nil && viewerUserId == holderUserId
        let isDelegate = viewerUserId != nil && viewerUserId == delegateUserId

        items.append(SecondaryAction(
            label: "Compartir",
            symbol: "square.and.arrow.up",
            section: .primary,
            kind: .share
        ))

        // Edit details: admin only. Surfaces the EditRightSheet which
        // wraps `update_right_metadata` (mig 00199). Tuneable knobs:
        // name, priority, exclusive/transferable/delegable/divisible,
        // expires_at, source, scope, target_resource_id, target_capability.
        // Holder + delegate + status stay on dedicated lifecycle RPCs
        // (transfer/delegate/revoke/etc.) so atom emission is correct.
        if canEdit {
            items.append(SecondaryAction(
                label: "Editar detalles",
                symbol: "pencil",
                section: .primary,
                kind: .editDetails
            ))
        }

        // Exercise: holder or active delegate, right is active + not
        // suspended. Server-side `exercise_right` rejects everyone else,
        // so the UI hides the button to avoid presenting an action that
        // would fail.
        if (isHolder || isDelegate) && isActive && !isSuspended {
            items.append(SecondaryAction(
                label: "Ejercer",
                symbol: "hand.tap",
                section: .primary,
                kind: .exerciseRight
            ))
        }

        // Transfer: holder of a transferable + active + not-suspended
        // right. Admin can transfer too (the server allows any group
        // member to call when transferable=true, but the UX intent is
        // holder-owns-the-decision).
        let isTransferable = metadata["transferable"]?.boolValue == true
        if (isHolder || canTransfer) && isTransferable && isActive && !isSuspended {
            items.append(SecondaryAction(
                label: "Transferir",
                symbol: "arrow.left.arrow.right",
                section: .primary,
                kind: .transferRight
            ))
        }

        // Delegate: holder of a delegable + active right.
        let isDelegable = metadata["delegable"]?.boolValue == true
        if (isHolder || canDelegate) && isDelegable && isActive && !isSuspended {
            items.append(SecondaryAction(
                label: "Delegar",
                symbol: "person.line.dotted.person",
                section: .primary,
                kind: .delegateRight
            ))
        }

        // Governance section: suspend/restore (suspendRight permission)
        // and revoke (revokeRight permission).
        if canSuspend && isActive && !isSuspended {
            items.append(SecondaryAction(
                label: "Suspender",
                symbol: "pause.circle",
                section: .governance,
                kind: .suspendRight
            ))
        }
        if canRestore && (isSuspended || isRevoked) {
            items.append(SecondaryAction(
                label: "Restaurar",
                symbol: "arrow.counterclockwise.circle",
                section: .governance,
                kind: .restoreRight
            ))
        }

        // Danger section: revoke (revokeRight permission, terminal-ish).
        if canRevoke && !isRevoked {
            items.append(SecondaryAction(
                label: "Revocar",
                symbol: "xmark.octagon",
                section: .danger,
                kind: .revokeRight,
                isDestructive: true
            ))
        }

        return items
    }

    private func commonSecondaryActions(viewerPermissions: Set<Permission>) -> [SecondaryAction] {
        var items: [SecondaryAction] = []

        items.append(SecondaryAction(
            label: "Compartir",
            symbol: "square.and.arrow.up",
            section: .primary,
            kind: .share
        ))

        // Doctrine: capabilities are auto-on at resource creation and
        // never user-visible. `.enableCapability` is no longer emitted
        // here. The SecondaryAction.Kind case stays defined for future
        // re-use if a use-case ever needs a "turn this on" prompt inline.
        if viewerPermissions.contains(.modifyGovernance) {
            items.append(SecondaryAction(
                label: "Archivar",
                symbol: "archivebox",
                section: .danger,
                kind: .archive,
                isDestructive: true
            ))
        }

        return items
    }
}

