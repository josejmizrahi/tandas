//
//  ActionsSlot.swift
//  ResourceKit
//
//  Horizontal row of action buttons. 2026-05-25 v2 (founder pick):
//  uniform `.glass` chrome for ALL actions — no prominent fills,
//  no per-button colored pills. The action.tint only controls the
//  LABEL color for semantic role (red for cancel/destructive, green
//  for confirm/success). Default tint = .primary (black/white
//  adaptive) so most buttons read as quiet neutral pills, matching
//  the iOS form-style action row pattern (ref: Luma / Apple Maps
//  detail / iOS Forms).
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
                if action.isPending {
                    ProgressView()
                        .controlSize(.mini)
                } else if let icon = action.icon {
                    Image(systemName: icon)
                        .font(.footnote.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(displayedLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.18), value: action.isPending)
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .tint(action.tint ?? .primary)
        .disabled(action.isPending)
    }

    private var displayedLabel: String {
        if action.isPending, let pending = action.pendingLabel { return pending }
        return action.label
    }
}
