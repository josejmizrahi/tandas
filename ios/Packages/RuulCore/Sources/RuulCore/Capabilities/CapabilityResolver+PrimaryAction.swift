import Foundation

public extension CapabilityResolver {
    /// Decides the single primary CTA for the resource detail screen.
    /// Returns `.none` when no action applies — caller should hide the
    /// sticky footer entirely.
    ///
    /// Decision matrix:
    /// - event + cancelled                         → none
    /// - event + closed (completed)                → viewClosed
    /// - event + open/in-progress + viewer is host → viewHostActions
    /// - event + open + has rsvp + not RSVP'd      → rsvpConfirm
    /// - event + open + has rsvp + RSVP'd .going   → rsvpCancel
    /// - event without rsvp capability             → none
    /// - fund with ledger capability               → openContribute
    /// - fund without ledger capability            → none
    /// - asset                                     → none (bookings section's
    ///   inline "+ Nuevo" button is the canonical add path; the CTA at the
    ///   bottom would just route to the same flow at the cost of
    ///   "Reservar"-shaped misleading copy when booking is disabled)
    /// - right + viewer is holder/delegate + active + !suspended → exerciseRight
    /// - space, slot, unknown                      → none
    func primaryAction(
        for resource: ResourceRow,
        viewerRole: MemberRole,
        rsvpStatus: RSVPStatus?,
        eventStatus: EventStatus?,
        enabledCapabilities: Set<String>,
        viewerUserId: UUID? = nil
    ) -> PrimaryAction {
        switch resource.resourceType {
        case .event:
            return eventPrimaryAction(
                viewerRole: viewerRole,
                rsvpStatus: rsvpStatus,
                eventStatus: eventStatus,
                enabledCapabilities: enabledCapabilities
            )
        case .fund:
            // Locked fund: contributions still record (fund_contribute
            // doesn't reject on lock per Constitution §9 — locks are
            // soft policy, rules enforce them). The button stays visible
            // but a future enhancement can disable it when a "no-write"
            // rule resolves true.
            guard enabledCapabilities.contains("ledger")
                  || enabledCapabilities.contains("money") else {
                return .none
            }
            return PrimaryAction(
                label: "Aportar",
                symbol: "plus.circle.fill",
                style: .prominent,
                kind: .openContribute
            )
        case .right:
            return rightPrimaryAction(
                resource: resource,
                viewerUserId: viewerUserId
            )
        case .asset, .space, .slot, .unknown:
            return .none
        }
    }

    /// Right's primary CTA is "Ejercer" when the viewer is the holder
    /// OR the active delegate AND the right is active + not suspended.
    /// Otherwise the sticky footer is hidden (no `.none` CTA renders).
    /// Mirrors the visibility rules used by `rightSecondaryActions`
    /// for the Exercise menu entry — same intent: don't show an
    /// action that would fail server-side.
    private func rightPrimaryAction(
        resource: ResourceRow,
        viewerUserId: UUID?
    ) -> PrimaryAction {
        guard let viewerUserId else { return .none }
        guard resource.status == "active" else { return .none }
        let metadata = resource.metadata
        let isSuspended = metadata["suspended_until"]?.stringValue != nil
            || metadata["suspended_at"]?.stringValue != nil
        if isSuspended { return .none }

        let holderUid = metadata["holder_user_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let delegateUid = metadata["delegate_user_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let isHolder = viewerUserId == holderUid
        let isDelegate = viewerUserId == delegateUid

        guard isHolder || isDelegate else { return .none }

        return PrimaryAction(
            label: "Ejercer",
            symbol: "hand.tap",
            style: .prominent,
            kind: .exerciseRight
        )
    }

    // MARK: - Private helpers

    private func eventPrimaryAction(
        viewerRole: MemberRole,
        rsvpStatus: RSVPStatus?,
        eventStatus: EventStatus?,
        enabledCapabilities: Set<String>
    ) -> PrimaryAction {
        // Cancelled → no CTA at all (terminal state, nothing to do)
        if eventStatus == .cancelled {
            return .none
        }

        // Closed (completed) → history-only CTA (read-only retrospective)
        if eventStatus == .closed {
            return PrimaryAction(
                label: "Ver historial",
                symbol: "clock.arrow.circlepath",
                style: .standard,
                kind: .viewClosed
            )
        }

        // Open or in-progress + host → host actions sheet
        if viewerRole == .host || viewerRole == .founder {
            return PrimaryAction(
                label: "Acciones de host",
                symbol: "person.badge.shield.checkmark",
                style: .prominent,
                kind: .viewHostActions
            )
        }

        // Open + no rsvp capability → nothing for member to do via CTA
        if !enabledCapabilities.contains("rsvp") {
            return .none
        }

        // Open + has rsvp + viewer going → cancel option
        if rsvpStatus == .going {
            return PrimaryAction(
                label: "Cancelar mi asistencia",
                symbol: "xmark.circle",
                style: .standard,
                kind: .rsvpCancel
            )
        }

        // Default: confirm (covers nil rsvpStatus, .pending, .maybe, .declined, .waitlisted)
        return PrimaryAction(
            label: "Confirmar mi asistencia",
            symbol: "checkmark.circle.fill",
            style: .prominent,
            kind: .rsvpConfirm
        )
    }
}
