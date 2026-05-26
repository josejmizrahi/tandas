import Foundation
import RuulCore

/// Builder for Event resources. Produces the universal `ResourceBlocks`
/// tree from an `EventDetailSnapshot` assembled by the host.
///
/// All event-specific decisions live here — the `UniversalResourceDetailView`
/// renders the result with zero knowledge of events.
///
/// Rotation block per Addendum E.5:
///   - Next-host index: `((cycle - 1 - cycleOffset) % count + count) % count`
///     (mig 00336 formula — handles negative modulo in Swift).
///   - Always included when rotation module is active.
///
/// Location block per Addendum E.5:
///   - Always included for events (no capability gate — the capability
///     flag is unreliable pre-mig 00340).
///
/// RSVP block:
///   - Included when the `rsvp` module is active and event is not closed.
public struct EventBlockBuilder: BlockBuilder {
    public typealias Source = EventDetailSnapshot

    public init() {}

    // MARK: - BlockBuilder

    public func build(
        source: EventDetailSnapshot,
        viewer: BlockViewerContext,
        now: Date
    ) -> ResourceBlocks {
        let isClosed = source.event.status == .closed || source.event.status == .cancelled
        let isHost   = source.viewerIsHost

        let identity = IdentityRibbon(
            icon: "calendar",
            tint: .events,
            title: source.event.title,
            subtitleSegments: ["Evento", source.event.status.displayName]
        )

        let state = makeState(
            source: source,
            isHost: isHost,
            isClosed: isClosed,
            now: now
        )

        let properties = makeProperties(source: source)

        let capabilities = makeCapabilities(
            source: source,
            viewer: viewer,
            isHost: isHost,
            isClosed: isClosed
        )

        return ResourceBlocks(
            identity: identity,
            state: StateHeadlineResolver.normalize(state, fallback: source.event.title),
            properties: properties,
            capabilities: capabilities,
            relations: [],           // Phase 2: resource_links table
            activityHead: [],        // Phase E: wired from SystemEventsRepository
            hasMoreActivity: false
        )
    }

    // MARK: - State Headline

    private func makeState(
        source: EventDetailSnapshot,
        isHost: Bool,
        isClosed: Bool,
        now: Date
    ) -> StateHeadline {
        if isClosed {
            return StateHeadline(
                headline: "Cerrado",
                supportingFacts: [source.event.status.displayName],
                primaryAction: nil,
                urgency: .terminal
            )
        }
        if isHost {
            return StateHeadline(
                headline: "Eres anfitrión",
                supportingFacts: [relativeDay(from: source.event.startsAt, now: now)],
                primaryAction: nil,
                urgency: .actionable
            )
        }
        if source.myRSVP == nil {
            return StateHeadline(
                headline: "Confirma si vienes",
                supportingFacts: [relativeDay(from: source.event.startsAt, now: now)],
                primaryAction: PrimaryAction(
                    label: "Confirmar asistencia",
                    symbol: "checkmark.circle",
                    style: .standard,
                    kind: .rsvpConfirm
                ),
                urgency: .actionable
            )
        }
        // FASE 3 C.2 surface 4: attendee with RSVP=going and not yet
        // checked-in gets a "Ya llegué" one-shot. Server (mig 00236) lets
        // any user self check-in (`auth.uid() = p_user_id`) regardless of
        // event status, so we mirror that here — no event-status gate.
        if let rsvp = source.myRSVP,
           rsvp.status == .going,
           !rsvp.isCheckedIn {
            return StateHeadline(
                headline: "¿Ya llegaste?",
                supportingFacts: [relativeDay(from: source.event.startsAt, now: now)],
                primaryAction: PrimaryAction(
                    label: "Ya llegué",
                    symbol: "figure.wave",
                    style: .standard,
                    kind: .selfCheckIn
                ),
                urgency: .actionable
            )
        }
        let rsvpLabel = source.myRSVP?.status.displayName ?? ""
        let checkInFact = source.myRSVP?.isCheckedIn == true ? "Llegaste" : rsvpLabel
        return StateHeadline(
            headline: "Asistencia confirmada",
            supportingFacts: [
                relativeDay(from: source.event.startsAt, now: now),
                checkInFact
            ],
            primaryAction: nil,
            urgency: .ambient
        )
    }

    // MARK: - Properties

    private func makeProperties(source: EventDetailSnapshot) -> PropertiesBlock {
        var rows: [FactRow] = [
            FactRow(id: "starts_at", key: "Cuándo", value: shortDate(source.event.startsAt))
        ]
        if let duration = source.event.durationMinutes > 0 ? source.event.durationMinutes : nil {
            rows.append(FactRow(id: "duration", key: "Duración", value: "\(duration) min"))
        }
        return PropertiesBlock(rows: rows)
    }

    // MARK: - Capabilities

    private func makeCapabilities(
        source: EventDetailSnapshot,
        viewer: BlockViewerContext,
        isHost: Bool,
        isClosed: Bool
    ) -> [CapabilityBlock] {
        var out: [CapabilityBlock] = []

        // RSVP block — active module + event not closed
        if viewer.activeModules.contains("rsvp") && !isClosed {
            out.append(makeRSVPBlock(source: source))
        }

        // Rotation block — active module + event not closed (Addendum E.5)
        if viewer.activeModules.contains("rotating_host") && !isClosed {
            out.append(makeRotationBlock(source: source))
        }

        // Location block — always included for events (Addendum E.5)
        out.append(makeLocationBlock(source: source))

        return out
    }

    // MARK: - RSVP Block

    private func makeRSVPBlock(source: EventDetailSnapshot) -> CapabilityBlock {
        let viewerNotRSVPd = source.myRSVP == nil
        let rsvpLabel: String
        if viewerNotRSVPd {
            rsvpLabel = "Sin tu respuesta aún · Toca para invitar gente"
        } else {
            rsvpLabel = "Tu respuesta: \(source.myRSVP!.status.displayName) · Toca para invitar gente"
        }
        return CapabilityBlock(
            id: "rsvp",
            title: "Asistencia",
            icon: "person.2",
            layoutKind: .progress,
            payload: CapabilityBlock.Payload(
                progress: CapabilityBlock.ProgressFields(
                    current: 0,       // Live counts wired in Phase E from EventInteractor.rsvps
                    total: 0,
                    label: rsvpLabel
                )
            ),
            // Verb is intentionally "Invitar gente" not "Ver asistencia" —
            // the founder reported users couldn't find the invite affordance.
            // Tapping opens the attendees sheet which exposes the share-
            // join-link surface alongside the RSVP roll.
            footerVerb: "Invitar gente",
            openDestinationId: "rsvp.manager",
            isViewerObligation: viewerNotRSVPd
        )
    }

    // MARK: - Rotation Block (Addendum E.5)

    private func makeRotationBlock(source: EventDetailSnapshot) -> CapabilityBlock {
        guard let rotation = source.rotationConfig,
              !rotation.participants.isEmpty else {
            // Unconfigured → emptyPrompt layout
            return CapabilityBlock(
                id: "rotation",
                title: "Rotación",
                icon: "arrow.2.circlepath",
                layoutKind: .emptyPrompt,
                payload: CapabilityBlock.Payload(
                    emptyPrompt: "Configura quién rota como anfitrión"
                ),
                footerVerb: "Configurar anfitriones",
                openDestinationId: "rotation.participants"
            )
        }

        let count = rotation.participants.count
        let cycle = source.cycleNumber ?? 1
        let offset = rotation.cycleOffset

        // Mig 00336 formula: handles negative modulo in Swift
        let nextIdx = ((cycle - 1 - offset) % count + count) % count
        let nextHostId = rotation.participants[nextIdx]
        let nextHostName = source.memberDirectory[nextHostId]?.displayName ?? shortId(nextHostId)

        // Queue: next 3 after nextIdx (wrapping)
        var queueFacts: [FactRow] = [
            FactRow(id: "next_host", key: "Próximo anfitrión", value: nextHostName)
        ]
        let queueNames: [String] = (1...min(3, count - 1)).map { delta in
            let qIdx = (nextIdx + delta) % count
            let uid = rotation.participants[qIdx]
            return source.memberDirectory[uid]?.displayName ?? shortId(uid)
        }
        if !queueNames.isEmpty {
            queueFacts.append(FactRow(id: "queue", key: "Cola", value: queueNames.joined(separator: " · ")))
        }

        return CapabilityBlock(
            id: "rotation",
            title: "Rotación",
            icon: "arrow.2.circlepath",
            layoutKind: .summaryFacts,
            payload: CapabilityBlock.Payload(facts: queueFacts),
            footerVerb: "Editar anfitriones",
            openDestinationId: "rotation.participants"
        )
    }

    // MARK: - Location Block (Addendum E.5)

    private func makeLocationBlock(source: EventDetailSnapshot) -> CapabilityBlock {
        if let locationName = source.event.locationName, !locationName.isEmpty {
            return CapabilityBlock(
                id: "location",
                title: "Lugar",
                icon: "mappin.and.ellipse",
                layoutKind: .summaryFacts,
                payload: CapabilityBlock.Payload(facts: [
                    FactRow(id: "location_name", key: "Dónde", value: locationName)
                ]),
                footerVerb: "Abrir en Mapas",
                openDestinationId: "location.editor"
            )
        }
        return CapabilityBlock(
            id: "location",
            title: "Lugar",
            icon: "mappin.and.ellipse",
            layoutKind: .emptyPrompt,
            payload: CapabilityBlock.Payload(
                emptyPrompt: "Añadir ubicación"
            ),
            footerVerb: nil,
            openDestinationId: "location.editor"
        )
    }

    // MARK: - Helpers

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func relativeDay(from d: Date, now: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: now, to: d).day ?? 0
        switch days {
        case ..<0:  return "Ya pasó"
        case 0:     return "Hoy"
        case 1:     return "Mañana"
        default:    return "En \(days) días"
        }
    }

    private func shortId(_ uid: UUID) -> String {
        String(uid.uuidString.lowercased().prefix(6))
    }
}
