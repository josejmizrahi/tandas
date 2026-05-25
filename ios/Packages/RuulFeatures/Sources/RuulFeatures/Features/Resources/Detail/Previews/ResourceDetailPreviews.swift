//
//  ResourceDetailPreviews.swift
//  ResourceKit
//
//  All `#Preview` blocks for the universal resource detail. Lives in its
//  own file so the shell + slots stay free of debug clutter.
//

#if DEBUG
import SwiftUI
import MapKit
import CoreLocation

#Preview("Evento") {
    ResourceDetailView(config: .event(EventInput(
        id: "1",
        title: "Rrff",
        dateLabel: "21 may",
        timeLabel: "2:03 p.m.",
        dayLabel: "Hoy",
        durationMin: 180,
        isHost: true,
        address: "Altezza Bosques, Camino a Tecamachalco 98, El Olivo, 52789 Naucalpan, Edo. Méx.",
        coordinate: CLLocationCoordinate2D(latitude: 19.4019, longitude: -99.2436),
        attendees: [],
        activity: [
            ActivityItem(id: "a1", title: "Confirmación de asistencia",
                         subtitle: "Tú", timestamp: Date().addingTimeInterval(-36000),
                         kind: .positive),
            ActivityItem(id: "a2", title: "Evento creado",
                         subtitle: "Tú", timestamp: Date().addingTimeInterval(-36000))
        ]
    )))
}

#Preview("Fondo") {
    ResourceDetailView(config: .fund(FundInput(
        id: "1",
        name: "Nabba",
        createdAgo: "hace 2 d",
        balance: 0,
        contributed: 0,
        withdrawn: 0,
        participants: [
            Person(id: "p1", name: "Jose", initials: "JM", color: .orange),
            Person(id: "p2", name: "Linda", initials: "LR", color: .indigo)
        ],
        movements: []
    )))
}

#Preview("Espacio") {
    ResourceDetailView(config: .space(SpaceInput(
        id: "1",
        name: "Palco",
        isActive: true,
        capacity: 12,
        location: "Nivel 2 · Norte",
        bookingsThisMonth: 0,
        nextBookingTime: nil,
        activity: [
            ActivityItem(id: "s1", title: "Espacio creado",
                         subtitle: "Tú",
                         timestamp: Date().addingTimeInterval(-172800))
        ]
    )))
}

#Preview("Votación") {
    ResourceDetailView(config: .vote(VoteInput(
        id: "1",
        title: "¿Subimos la cuota mensual a $500?",
        description: "Para cubrir gastos del próximo trimestre.",
        statusLabel: "Abierta",
        voteTypeLabel: "Cambio de regla",
        timingLabel: "Cierra en 2 d",
        closesAt: Date().addingTimeInterval(2 * 24 * 3600),
        isOpen: true,
        inFavor: 4,
        against: 1,
        abstained: 1,
        pending: 2,
        totalEligible: 8,
        quorumPercent: 60,
        thresholdPercent: 50,
        viewerAlreadyVoted: false,
        activity: [
            ActivityItem(id: "v1", title: "Votación iniciada",
                         subtitle: "Jose", timestamp: Date().addingTimeInterval(-7200)),
            ActivityItem(id: "v2", title: "Voto emitido",
                         subtitle: "Linda · A favor",
                         timestamp: Date().addingTimeInterval(-3600),
                         kind: .positive)
        ]
    )))
}

#Preview("Multa") {
    ResourceDetailView(config: .fine(FineInput(
        id: "1",
        reason: "Llegada tarde a la cena",
        amountFormatted: "$200.00",
        statusLabel: "Pendiente",
        createdAtLabel: "Hoy · 21 may",
        finedPerson: Person(
            id: "linda",
            name: "Linda",
            initials: "L",
            color: .blue,
            imageURL: nil
        ),
        issuerPerson: Person(
            id: "jose",
            name: "Jose",
            initials: "J",
            color: .green,
            imageURL: nil
        ),
        canPay: true,
        canAppeal: true,
        appealStatusLabel: nil,
        activity: [
            ActivityItem(id: "f1", title: "Multa emitida",
                         subtitle: "Jose", timestamp: Date().addingTimeInterval(-1800),
                         kind: .negative)
        ]
    )))
}
#endif
