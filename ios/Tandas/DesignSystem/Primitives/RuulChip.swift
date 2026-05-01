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
            HStack(spacing: RuulSpacing.s2) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .ruulTextStyle(RuulTypography.callout)
                if case .count(let n) = style {
                    Text("\(n)")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                if case .removable = style {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, RuulSpacing.s3)
            .padding(.vertical, RuulSpacing.s2)
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
            content.background(Color.ruulAccentPrimary, in: shape)
        case .suggestion:
            content
                .background(Color.ruulAccentSubtle, in: shape)
                .overlay(shape.stroke(Color.ruulAccentPrimary.opacity(0.3), lineWidth: 1))
        default:
            content.ruulGlass(shape, material: .regular)
        }
    }
}

#if DEBUG
private struct RuulChipPreview: View {
    @State var selection: Set<String> = ["Eventos"]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            Text("Selectable").ruulTextStyle(RuulTypography.footnote)
            HStack {
                ForEach(["Eventos", "Reglas", "Multas"], id: \.self) { tag in
                    RuulChip(tag, style: .selectable(isSelected: selection.contains(tag))) {
                        if selection.contains(tag) { selection.remove(tag) } else { selection.insert(tag) }
                    }
                }
            }
            Text("Count").ruulTextStyle(RuulTypography.footnote)
            HStack {
                RuulChip("Reglas", style: .count(4))
                RuulChip("Pendientes", systemImage: "clock", style: .count(2))
            }
            Text("Removable").ruulTextStyle(RuulTypography.footnote)
            HStack {
                RuulChip("Comida", style: .removable)
                RuulChip("Cena", style: .removable)
            }
            Text("Suggestion").ruulTextStyle(RuulTypography.footnote)
            HStack {
                RuulChip("Cena de los miércoles", systemImage: "sparkles", style: .suggestion)
            }
        }
        .padding(RuulSpacing.s5)
        .background(Color.ruulBackgroundCanvas)
    }
}

#Preview("RuulChip") {
    RuulChipPreview()
}
#endif
