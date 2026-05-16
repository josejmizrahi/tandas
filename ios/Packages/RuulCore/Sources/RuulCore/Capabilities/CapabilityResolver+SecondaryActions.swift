import Foundation

public extension CapabilityResolver {
    /// Items for the nav bar `⋯` menu, in display order.
    ///
    /// The caller groups consecutive items by `section` to draw visual
    /// separators between sections. Items within a section appear in the
    /// order returned here.
    ///
    /// Permission gating (e.g. can THIS user issue a fine?) is passed in as
    /// pre-computed flags (`viewerCanIssueManualFine`) so the resolver stays
    /// synchronous and testable without async governance calls.
    func secondaryActions(
        for resource: ResourceRow,
        viewerRole: MemberRole,
        viewerCanIssueManualFine: Bool,
        enabledCapabilities: Set<String>,
        viewerUserId: UUID? = nil
    ) -> [SecondaryAction] {
        switch resource.resourceType {
        case .event:
            return eventSecondaryActions(
                viewerRole: viewerRole,
                viewerCanIssueManualFine: viewerCanIssueManualFine,
                enabledCapabilities: enabledCapabilities
            )
        case .right:
            return rightSecondaryActions(
                resource: resource,
                viewerRole: viewerRole,
                viewerUserId: viewerUserId
            )
        default:
            return commonSecondaryActions(viewerRole: viewerRole)
        }
    }

    // MARK: - Per-type builders

    private func eventSecondaryActions(
        viewerRole: MemberRole,
        viewerCanIssueManualFine: Bool,
        enabledCapabilities: Set<String>
    ) -> [SecondaryAction] {
        var items: [SecondaryAction] = []

        let isHost    = viewerRole == .host
        let isAdmin   = viewerRole == .founder

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
        if isAdmin {
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
        viewerRole: MemberRole,
        viewerUserId: UUID?
    ) -> [SecondaryAction] {
        var items: [SecondaryAction] = []
        let metadata = resource.metadata

        let isAdmin = viewerRole == .founder
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
        if isAdmin {
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
        if (isHolder || isAdmin) && isTransferable && isActive && !isSuspended {
            items.append(SecondaryAction(
                label: "Transferir",
                symbol: "arrow.left.arrow.right",
                section: .primary,
                kind: .transferRight
            ))
        }

        // Delegate: holder of a delegable + active right.
        let isDelegable = metadata["delegable"]?.boolValue == true
        if (isHolder || isAdmin) && isDelegable && isActive && !isSuspended {
            items.append(SecondaryAction(
                label: "Delegar",
                symbol: "person.line.dotted.person",
                section: .primary,
                kind: .delegateRight
            ))
        }

        // Governance section: admin-only suspend/restore/revoke.
        if isAdmin && isActive && !isSuspended {
            items.append(SecondaryAction(
                label: "Suspender",
                symbol: "pause.circle",
                section: .governance,
                kind: .suspendRight
            ))
        }
        if isAdmin && (isSuspended || isRevoked) {
            items.append(SecondaryAction(
                label: "Restaurar",
                symbol: "arrow.counterclockwise.circle",
                section: .governance,
                kind: .restoreRight
            ))
        }

        // Danger section: revoke (admin only, terminal-ish).
        if isAdmin && !isRevoked {
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

    private func commonSecondaryActions(viewerRole: MemberRole) -> [SecondaryAction] {
        var items: [SecondaryAction] = []

        items.append(SecondaryAction(
            label: "Compartir",
            symbol: "square.and.arrow.up",
            section: .primary,
            kind: .share
        ))

        let isAdmin = viewerRole == .founder
        if isAdmin {
            items.append(SecondaryAction(
                label: "Activar capability",
                symbol: "switch.2",
                section: .governance,
                kind: .enableCapability
            ))
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

