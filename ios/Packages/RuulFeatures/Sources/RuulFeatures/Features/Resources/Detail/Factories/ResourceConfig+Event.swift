//
//  ResourceConfig+Event.swift
//  ResourceKit
//
//  Sample `EventInput` model + `ResourceConfig.event(...)` factory.
//  Hosts (e.g. `EventDetailHost`) build an `EventInput` from real domain
//  state and pass it through this factory; the universal shell renders
//  the resulting `ResourceConfig`.
//

import SwiftUI
import MapKit
import CoreLocation
import RuulCore
import RuulUI

// MARK: - EventInput

public struct EventInput {
    public let id: String
    public let title: String
    public let dateLabel: String        // "21 may"
    public let timeLabel: String        // "2:03 p.m."
    public let dayLabel: String         // "Hoy"
    public let durationMin: Int
    public let isHost: Bool
    /// True when the viewer hasn't accepted yet (no RSVP or pending).
    /// Drives the conditional "Confirma asistencia" primary action.
    public let needsRSVPConfirm: Bool
    /// True when the viewer has already RSVP'd `.going`. Swaps the first
    /// action for "Cancelar asistencia" (destructive tint).
    public let viewerIsGoing: Bool
    public let address: String
    public let coordinate: CLLocationCoordinate2D
    public let attendees: [Person]
    public let activity: [ActivityItem]
    /// True when the event was generated from a recurring `ResourceSeries`.
    /// Drives the "Recurrente" badge in `IdentitySlot`. One-off events
    /// keep this false.
    public let isRecurrent: Bool
    /// Pre-formatted recurrence cadence label ("Recurrente · Semanal",
    /// "Recurrente · Mensual · Ciclo 3"). nil for one-off events.
    public let recurrenceLabel: String?

    public init(
        id: String,
        title: String,
        dateLabel: String,
        timeLabel: String,
        dayLabel: String,
        durationMin: Int,
        isHost: Bool,
        needsRSVPConfirm: Bool = false,
        viewerIsGoing: Bool = false,
        address: String,
        coordinate: CLLocationCoordinate2D,
        attendees: [Person],
        activity: [ActivityItem],
        isRecurrent: Bool = false,
        recurrenceLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.dateLabel = dateLabel
        self.timeLabel = timeLabel
        self.dayLabel = dayLabel
        self.durationMin = durationMin
        self.isHost = isHost
        self.needsRSVPConfirm = needsRSVPConfirm
        self.viewerIsGoing = viewerIsGoing
        self.address = address
        self.coordinate = coordinate
        self.attendees = attendees
        self.activity = activity
        self.isRecurrent = isRecurrent
        self.recurrenceLabel = recurrenceLabel
    }
}

// MARK: - Factory

public extension ResourceConfig {

    // MARK: Evento

    static func event(
        _ event: EventInput,
        onInvite: @escaping () -> Void = {},
        onEdit: @escaping () -> Void = {},
        onRotateHost: @escaping () -> Void = {},
        onSeeAllAttendees: @escaping () -> Void = {},
        onRSVPConfirm: @escaping () -> Void = {},
        onRSVPCancel: @escaping () -> Void = {},
        onAddToCalendar: @escaping () -> Void = {},
        toolbarMenu: [ToolbarMenuItem] = [],
        moneyContext: MoneyContext? = nil
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.events.color

        // Actions row, capped at 3. RSVP state takes precedence over the
        // host workflow: an event creator is still an attendee until they
        // confirm, and the old surface showed "Sin tu respuesta aún" for
        // hosts who hadn't yet RSVP'd themselves. So:
        //   - Anyone with no RSVP / pending:
        //        [Confirma asistencia (success), Invitar, Editar]   if host
        //        [Confirma asistencia, Compartir, Calendario]       otherwise
        //   - Anyone going + host: [Invitar, Editar, Rotar]
        //   - Anyone going + non-host: [Cancelar (error), Compartir, Calendario]
        //   - Declined / closed + non-host: [Compartir, Calendario]
        let actions: [ResourceAction]
        if event.needsRSVPConfirm {
            let confirm = ResourceAction(
                label: "Confirma asistencia",
                icon: "checkmark",
                tint: .ruulSemanticSuccess,
                handler: onRSVPConfirm
            )
            if event.isHost {
                actions = [
                    confirm,
                    ResourceAction(label: "Invitar", icon: "plus", handler: onInvite),
                    ResourceAction(label: "Editar", handler: onEdit)
                ]
            } else {
                actions = [
                    confirm,
                    ResourceAction(label: "Compartir", icon: "square.and.arrow.up", handler: onInvite),
                    ResourceAction(label: "Calendario", icon: "calendar.badge.plus", handler: onAddToCalendar)
                ]
            }
        } else if event.isHost {
            actions = [
                ResourceAction(label: "Invitar", icon: "plus", handler: onInvite),
                ResourceAction(label: "Editar", handler: onEdit),
                ResourceAction(label: "Rotar", handler: onRotateHost)
            ]
        } else if event.viewerIsGoing {
            actions = [
                ResourceAction(label: "Cancelar", icon: "xmark", tint: .ruulSemanticError, handler: onRSVPCancel),
                ResourceAction(label: "Compartir", icon: "square.and.arrow.up", handler: onInvite),
                ResourceAction(label: "Calendario", icon: "calendar.badge.plus", handler: onAddToCalendar)
            ]
        } else {
            actions = [
                ResourceAction(label: "Compartir", icon: "square.and.arrow.up", handler: onInvite),
                ResourceAction(label: "Calendario", icon: "calendar.badge.plus", handler: onAddToCalendar)
            ]
        }

        // Metadata under the title — adds the recurrence cadence so the
        // viewer can tell a one-off from a recurring instance at a glance.
        var identityMetadata: [String] = [event.dayLabel]
        if let recurrence = event.recurrenceLabel {
            identityMetadata.append(recurrence)
        } else if event.isRecurrent {
            identityMetadata.append("Recurrente")
        }

        // When recurrent, prepend a "Detalles" row section so the cadence
        // is also a tappable / scannable property, not just a tag.
        var sections: [ResourceSection] = []
        if let recurrence = event.recurrenceLabel ?? (event.isRecurrent ? "Recurrente" : nil) {
            sections.append(.rows(title: "Detalles", items: [
                RowItem(icon: "arrow.triangle.2.circlepath", label: "Recurrencia", value: .text(recurrence))
            ]))
        }
        sections.append(contentsOf: [
            .map(
                title: "Lugar",
                location: MapLocation(
                    coordinate: event.coordinate,
                    address: event.address
                )
            ),
            .avatars(
                title: "Asistencia",
                people: event.attendees,
                emptyText: "Aún nadie invitado",
                onTapMore: onSeeAllAttendees
            )
        ])

        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "calendar",
                name: event.title,
                typeLabel: "Evento",
                metadata: identityMetadata,
                badge: event.isHost ? ResourceBadge(text: "Anfitrión", color: accent) : nil
            ),
            accent: accent,
            hero: HeroData(
                value: event.timeLabel,
                label: "\(event.dateLabel) · \(event.durationMin) min de duración",
                size: .title
            ),
            actions: actions,
            sections: sections,
            activity: .static(event.activity),
            toolbarMenu: toolbarMenu,
            moneyContext: moneyContext
        )
    }
}
