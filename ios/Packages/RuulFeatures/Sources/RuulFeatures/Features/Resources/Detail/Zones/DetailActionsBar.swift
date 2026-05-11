import SwiftUI
import RuulUI
import RuulCore

/// "Primary actions" zone — capability-driven CTA strip. The set of
/// buttons surfaced depends on which capabilities the resource has
/// enabled, NOT on the resource type:
///
///   rsvp           → "RSVP"          (defers to onPresentRSVP)
///   money/expenses → "+ Gasto"       (opens ledger)
///   contributions  → "+ Aportación"  (opens ledger)
///   payouts        → "Pagar"         (opens ledger)
///   guests         → "Invitar"       (TODO: not wired in V1)
///   rotation       → "Pasar turno"   (TODO: not wired in V1)
///
/// V1 wires the ledger-flavored buttons through `onPresentLedger`
/// (they all open the same sheet). Phase 2 splits them when the
/// per-button intent is encoded in the form (preselect kind).
public struct DetailActionsBar: View {
    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        if actions.isEmpty {
            EmptyView()
        } else {
            // Horizontal scroll so adding a 4th capability doesn't
            // crush the layout — most resources will have 2-3 here.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.xs) {
                    ForEach(actions) { action in
                        actionButton(action)
                    }
                }
                .padding(.horizontal, RuulSpacing.xxs)
            }
        }
    }

    // MARK: - Actions

    private struct ActionItem: Identifiable {
        let id: String
        let label: String
        let icon: String
        let run: () -> Void
    }

    private var actions: [ActionItem] {
        var out: [ActionItem] = []
        let caps = context.enabledCapabilities

        if caps.contains("rsvp") {
            // RSVP routes through edit/event detail today. Stubbed as
            // a no-op for V1; the lower RSVP section is the affordance
            // until the full migration lands.
        }

        if caps.contains("expenses") || caps.contains("money") {
            out.append(.init(
                id: "expense",
                label: "Gasto",
                icon: "cart.fill",
                run: context.onPresentLedger
            ))
        }
        if caps.contains("contributions") {
            out.append(.init(
                id: "contribution",
                label: "Aportación",
                icon: "arrow.up.bin.fill",
                run: context.onPresentLedger
            ))
        }
        if caps.contains("payouts") {
            out.append(.init(
                id: "payout",
                label: "Payout",
                icon: "tray.and.arrow.down.fill",
                run: context.onPresentLedger
            ))
        }

        if caps.contains("rules") {
            out.append(.init(
                id: "rules",
                label: "Reglas",
                icon: "list.bullet.clipboard.fill",
                run: context.onPresentRules
            ))
        }

        return out
    }

    private func actionButton(_ a: ActionItem) -> some View {
        Button(action: a.run) {
            HStack(spacing: RuulSpacing.xxs) {
                Image(systemName: a.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(a.label)
                    .ruulTextStyle(RuulTypography.callout)
            }
            .foregroundStyle(Color.ruulTextPrimary)
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .background(Color.ruulSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.ruulSeparator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
