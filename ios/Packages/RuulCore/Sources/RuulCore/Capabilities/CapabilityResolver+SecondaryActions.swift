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
        enabledCapabilities: Set<String>
    ) -> [SecondaryAction] {
        switch resource.resourceType {
        case .event:
            return eventSecondaryActions(
                viewerRole: viewerRole,
                viewerCanIssueManualFine: viewerCanIssueManualFine,
                enabledCapabilities: enabledCapabilities
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

