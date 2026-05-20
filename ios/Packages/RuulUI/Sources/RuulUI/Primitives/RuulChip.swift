import SwiftUI

/// Chip primitive for selectable filters, removable tags, count badges,
/// and suggestion pills.
public struct RuulChip: View {
    public enum Style: Sendable, Hashable {
        case selectable(isSelected: Bool)
        case removable
        case count(Int)
        case suggestion
    }

    private let title: String
    private let systemImage: String?
    private let style: Style
    private let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, style: Style, action: @escaping () -> Void = {}) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.footnote)
                if case .count(let n) = style {
                    Text("\(n)")
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                if case .removable = style {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, RuulSpacing.sm)
            .padding(.vertical, RuulSpacing.xs)
            .modifier(ChipBackground(style: style))
        }
        .buttonStyle(.ruulPress)
    }

    private var foreground: Color {
        if case .selectable(let isSelected) = style, isSelected {
            return .ruulTextInverse
        }
        return .ruulTextPrimary
    }
}

private struct ChipBackground: ViewModifier {
    let style: RuulChip.Style

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = Capsule()
        switch style {
        case .selectable(let isSelected) where isSelected:
            content.background(Color.ruulAccent, in: shape)
        case .suggestion:
            content
                .background(Color.ruulAccentMuted, in: shape)
                .overlay(shape.stroke(Color.ruulAccent.opacity(0.3), lineWidth: 1))
        default:
            content.ruulGlass(shape, material: .regular)
        }
    }
}

#if DEBUG
private struct RuulChipPreview: View {
    @State var selection: Set<String> = ["Eventos"]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Selectable").font(.footnote)
            HStack {
                ForEach(["Eventos", "Reglas", "Multas"], id: \.self) { tag in
                    RuulChip(tag, style: .selectable(isSelected: selection.contains(tag))) {
                        if selection.contains(tag) { selection.remove(tag) } else { selection.insert(tag) }
                    }
                }
            }
            Text("Count").font(.footnote)
            HStack {
                RuulChip("Reglas", style: .count(4))
                RuulChip("Pendientes", systemImage: "clock", style: .count(2))
            }
            Text("Removable").font(.footnote)
            HStack {
                RuulChip("Comida", style: .removable)
                RuulChip("Cena", style: .removable)
            }
            Text("Suggestion").font(.footnote)
            HStack {
                RuulChip("Cena de los miércoles", systemImage: "sparkles", style: .suggestion)
            }
        }
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
    }
}

#Preview("RuulChip") {
    RuulChipPreview()
}
#endif
