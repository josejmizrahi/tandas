import SwiftUI

/// Luma-style inline action bar. Renders a horizontal row of tile-shaped
/// buttons (icon + label, equal flex) directly under a resource's title
/// block. Replaces the "primary CTA stuck at the bottom + everything else
/// hidden in the `⋯` menu" pattern with visible affordances at the place
/// the user is already looking.
///
/// Two visual styles:
/// - `.primary` — filled accent capsule with inverse text. One per bar.
/// - `.secondary` — soft surface fill, primary text. The rest.
///
/// The bar lays out as equal-flex columns. Three actions is the sweet
/// spot (mirrors Luma's `Registrarse / Contacto / Más` pattern); two or
/// four also work. Beyond four, the caller should promote the overflow
/// into a sheet or menu rather than cramming tiles.
@MainActor
public struct RuulInlineActionBar: View {
    public struct Action: Identifiable, Sendable {
        public enum Style: Sendable, Hashable { case primary, secondary }

        public let id: String
        public let label: String
        public let symbol: String
        public let style: Style
        public let isDestructive: Bool
        public let isDisabled: Bool
        public let perform: @MainActor () -> Void

        public init(
            id: String,
            label: String,
            symbol: String,
            style: Style = .secondary,
            isDestructive: Bool = false,
            isDisabled: Bool = false,
            perform: @MainActor @escaping () -> Void
        ) {
            self.id = id
            self.label = label
            self.symbol = symbol
            self.style = style
            self.isDestructive = isDestructive
            self.isDisabled = isDisabled
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
            HStack(spacing: RuulSpacing.sm) {
                ForEach(actions) { action in
                    tile(for: action)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(for action: Action) -> some View {
        Button(action: action.perform) {
            VStack(spacing: RuulSpacing.xxs) {
                Image(systemName: action.symbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(action.label)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, RuulSpacing.md)
            .foregroundStyle(foregroundColor(for: action))
            .background(backgroundShape(for: action))
        }
        .buttonStyle(.ruulPress)
        .disabled(action.isDisabled)
        .opacity(action.isDisabled ? 0.5 : 1.0)
        .accessibilityLabel(action.label)
    }

    @ViewBuilder
    private func backgroundShape(for action: Action) -> some View {
        let shape = RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
        switch action.style {
        case .primary:
            shape.fill(action.isDestructive ? Color.ruulNegative : Color.ruulTextPrimary)
        case .secondary:
            shape.fill(Color.ruulSurface)
        }
    }

    private func foregroundColor(for action: Action) -> Color {
        switch action.style {
        case .primary:
            // Inverse of the filled primary background — reads correctly
            // in both light and dark modes since the primary uses the
            // same token as the text would, just swapped.
            return Color.ruulBackgroundCanvas
        case .secondary:
            return action.isDestructive ? Color.ruulNegative : Color.ruulTextPrimary
        }
    }
}

#if DEBUG
#Preview("RuulInlineActionBar — 3 actions") {
    VStack(spacing: RuulSpacing.lg) {
        RuulInlineActionBar(actions: [
            .init(id: "rsvp",  label: "Confirmar", symbol: "checkmark", style: .primary, perform: {}),
            .init(id: "share", label: "Compartir", symbol: "square.and.arrow.up",     perform: {}),
            .init(id: "more",  label: "Más",       symbol: "ellipsis", perform: {})
        ])
        RuulInlineActionBar(actions: [
            .init(id: "register", label: "Registrarse", symbol: "ticket", style: .primary, perform: {}),
            .init(id: "contact",  label: "Contacto",    symbol: "envelope",                perform: {})
        ])
        RuulInlineActionBar(actions: [
            .init(id: "cancel", label: "Cancelar evento", symbol: "xmark.circle", style: .primary, isDestructive: true, perform: {}),
            .init(id: "edit",   label: "Editar",          symbol: "pencil",                                              perform: {})
        ])
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
