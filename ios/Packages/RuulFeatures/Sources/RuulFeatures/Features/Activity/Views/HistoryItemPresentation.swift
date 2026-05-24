import Foundation
import RuulUI
import RuulCore

/// Maps a `SystemEvent` to display data for `RuulTimelineItem`. Decouples
/// the timeline UI primitive (icon/title/subtitle/timestamp/tone) from the
/// platform's event-type catalog.
public struct HistoryItemPresentation {
    public let icon: String
    public let title: String
    public let subtitle: String?
    public let timestamp: String
    public let tone: RuulTimelineItem.Tone

    private static func relativeString(for date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "es_MX")
        return f.localizedString(for: date, relativeTo: .now)
    }

    /// P2 (mig 00366): when caller provides `resolveMemberName`, the
    /// `.ledgerEntryCreated` case unpacks the payload's
    /// `paid_by_member_id` and surfaces "pagado por X" when the payer
    /// differs from the actor. Backwards-compat: callers that don't
    /// pass the closure get the prior generic copy.
    public init(
        event: SystemEvent,
        memberName: String? = nil,
        resolveMemberName: ((UUID) -> String?)? = nil
    ) {
        let actor = memberName ?? "Alguien"
        switch event.eventType {
        case .eventCreated:
            self.icon = "calendar.badge.plus"
            self.title = "Se creó un evento"
            self.tone = .info
        case .eventClosed:
            self.icon = "calendar.badge.checkmark"
            self.title = "\(actor) cerró un evento"
            self.tone = .neutral
        case .rsvpDeadlinePassed:
            self.icon = "clock.badge.exclamationmark"
            self.title = "Cerró la deadline de RSVP"
            self.tone = .warning
        case .hoursBeforeEvent:
            self.icon = "clock"
            self.title = "Quedan horas para un evento"
            self.tone = .neutral
        case .rsvpSubmitted:
            self.icon = "checkmark.circle"
            self.title = "\(actor) respondió RSVP"
            self.tone = .positive
        case .rsvpChangedSameDay:
            self.icon = "arrow.uturn.backward.circle"
            self.title = "\(actor) cambió RSVP el mismo día"
            self.tone = .warning
        case .checkInRecorded:
            self.icon = "location.fill"
            self.title = "\(actor) llegó al evento"
            self.tone = .positive
        case .checkInMissed:
            self.icon = "location.slash"
            self.title = "\(actor) no apareció"
            self.tone = .negative
        case .eventDescriptionMissing:
            self.icon = "exclamationmark.bubble"
            self.title = "Falta descripción del evento"
            self.tone = .warning
        case .slotAssigned:
            self.icon = "ticket"
            self.title = "\(actor) recibió un cupo"
            self.tone = .info
        case .slotDeclined:
            self.icon = "ticket"
            self.title = "\(actor) rechazó un cupo"
            self.tone = .neutral
        case .slotExpired:
            self.icon = "ticket"
            self.title = "Un cupo expiró"
            self.tone = .warning
        case .fineOfficialized:
            self.icon = "creditcard.fill"
            self.title = "Se oficializó una multa"
            self.tone = .warning
        case .fineVoided:
            self.icon = "xmark.circle"
            self.title = "Se anuló una multa"
            self.tone = .neutral
        case .finePaid:
            self.icon = "creditcard.and.123"
            self.title = "\(actor) pagó una multa"
            self.tone = .positive
        case .fineReminderSent:
            self.icon = "bell.badge"
            self.title = "Recordatorio de multa pendiente"
            self.tone = .warning
        case .appealCreated:
            self.icon = "scales.tighten"
            self.title = "\(actor) apeló una multa"
            self.tone = .info
        case .appealResolved:
            self.icon = "scales.tighten"
            self.title = "Se resolvió una apelación"
            self.tone = .neutral
        case .voteOpened:
            self.icon = "hand.raised.fill"
            self.title = "Se abrió una votación"
            self.tone = .info
        case .voteCast:
            self.icon = "hand.raised"
            self.title = "\(actor) emitió su voto"
            self.tone = .neutral
        case .voteResolved:
            // Specialize for ledger_review failed → expense reversed.
            // Activity feed shows the same row to everyone (group-scoped);
            // the notification adds a private push to the affected member.
            let voteType = event.payload["vote_type"]?.stringValue
            let resolution = event.payload["resolution"]?.stringValue
            if voteType == "ledger_review" && resolution == "failed" {
                self.icon = "arrow.uturn.backward.circle.fill"
                self.title = "El grupo reversó un gasto"
                self.tone = .warning
            } else if voteType == "ledger_review" && resolution == "passed" {
                self.icon = "checkmark.seal.fill"
                self.title = "El grupo ratificó un gasto"
                self.tone = .positive
            } else {
                self.icon = "hand.thumbsup.fill"
                self.title = "Se cerró una votación"
                self.tone = .positive
            }
        case .fundDeposit:
            self.icon = "banknote.fill"
            self.title = "Se depositó al fondo"
            self.tone = .positive
        case .fundThresholdReached:
            self.icon = "trophy.fill"
            self.title = "El fondo alcanzó la meta"
            self.tone = .positive
        case .positionChanged:
            self.icon = "arrow.2.circlepath"
            self.title = "Cambió la rotación"
            self.tone = .neutral
        case .memberJoined:
            self.icon = "person.crop.circle.badge.plus"
            self.title = "\(actor) se unió al grupo"
            self.tone = .positive
        case .memberLeft:
            self.icon = "person.crop.circle.badge.minus"
            self.title = "\(actor) salió del grupo"
            self.tone = .neutral
        case .slotSwapRequested:
            self.icon = "arrow.left.arrow.right"
            self.title = "\(actor) pidió cambiar un cupo"
            self.tone = .info
        case .slotSwapApproved:
            self.icon = "arrow.left.arrow.right.circle.fill"
            self.title = "Se aprobó un cambio de cupo"
            self.tone = .positive
        case .bookingCreated:
            self.icon = "calendar.badge.plus"
            self.title = "\(actor) reservó un cupo"
            self.tone = .info
        case .bookingCancelled:
            self.icon = "calendar.badge.minus"
            self.title = "\(actor) canceló una reserva"
            self.tone = .neutral
        case .bookingExpired:
            self.icon = "calendar.badge.exclamationmark"
            self.title = "Una reserva expiró"
            self.tone = .warning
        case .assetCreated:
            self.icon = "house.fill"
            self.title = "\(actor) registró un recurso"
            self.tone = .info
        case .fundCreated:
            self.icon = "banknote"
            self.title = "\(actor) creó un fondo"
            self.tone = .info
        case .ruleEnabledChanged:
            self.icon = "switch.2"
            self.title = "\(actor) cambió el estado de una regla"
            self.tone = .neutral
        case .ruleAmountChanged:
            self.icon = "pencil.line"
            self.title = "\(actor) editó la multa de una regla"
            self.tone = .neutral
        case .pendingChangeApplied:
            self.icon = "checkmark.seal"
            self.title = "Se aplicó un cambio aprobado"
            self.tone = .positive
        case .inviteCodeRotated:
            self.icon = "link.badge.plus"
            self.title = "\(actor) rotó el código de invitación"
            self.tone = .neutral
        case .groupCreated:
            self.icon = "person.3.fill"
            self.title = "Se creó el grupo"
            self.tone = .info
        case .groupArchived:
            self.icon = "archivebox"
            self.title = "\(actor) archivó el grupo"
            self.tone = .neutral
        case .groupUnarchived:
            self.icon = "tray.and.arrow.up"
            self.title = "\(actor) restauró el grupo"
            self.tone = .info
        case .groupRenamed:
            self.icon = "pencil"
            self.title = "\(actor) renombró el grupo"
            self.tone = .neutral
        case .governanceUpdated:
            self.icon = "scalemass"
            self.title = "\(actor) actualizó las decisiones del grupo"
            self.tone = .neutral
        case .resourceArchived:
            self.icon = "archivebox"
            self.title = "\(actor) archivó un recurso"
            self.tone = .neutral
        case .resourceUnarchived:
            self.icon = "tray.and.arrow.up"
            self.title = "\(actor) restauró un recurso"
            self.tone = .info
        case .resourceRenamed:
            self.icon = "pencil"
            self.title = "\(actor) renombró un recurso"
            self.tone = .neutral
        case .capabilityToggled:
            self.icon = "switch.2"
            self.title = "\(actor) cambió una capacidad"
            self.tone = .neutral
        case .capabilityConfigUpdated:
            self.icon = "slider.horizontal.3"
            self.title = "\(actor) editó la configuración de una capacidad"
            self.tone = .neutral
        case .memberCapabilityOverridden:
            self.icon = "person.fill.questionmark"
            self.title = "\(actor) aplicó una excepción de miembro"
            self.tone = .neutral
        case .ledgerEntryCreated:
            self.icon = "dollarsign.circle"
            // P2 enrichment: unpack payload to surface tri-role context
            // when present. Falls back to generic copy when the payload
            // doesn't carry the new keys (legacy entries pre-mig 00366).
            self.title = Self.composeLedgerTitle(
                actor: actor,
                payload: event.payload,
                resolveMemberName: resolveMemberName
            )
            self.tone = .neutral
        case .warningEmitted:
            self.icon = "exclamationmark.triangle"
            self.title = "Aviso emitido por regla"
            self.tone = .warning
        case .assetTransferred:
            self.icon = "arrow.left.arrow.right"
            self.title = "\(actor) transfirió un activo"
            self.tone = .info
        case .assetAssigned:
            self.icon = "person.crop.circle.badge.checkmark"
            self.title = "\(actor) recibió un activo"
            self.tone = .info
        case .assetReturned:
            self.icon = "arrow.uturn.backward"
            self.title = "\(actor) devolvió un activo"
            self.tone = .neutral
        case .custodyAssigned:
            self.icon = "person.text.rectangle"
            self.title = "\(actor) quedó como custodio"
            self.tone = .info
        case .custodyReleased:
            self.icon = "person.crop.rectangle.badge.xmark"
            self.title = "\(actor) liberó la custodia"
            self.tone = .neutral
        case .maintenanceLogged:
            self.icon = "wrench.and.screwdriver"
            self.title = "\(actor) registró mantenimiento"
            self.tone = .info
        case .maintenanceCompleted:
            self.icon = "checkmark.seal"
            self.title = "Se cerró un mantenimiento"
            self.tone = .positive
        case .damageReported:
            self.icon = "exclamationmark.triangle.fill"
            self.title = "\(actor) reportó un daño"
            self.tone = .warning
        case .assetUsed:
            self.icon = "hand.tap"
            self.title = "\(actor) usó un activo"
            self.tone = .neutral
        case .assetCheckedOut:
            self.icon = "arrow.up.right.square"
            self.title = "\(actor) sacó prestado un activo"
            self.tone = .info
        case .assetCheckedIn:
            self.icon = "arrow.down.left.square"
            self.title = "Se devolvió un activo"
            self.tone = .positive
        case .valuationRecorded:
            self.icon = "chart.line.uptrend.xyaxis"
            self.title = "\(actor) registró el valor"
            self.tone = .neutral

        // Fund lock lifecycle (mig 00202_fund_writers_balance_lifecycle)
        case .fundLocked:
            self.icon = "lock.fill"
            self.title = "\(actor) bloqueó un fondo"
            self.tone = .warning
        case .fundUnlocked:
            self.icon = "lock.open"
            self.title = "\(actor) desbloqueó un fondo"
            self.tone = .info

        // Right lifecycle (mig 00198_right_resource_canonical)
        case .rightCreated:
            self.icon = "key.fill"
            self.title = "\(actor) creó un derecho"
            self.tone = .info
        case .rightTransferred:
            self.icon = "arrow.left.arrow.right"
            self.title = "\(actor) transfirió un derecho"
            self.tone = .info
        case .rightDelegated:
            self.icon = "person.2.fill"
            self.title = "\(actor) delegó un derecho"
            self.tone = .info
        case .rightRevoked:
            self.icon = "xmark.octagon"
            self.title = "\(actor) revocó un derecho"
            self.tone = .negative
        case .rightExpired:
            self.icon = "clock.badge.xmark"
            self.title = "Un derecho expiró"
            self.tone = .neutral
        case .rightExercised:
            self.icon = "checkmark.seal.fill"
            self.title = "\(actor) ejerció un derecho"
            self.tone = .positive
        case .rightSuspended:
            self.icon = "pause.circle"
            self.title = "\(actor) suspendió un derecho"
            self.tone = .warning
        case .rightRestored:
            self.icon = "arrow.clockwise.circle"
            self.title = "\(actor) restauró un derecho"
            self.tone = .positive
        case .rightExpiringSoon:
            self.icon = "clock.badge.exclamationmark"
            self.title = "Un derecho está por expirar"
            self.tone = .warning

        // Resource links (mig 00202_event_resource_links)
        case .resourceLinked:
            self.icon = "link"
            self.title = "\(actor) vinculó un recurso al evento"
            self.tone = .info
        case .resourceUnlinked:
            self.icon = "link.badge.plus"
            self.title = "\(actor) desvinculó un recurso del evento"
            self.tone = .neutral

        // Event lifecycle — eventCancelled (mig 00203_event_cancelled_atom)
        case .eventCancelled:
            self.icon = "xmark.circle"
            self.title = "\(actor) canceló el evento"
            self.tone = .negative
        // Event lifecycle — eventStarted (mig 00208, cron-emitted)
        case .eventStarted:
            self.icon = "play.circle"
            self.title = "El evento empezó"
            self.tone = .info
        // Event lifecycle — eventUpdated (mig 00210, non-title metadata change)
        case .eventUpdated:
            self.icon = "pencil.and.list.clipboard"
            self.title = "\(actor) actualizó el evento"
            self.tone = .neutral
        // Event lifecycle — eventReopened (mig 00295, status revert to scheduled)
        case .eventReopened:
            self.icon = "arrow.counterclockwise.circle"
            self.title = "\(actor) reabrió el evento"
            self.tone = .info

        // Space lifecycle (mig 00207_space_writers + mig 00264_space_universal_atoms)
        case .spaceCreated:
            self.icon = "building.2"
            self.title = "\(actor) creó un espacio"
            self.tone = .info
        case .spaceBooked:
            self.icon = "calendar.badge.checkmark"
            self.title = "\(actor) reservó un espacio"
            self.tone = .info
        case .spaceReleased:
            self.icon = "arrow.uturn.backward"
            self.title = "Un espacio se liberó"
            self.tone = .neutral
        case .spaceCapacityReached:
            self.icon = "person.3.fill"
            self.title = "Un espacio llegó al aforo"
            self.tone = .warning
        case .spaceWaitlistJoined:
            self.icon = "person.crop.circle.badge.clock"
            self.title = "\(actor) entró a la lista de espera"
            self.tone = .info
        case .spaceWaitlistPromoted:
            self.icon = "person.crop.circle.badge.checkmark"
            self.title = "\(actor) fue promovido desde la lista de espera"
            self.tone = .info
        case .spaceAccessGranted:
            self.icon = "key.fill"
            self.title = "\(actor) recibió acceso a un espacio"
            self.tone = .info
        case .spaceAccessRevoked:
            self.icon = "key.slash"
            self.title = "Se revocó el acceso de \(actor) a un espacio"
            self.tone = .warning

        case .bookingNoCheckIn:
            self.icon = "clock.badge.xmark"
            self.title = "Nadie marcó llegada a la reserva"
            self.tone = .warning

        case .assetCheckoutOverdue:
            self.icon = "clock.badge.exclamationmark"
            self.title = "Un activo no fue devuelto a tiempo"
            self.tone = .warning

        case .assetMaintenanceOverdue:
            self.icon = "wrench.and.screwdriver.fill"
            self.title = "Un mantenimiento lleva demasiado tiempo abierto"
            self.tone = .warning

        case .roleAssigned:
            self.icon = "person.text.rectangle.fill"
            self.title = "\(actor) recibió un rol"
            self.tone = .info

        case .roleUnassigned:
            self.icon = "person.text.rectangle"
            self.title = "\(actor) perdió un rol"
            self.tone = .neutral

        case .unknown:
            self.icon = "questionmark.circle"
            self.title = "Actividad"
            self.tone = .neutral
        }

        self.subtitle = nil
        self.timestamp = Self.relativeString(for: event.occurredAt)
    }

    // MARK: - Ledger entry title composition (P2, mig 00366)

    /// Builds the human-readable title for `.ledgerEntryCreated` by
    /// unpacking the tri-role payload added in mig 00366. Falls back
    /// gracefully when the payload lacks the new keys (legacy entries
    /// emitted pre-mig still render as "X registró un movimiento de
    /// dinero").
    ///
    /// Shape variants:
    /// - expense + paid_by → "X registró un gasto de $Y pagado por Z"
    /// - expense + no paid_by → "X registró un gasto de $Y"
    /// - contribution + in_kind → "X aportó en especie por $Y"
    /// - contribution → "X aportó $Y"
    /// - settlement → "X registró un pago de $Y"
    /// - payout → "X recibió un pago de $Y del fondo"
    private static func composeLedgerTitle(
        actor: String,
        payload: JSONConfig,
        resolveMemberName: ((UUID) -> String?)?
    ) -> String {
        let kind = payload["type"]?.stringValue ?? ""
        let amount = formatAmount(
            cents: payload["amount_cents"]?.intValue,
            currency: payload["currency"]?.stringValue
        )

        // Resolve a richer actor when the generic `memberName` came in
        // as "Alguien". The trigger emits payload.from_member_id for
        // contributions (the contributor IS the actor) and
        // payload.paid_by_member_id for expenses (when present).
        let payloadActor = resolveActorFromPayload(
            payload: payload,
            kind: kind,
            resolveMemberName: resolveMemberName
        )
        let effectiveActor = (actor == "Alguien" ? payloadActor : actor) ?? actor

        switch kind {
        case "expense":
            // P4: if participants array is present + ≥2 entries, surface
            // the split context. Otherwise fall back to the tri-role
            // "pagado por" enrichment.
            let participantsCount: Int? = {
                if case let .array(items) = payload["participants"] {
                    return items.count >= 2 ? items.count : nil
                }
                return nil
            }()
            if let n = participantsCount {
                return amount.isEmpty
                    ? "\(effectiveActor) registró un gasto compartido entre \(n) personas"
                    : "\(effectiveActor) registró \(amount) entre \(n) personas"
            }
            if let paidById = payload["paid_by_member_id"]?.stringValue,
               let paidByUUID = UUID(uuidString: paidById),
               let paidByName = resolveMemberName?(paidByUUID),
               paidByName != effectiveActor {
                return amount.isEmpty
                    ? "\(effectiveActor) registró un gasto pagado por \(paidByName)"
                    : "\(effectiveActor) registró un gasto de \(amount) pagado por \(paidByName)"
            }
            return amount.isEmpty
                ? "\(effectiveActor) registró un gasto"
                : "\(effectiveActor) registró un gasto de \(amount)"
        case "contribution":
            let inKind = payload["in_kind"]?.boolValue == true
            if inKind {
                return amount.isEmpty
                    ? "\(effectiveActor) aportó en especie"
                    : "\(effectiveActor) aportó en especie por \(amount)"
            }
            return amount.isEmpty
                ? "\(effectiveActor) aportó al dinero compartido"
                : "\(effectiveActor) aportó \(amount)"
        case "settlement":
            return amount.isEmpty
                ? "\(effectiveActor) registró un pago"
                : "\(effectiveActor) registró un pago de \(amount)"
        case "payout":
            return amount.isEmpty
                ? "\(effectiveActor) recibió un pago del fondo"
                : "\(effectiveActor) recibió \(amount) del fondo"
        default:
            return "\(effectiveActor) registró un movimiento de dinero"
        }
    }

    /// Resolves an actor display name from the payload's member ids
    /// (from_member_id for contributions, paid_by_member_id for
    /// expenses). Returns nil if neither resolves — caller keeps the
    /// "Alguien" fallback.
    private static func resolveActorFromPayload(
        payload: JSONConfig,
        kind: String,
        resolveMemberName: ((UUID) -> String?)?
    ) -> String? {
        guard let resolve = resolveMemberName else { return nil }
        let candidateIdStrings: [String?] = (kind == "expense")
            ? [payload["paid_by_member_id"]?.stringValue,
               payload["from_member_id"]?.stringValue]
            : [payload["from_member_id"]?.stringValue,
               payload["paid_by_member_id"]?.stringValue]
        for s in candidateIdStrings {
            if let s, let uuid = UUID(uuidString: s), let name = resolve(uuid) {
                return name
            }
        }
        return nil
    }

    /// Formats `(cents, currency)` into a localized currency string.
    /// Returns empty string when either input is missing — caller
    /// falls back to the no-amount copy variant.
    private static func formatAmount(cents: Int?, currency: String?) -> String {
        guard let cents, let currency else { return "" }
        let amount = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        return f.string(from: amount as NSDecimalNumber) ?? ""
    }
}
