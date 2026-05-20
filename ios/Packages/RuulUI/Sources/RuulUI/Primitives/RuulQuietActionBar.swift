import SwiftUI

/// Quiet action bar — a horizontal row of small icon+label buttons that
/// sits at the bottom of a Resource Detail Overview. Distinct from
/// `RuulInlineActionBar` (filled tiles for 2-4 primary CTAs); the quiet
/// bar is for ambient universal verbs that should always be reachable
/// without competing for visual weight.
///
/// Per V2 Human-Layer doctrine (Plans/Active/ProductCompression.md §C.1):
/// 7 verbs are universal across every resource type (`view_history`,
/// `link_resource`, `add_rules`, `share_resource`, `edit_resource`,
/// `archive_resource`, `track_money`). Hosting them in this quiet bar
/// lets each variant's primary intent menu shrink to ≤4 distinctive
/// actions.
///
/// Visual contract:
/// - Buttons are icon + caption stacked vertically, equal flex.
/// - Muted foreground (`ruulTextSecondary`) so the bar reads as ambient
///   chrome, not a CTA row.
/// - Compact vertical padding. No background fill on the bar itself.
/// - Horizontal `ScrollView` keeps the layout safe on iPhone SE when
///   6-7 verbs land at once; on wider screens the row centers visually
///   via `frame(maxWidth: .infinity)`.
@MainActor
public struct RuulQuietActionBar: View {
    public struct Action: Identifiable, Sendable {
        public let id: String
        public let label: String
        public let symbol: String
        public let isDestructive: Bool
        public let perform: @MainActor () -> Void

        public init(
            id: String,
            label: String,
            symbol: String,
            isDestructive: Bool = false,
            perform: @MainActor @escaping () -> Void
        ) {
            self.id = id
            self.label = label
            self.symbol = symbol
            self.isDestructive = isDestructive
            self.perform = perform
        }
    }

    public let actions: [Action]

    public init(actions: [Action]) {
        self.actions = actions
    }

    public var body: some View {
        if actions.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.lg) {
                    ForEach(actions) { action in
                        button(for: action)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.vertical, RuulSpacing.md)
            }
        }
    }

    @ViewBuilder
    private func button(for action: Action) -> some View {
        Button(action: action.perform) {
            VStack(spacing: RuulSpacing.xxs) {
                Image(systemName: action.symbol)
                    .font(.system(size: 18, weight: .regular))
                Text(action.label)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(action.isDestructive ? Color.ruulNegative : Color.ruulTextSecondary)
            .frame(minWidth: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ruulPress)
        .accessibilityLabel(action.label)
    }
}

#if DEBUG
#Preview("RuulQuietActionBar — 6 universal verbs") {
    RuulQuietActionBar(actions: [
        .init(id: "view_history",     label: "Historia",  symbol: "clock.arrow.circlepath", perform: {}),
        .init(id: "add_rules",        label: "Reglas",    symbol: "list.bullet.clipboard",  perform: {}),
        .init(id: "share_resource",   label: "Compartir", symbol: "square.and.arrow.up",    perform: {}),
        .init(id: "edit_resource",    label: "Editar",    symbol: "pencil",                 perform: {}),
        .init(id: "archive_resource", label: "Archivar",  symbol: "archivebox", isDestructive: true, perform: {}),
        .init(id: "track_money",      label: "Dinero",    symbol: "banknote",               perform: {})
    ])
    .padding(.horizontal, RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
