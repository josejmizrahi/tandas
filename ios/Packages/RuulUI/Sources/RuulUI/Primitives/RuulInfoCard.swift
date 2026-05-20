import SwiftUI

/// Canonical "labeled card with rows separated by hairlines" used across
/// every resource detail surface (Fund balance card, Asset custody /
/// ownership / maintenance / bookings, the universal INFORMACIÓN card,
/// etc.). Replaces the `sectionContainer + row + divider` trio that was
/// re-declared as private helpers inside each section view.
///
/// Layout:
///   ```
///   TÍTULO                                  ← optional, tracked caps
///   ┌───────────────────────────────┐
///   │ Label              Value      │
///   ├───────────────────────────────┤      ← hairline (use RuulInfoDivider)
///   │ Label              Value      │
///   ├───────────────────────────────┤
///   │ 􀎁  Acción                     │      ← RuulInfoActionRow
///   └───────────────────────────────┘
///   ```
///
/// Usage:
///   ```swift
///   RuulInfoCard("CUSTODIA") {
///       RuulInfoRow(label: "Custodio", value: "Pedro")
///       RuulInfoDivider()
///       RuulInfoActionRow(label: "Asignar custodio",
///                         symbol: "person.badge.plus") { ... }
///   }
///   ```
///
/// Callers compose `RuulInfoDivider()` between rows — keeps the API
/// honest (the divider only renders when the caller decides one is
/// needed, no implicit insertion magic).
public struct RuulInfoCard<Content: View>: View {
    public let title: String?
    public let content: Content

    public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(.leading, RuulSpacing.xxs)
            }
            VStack(spacing: 0) { content }
                .background(
                    Color.ruulSurface,
                    in: RoundedRectangle(cornerRadius: RuulRadius.lg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Rows

/// Standard label-value row inside a `RuulInfoCard`. Label on the left
/// in secondary text, value on the right in primary text, both at body
/// weight. Right-aligns the value so long strings wrap cleanly.
public struct RuulInfoRow: View {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(RuulSpacing.md)
    }
}

/// Tappable action row inside a `RuulInfoCard`. SF symbol on the left,
/// label next to it; foreground turns red when `isDestructive` is true.
/// Full-width tap target (`contentShape(Rectangle())`) so users don't
/// have to land on the text exactly.
public struct RuulInfoActionRow: View {
    public let label: String
    public let symbol: String
    public let isDestructive: Bool
    public let action: () -> Void

    public init(
        label: String,
        symbol: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.symbol = symbol
        self.isDestructive = isDestructive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .frame(width: 20)
                Text(label)
                    .font(.subheadline)
                Spacer()
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Hairline separator sized to drop in between rows inside a
/// `RuulInfoCard`. Inset on the leading edge so the divider doesn't
/// touch the card's curved border.
public struct RuulInfoDivider: View {
    public init() {}

    public var body: some View {
        Divider()
            .background(Color(.separator))
            .padding(.leading, RuulSpacing.md)
    }
}

#if DEBUG
#Preview("RuulInfoCard — info + actions") {
    VStack(alignment: .leading, spacing: RuulSpacing.lg) {
        RuulInfoCard("CUSTODIA") {
            RuulInfoRow(label: "Custodio", value: "Pedro Hernández")
            RuulInfoDivider()
            RuulInfoRow(label: "Desde", value: "8 May 2026")
            RuulInfoDivider()
            RuulInfoActionRow(
                label: "Cambiar custodio",
                symbol: "person.badge.plus"
            ) { }
            RuulInfoDivider()
            RuulInfoActionRow(
                label: "Liberar custodia",
                symbol: "person.crop.rectangle.badge.xmark",
                isDestructive: true
            ) { }
        }
        RuulInfoCard("INFORMACIÓN") {
            RuulInfoRow(label: "Fecha", value: "Lunes 19 de mayo")
            RuulInfoDivider()
            RuulInfoRow(label: "Hora", value: "16:00 – 19:00")
            RuulInfoDivider()
            RuulInfoRow(label: "Anfitrión", value: "María González")
        }
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
