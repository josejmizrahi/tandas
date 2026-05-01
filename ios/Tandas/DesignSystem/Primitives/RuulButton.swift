import SwiftUI

/// Primary button primitive.
///
/// Variants: `.primary`, `.secondary`, `.glass`, `.destructive`, `.plain`.
/// Sizes: `.small`, `.medium`, `.large`.
public struct RuulButton: View {
    public enum Style: Sendable, Hashable { case primary, secondary, glass, destructive, plain }
    public enum Size: Sendable, Hashable { case small, medium, large }

    private let title: String
    private let systemImage: String?
    private let style: Style
    private let size: Size
    private let isLoading: Bool
    private let fillsWidth: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        systemImage: String? = nil,
        style: Style = .primary,
        size: Size = .medium,
        isLoading: Bool = false,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.size = size
        self.isLoading = isLoading
        self.fillsWidth = fillsWidth
        self.action = action
    }

    public var body: some View {
        Button(action: { if !isLoading { action() } }) {
            label
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(minHeight: heightForSize)
                .padding(.horizontal, horizontalPadding)
                .modifier(StyleBackground(style: style))
                .foregroundStyle(foreground)
        }
        .buttonStyle(.ruulPress)
        .disabled(isLoading)
    }

    @ViewBuilder
    private var label: some View {
        if isLoading {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(foreground)
        } else {
            HStack(spacing: RuulSpacing.s2) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).ruulTextStyle(textStyle)
            }
        }
    }

    private var foreground: Color {
        switch style {
        case .primary:     return .ruulTextInverse
        case .secondary:   return .ruulAccentPrimary
        case .glass:       return .ruulTextPrimary
        case .destructive: return .ruulTextInverse
        case .plain:       return .ruulAccentPrimary
        }
    }

    private var textStyle: RuulTextStyle {
        switch size {
        case .small:  return RuulTypography.callout
        case .medium: return RuulTypography.body
        case .large:  return RuulTypography.bodyLarge
        }
    }

    private var heightForSize: CGFloat {
        switch size {
        case .small:  return 32
        case .medium: return RuulSpacing.minTouchTarget
        case .large:  return 56
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small:  return RuulSpacing.s3
        case .medium: return RuulSpacing.s5
        case .large:  return RuulSpacing.s7
        }
    }
}

private struct StyleBackground: ViewModifier {
    let style: RuulButton.Style

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .primary:
            content
                .background(Capsule().fill(Color.ruulAccentPrimary))
                .ruulElevation(.sm)
        case .secondary:
            content
                .overlay(Capsule().stroke(Color.ruulBorderStrong, lineWidth: 1))
        case .glass:
            content
                .ruulGlass(Capsule(), material: .regular, interactive: true)
        case .destructive:
            content
                .background(Capsule().fill(Color.ruulSemanticError))
                .ruulElevation(.sm)
        case .plain:
            content
        }
    }
}

#if DEBUG
#Preview("RuulButton") {
    ScrollView {
        VStack(alignment: .leading, spacing: RuulSpacing.s4) {
            ForEach([RuulButton.Size.small, .medium, .large], id: \.self) { size in
                Text("\(String(describing: size))").ruulTextStyle(RuulTypography.footnote)
                HStack(spacing: RuulSpacing.s3) {
                    RuulButton("Primary", style: .primary, size: size) {}
                    RuulButton("Secondary", style: .secondary, size: size) {}
                }
                HStack(spacing: RuulSpacing.s3) {
                    RuulButton("Glass", style: .glass, size: size) {}
                    RuulButton("Destruct", style: .destructive, size: size) {}
                    RuulButton("Plain", style: .plain, size: size) {}
                }
            }
            Divider()
            RuulButton("Loading", isLoading: true, fillsWidth: true) {}
            RuulButton("Disabled", systemImage: "lock.fill") {}
                .disabled(true)
            RuulButton("Full width", style: .primary, size: .large, fillsWidth: true) {}
        }
        .padding(RuulSpacing.s5)
    }
    .background(Color.ruulBackgroundCanvas)
}
#endif
