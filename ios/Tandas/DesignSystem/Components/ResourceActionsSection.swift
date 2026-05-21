import SwiftUI
import RuulCore
import RuulUI

/// Generic actions section consumiendo `[ResourceAction]`. Renderiza
/// each action as a tappable row with icon + title + optional subtitle.
/// Destructive actions get red tint.
///
/// V1 scaffolding: `EventHostActionsSection` existing surface se
/// preserva intacto. Phase 2 ship `EventActionsProvider` concrete y
/// migra event-specific call sites a usar this section.
///
/// Mismo pattern que `VoteCastSection` (OpenVotesView) — single view
/// with private subviews.
struct ResourceActionsSection: View {
    let actions: [ResourceAction]

    var body: some View {
        if actions.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: RuulSpacing.xs) {
                ForEach(actions) { action in
                    ResourceActionRow(action: action)
                }
            }
        }
    }
}

private struct ResourceActionRow: View {
    let action: ResourceAction
    @State private var isInvoking = false

    var body: some View {
        Button {
            guard !isInvoking else { return }
            isInvoking = true
            Task {
                await action.onTap()
                isInvoking = false
            }
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: action.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(action.isDestructive
                        ? Color.red
                        : Color.ruulAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.ruulSurface, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.headline)
                        .foregroundStyle(action.isDestructive
                            ? Color.red
                            : Color.primary)
                    if let subtitle = action.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }

                Spacer()

                if isInvoking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .opacity(isInvoking ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isInvoking)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.subtitle ?? "")
    }
}
