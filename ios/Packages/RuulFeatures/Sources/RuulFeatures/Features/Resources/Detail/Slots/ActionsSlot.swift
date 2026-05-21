//
//  ActionsSlot.swift
//  ResourceKit
//
//  Horizontal row of `.glassProminent` action buttons. Resource factories
//  cap this at 3 actions; overflow goes to the toolbar menu.
//

import SwiftUI
import RuulUI

// MARK: Actions

struct ActionsSlot: View {
    let actions: [ResourceAction]
    let accent: Color

    var body: some View {
        HStack(spacing: RuulSpacing.s2) {
            ForEach(actions) { action in
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
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.glassProminent)
                .tint(action.tint ?? Color.ruulFillGlassStrong)
            }
        }
    }
}
