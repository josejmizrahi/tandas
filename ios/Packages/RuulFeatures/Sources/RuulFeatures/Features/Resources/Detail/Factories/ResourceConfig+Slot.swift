//
//  ResourceConfig+Slot.swift
//  ResourceKit
//
//  Slot factory — moves SlotDetailView onto the universal shell per
//  Resource Detail Doctrine v2 (2026-05-25). Vocabulary purge applied:
//  "Cupo" → "Turno" at the user-facing layer; "status" rendered as a
//  human phrase ("Le toca a José" / "Disponible") instead of the raw
//  state machine.
//

import SwiftUI
import RuulCore
import RuulUI

// MARK: - SlotInput

public struct SlotInput {
    public let id: String
    /// Parent asset name (e.g. "Palco Mundial"). Slots are sub-units;
    /// the asset name carries the recognizable identity.
    public let assetName: String
    /// Human time-range label ("Vie 5 oct · 8 a 11 p.m.").
    public let timeRangeLabel: String
    /// Human status phrase ("Le toca a José", "Disponible",
    /// "Reservado por Linda").
    public let statusLabel: String
    /// Avatar + name of the assigned holder (PresenceBlock per
    /// doctrine v2 §3). Nil when the slot is unassigned.
    public let titularPerson: Person?
    public let canAssign: Bool
    public let canBook: Bool
    public let canRequestSwap: Bool
    public let activity: [ActivityItem]

    public init(
        id: String,
        assetName: String,
        timeRangeLabel: String,
        statusLabel: String,
        titularPerson: Person?,
        canAssign: Bool,
        canBook: Bool,
        canRequestSwap: Bool,
        activity: [ActivityItem] = []
    ) {
        self.id = id
        self.assetName = assetName
        self.timeRangeLabel = timeRangeLabel
        self.statusLabel = statusLabel
        self.titularPerson = titularPerson
        self.canAssign = canAssign
        self.canBook = canBook
        self.canRequestSwap = canRequestSwap
        self.activity = activity
    }
}

// MARK: - Factory

public extension ResourceConfig {

    /// Renders a slot ("turno") on the universal shell. Hero shows the
    /// human status phrase ("Le toca a José") over the time-range
    /// label. Actions inline: Reservar / Asignar / Pedir intercambio,
    /// each gated by the input flags. The titular renders as a
    /// PresenceBlock-equivalent avatar row when present; an empty
    /// invitation appears when the slot is unassigned.
    static func slot(
        _ input: SlotInput,
        onBook: @escaping () -> Void = {},
        onAssign: @escaping () -> Void = {},
        onRequestSwap: @escaping () -> Void = {},
        toolbarMenu: [ToolbarMenuItem] = []
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.assets.color

        var actions: [ResourceAction] = []
        if input.canBook {
            actions.append(ResourceAction(
                label: "Reservar",
                icon: "ticket",
                tint: accent,
                handler: onBook
            ))
        }
        if input.canAssign {
            actions.append(ResourceAction(
                label: "Asignar",
                icon: "person.crop.circle.badge.plus",
                handler: onAssign
            ))
        }
        if input.canRequestSwap {
            actions.append(ResourceAction(
                label: "Pedir intercambio",
                icon: "arrow.left.arrow.right",
                handler: onRequestSwap
            ))
        }

        var sections: [ResourceSection] = []
        if let titular = input.titularPerson {
            sections.append(.avatars(
                title: "De quién es",
                people: [titular],
                emptyText: nil,
                onTapMore: nil
            ))
        } else {
            sections.append(.empty(
                title: "Sin titular",
                icon: "person.crop.circle.badge.questionmark",
                message: "Aún nadie tiene este turno",
                description: "Asigna a alguien o reserva tú mismo."
            ))
        }

        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "ticket",
                name: input.assetName,
                typeLabel: "Turno",
                metadata: [input.timeRangeLabel],
                badge: nil
            ),
            accent: accent,
            hero: HeroData(
                value: input.statusLabel,
                label: input.timeRangeLabel,
                size: .title
            ),
            actions: actions,
            sections: sections,
            activity: input.activity.isEmpty ? nil : .static(input.activity),
            toolbarMenu: toolbarMenu
        )
    }
}
