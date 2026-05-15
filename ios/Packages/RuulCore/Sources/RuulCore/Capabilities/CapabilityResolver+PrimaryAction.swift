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
    /// - fund                                      → openContribute (Phase 2 wires)
    /// - asset                                     → openBooking (Phase 2 wires)
    /// - space, slot, right, unknown               → none
    func primaryAction(
        for resource: ResourceRow,
        viewerRole: MemberRole,
        rsvpStatus: RSVPStatus?,
        eventStatus: EventStatus?,
        enabledCapabilities: Set<String>
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
            return PrimaryAction(
                label: "Aportar",
                symbol: "plus.circle.fill",
                style: .prominent,
                kind: .openContribute
            )
        case .asset:
            return PrimaryAction(
                label: "Reservar",
                symbol: "calendar.badge.plus",
                style: .prominent,
                kind: .openBooking
            )
        case .space, .slot, .right, .unknown:
            return .none
        }
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
