//
//  ActionsSlot.swift
//  ResourceKit
//
//  Horizontal row of action buttons.  Apple segmented-bar recipe:
//
//    - **Primary CTAs** (action.tint set) → `.glassProminent` with the
//      semantic tint → filled background, system-contrast (white) label
//      → readable in both light and dark.
//    - **Secondary actions** (action.tint == nil) → plain `.glass` →
//      outlined / glass-effect background, label uses the ambient
//      `.tint(...)` (`config.accent` from `ResourceDetailContent`).
//
//  Previously every button was `.glassProminent` with a fallback tint of
//  `Color.ruulFillGlassStrong` — that's a 6-10% primary-text wash, not a
//  proper accent color, so the white prominent label sat on a near-empty
//  background and disappeared in light mode and bleached in dark.
//
//  Resource factories cap this at 3 actions; overflow goes to the
//  toolbar menu.
//

import SwiftUI
import RuulUI

// MARK: Actions

struct ActionsSlot: View {
    let actions: [ResourceAction]
    let accent: Color

    var body: some View {
        HStack(spacing: RuulSpacing.xs) {
            ForEach(actions) { action in
                ActionButton(action: action)
            }
        }
    }
}

private struct ActionButton: View {
    let action: ResourceAction

    var body: some View {
        Button(role: action.role, action: action.handler) {
            HStack(spacing: RuulSpacing.micro) {
                if let icon = action.icon {
                    Image(systemName: icon)
                        .font(.footnote.weight(.semibold))
                }
                Text(action.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .modifier(ActionStyle(tint: action.tint))
    }
}

/// Branching the modifier (instead of conditional inside `body`) keeps
/// SwiftUI from confusing the two button styles in the same expression
/// tree (which compiles but lets the system pick the wrong default).
private struct ActionStyle: ViewModifier {
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let tint {
            content
                .buttonStyle(.glassProminent)
                .tint(tint)
        } else {
            content
                .buttonStyle(.glass)
        }
    }
}
