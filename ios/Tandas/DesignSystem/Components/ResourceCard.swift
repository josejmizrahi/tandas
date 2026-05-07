import SwiftUI

/// Generic resource card. Switches on `resource.resourceType` to dispatch
/// to the appropriate concrete view body. V1 only `.event` is wired and
/// re-uses the existing `EventCard` primitive — when Phase 2/3/4 ship
/// Slot/Fund/Position/Asset/Contribution, their bodies will hang off the
/// same switch here.
///
/// **Por qué scaffolding y no full HomeView swap V1**: HomeView's hero
/// (`heroTile`) es un render bespoke (4/5 aspect, displayMedium typography,
/// inline RSVP CTA) — no es EventCard. Forwarding 10+ params del hero a
/// través de ResourceCard sería ruido. ResourceCard V1 es scaffolding +
/// router para los consumers que SÍ usan EventCard hoy (`MyFeedView`,
/// `PastEventsView`). HomeView gana acceso a `coordinator.nextResource`
/// como handle resource-shaped, listo para cuando un segundo type llegue.
///
/// Mismo invariante que `EventResource`: `resource.resourceType == .event
/// ⇒ resource is EventResource`. Cast con seguridad dentro del case.
struct ResourceCard: View {
    let resource: any ResourceProtocol
    let myStatus: RSVPStatus?
    let isHostedByMe: Bool
    let attendeeAvatars: [RuulAvatarStack.Person]
    let confirmedCount: Int
    let isAtCapacity: Bool
    let onTap: () -> Void

    init(
        resource: any ResourceProtocol,
        myStatus: RSVPStatus? = nil,
        isHostedByMe: Bool = false,
        attendeeAvatars: [RuulAvatarStack.Person] = [],
        confirmedCount: Int = 0,
        isAtCapacity: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.resource = resource
        self.myStatus = myStatus
        self.isHostedByMe = isHostedByMe
        self.attendeeAvatars = attendeeAvatars
        self.confirmedCount = confirmedCount
        self.isAtCapacity = isAtCapacity
        self.onTap = onTap
    }

    var body: some View {
        switch resource.resourceType {
        case .event:
            if let eventResource = resource as? EventResource {
                EventCard(
                    event: eventResource.event,
                    myStatus: myStatus,
                    isHostedByMe: isHostedByMe,
                    attendeeAvatars: attendeeAvatars,
                    confirmedCount: confirmedCount,
                    isAtCapacity: isAtCapacity,
                    onTap: onTap
                )
            } else {
                // Defensive — V1 invariant says EventResource is the only
                // .event conformer. Si esto se rompe es bug, no UI fallback.
                UnknownResourceCard(resource: resource)
            }
        case .slot, .fund, .position, .asset, .contribution, .unknown:
            // Phase 2/3/4 bodies. V1 fallback hasta que cada type tenga
            // su body concreto en este switch.
            UnknownResourceCard(resource: resource)
        }
    }
}

/// Fallback visual para resource types aún no implementados. Existe para
/// que el switch sea total y para que QA spotee inmediatamente si un
/// resource llega a UI sin body — no es un error silencioso.
private struct UnknownResourceCard: View {
    let resource: any ResourceProtocol

    var body: some View {
        HStack(spacing: RuulSpacing.s2) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ruulTextTertiary)
            Text("Resource \(String(describing: resource.resourceType)) sin body")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ruulBackgroundElevated, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
        )
    }
}
