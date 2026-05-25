//
//  ResourceConfig+Rule.swift
//  ResourceKit
//
//  Rule factory — moves RuleDetailView onto the universal shell per
//  Resource Detail Doctrine v2 (2026-05-25). Vocabulary purge applied:
//  drop "Multa escalante" + slug/scope leaks from user copy; render
//  consequences as humane sentences in the "Qué hace" rows.
//

import SwiftUI
import RuulCore
import RuulUI

// MARK: - RuleInput

public struct RuleInput {
    public let id: String
    public let name: String
    public let isActive: Bool
    public let scopeLabel: String
    public let consequenceLines: [String]
    /// Optional hero block — fines render a prominent amount; rules
    /// without a money consequence skip the hero entirely.
    public let amountHero: AmountHero?
    public let canEditRule: Bool
    public let canEditParams: Bool
    /// When non-nil, params editing is blocked because a vote is in
    /// flight; the reason renders as a sentence row instead of a
    /// disabled button (doctrine v2 §6: action treatment).
    public let editParamsBlockedReason: String?
    public let activity: [ActivityItem]

    public struct AmountHero {
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public init(
        id: String,
        name: String,
        isActive: Bool,
        scopeLabel: String,
        consequenceLines: [String],
        amountHero: AmountHero?,
        canEditRule: Bool,
        canEditParams: Bool,
        editParamsBlockedReason: String?,
        activity: [ActivityItem] = []
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.scopeLabel = scopeLabel
        self.consequenceLines = consequenceLines
        self.amountHero = amountHero
        self.canEditRule = canEditRule
        self.canEditParams = canEditParams
        self.editParamsBlockedReason = editParamsBlockedReason
        self.activity = activity
    }
}

// MARK: - Factory

public extension ResourceConfig {

    static func rule(
        _ input: RuleInput,
        onEdit: @escaping () -> Void = {},
        onEditParams: @escaping () -> Void = {},
        onProposeChange: @escaping () -> Void = {}
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.agreements.color

        var actions: [ResourceAction] = []
        if input.canEditRule {
            actions.append(ResourceAction(
                label: "Editar",
                icon: "pencil",
                handler: onEdit
            ))
        }
        if input.canEditParams && input.editParamsBlockedReason == nil {
            actions.append(ResourceAction(
                label: "Cambiar monto",
                icon: "slider.horizontal.3",
                tint: accent,
                handler: onEditParams
            ))
        }
        actions.append(ResourceAction(
            label: "Proponer cambio",
            icon: "text.bubble",
            handler: onProposeChange
        ))

        var sections: [ResourceSection] = []
        if !input.consequenceLines.isEmpty {
            let rows = input.consequenceLines.enumerated().map { idx, line in
                RowItem(
                    icon: "arrow.right.circle.fill",
                    label: "Acción \(idx + 1)",
                    value: .text(line)
                )
            }
            sections.append(.rows(title: "Qué hace", items: rows))
        }
        if let reason = input.editParamsBlockedReason {
            sections.append(.rows(title: "Estado de la regla", items: [
                RowItem(
                    icon: "clock.badge.exclamationmark",
                    label: "En cambio",
                    value: .text(reason)
                )
            ]))
        }
        sections.append(.rows(title: "Detalles", items: [
            RowItem(icon: "scope", label: "Aplica a", value: .text(input.scopeLabel)),
            RowItem(
                icon: input.isActive ? "checkmark.circle" : "pause.circle",
                label: "Estado",
                value: .text(input.isActive ? "Activa" : "Deshabilitada")
            )
        ]))

        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "scroll",
                name: input.name,
                typeLabel: "Regla",
                metadata: [input.scopeLabel, input.isActive ? "Activa" : "Pausada"],
                badge: nil
            ),
            accent: accent,
            hero: input.amountHero.map { hero in
                HeroData(value: hero.value, label: hero.label, size: .display)
            },
            actions: actions,
            sections: sections,
            activity: input.activity.isEmpty ? nil : .static(input.activity),
            toolbarMenu: []
        )
    }
}
