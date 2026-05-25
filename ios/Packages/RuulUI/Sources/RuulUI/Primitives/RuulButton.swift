import SwiftUI

/// Thin wrapper around SwiftUI's native `Button` that maps a small,
/// Ruul-specific Style/Size axis onto Apple-canonical button styles
/// (`.borderedProminent`, `.bordered`, `.glass`, `.plain`) plus the
/// `.destructive` role. Per Plan §2.5: keep this wrapper because the
/// `isLoading` indicator + fixed-width hero behavior + role-binding
/// consolidate ~5 lines per call site (and 150+ call sites is a real
/// blast radius).
///
/// 2026-05-20 internals rewrite: previously the wrapper drew custom
/// capsules (`Capsule().fill(Color.ruulAccent)`, glass overlays, red
/// destructive fills) via a `StyleBackground` ViewModifier and a custom
/// `.ruulPress` interactive style. All of that is gone — the button now
/// renders with native `buttonStyle(...)`, `controlSize(...)`, role-
/// based destructive styling, and `.tint(.accentColor)` inherited from
/// the app root. Visual delta is large per call site (buttons read
/// system-native now), zero source-level changes at the ~150 callers.
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
        styledButton
            .controlSize(controlSize)
            .disabled(isLoading)
    }

    @ViewBuilder
    private var styledButton: some View {
        switch style {
        case .primary:
            base.buttonStyle(.glassProminent)
        case .secondary:
            base.buttonStyle(.glass)
        case .glass:
            base.buttonStyle(.glass)
        case .destructive:
            destructiveBase.buttonStyle(.glassProminent)
        case .plain:
            base.buttonStyle(.plain)
        }
    }

    private var base: some View {
        Button(action: tap) {
            label.frame(maxWidth: fillsWidth ? .infinity : nil)
        }
    }

    private var destructiveBase: some View {
        Button(role: .destructive, action: tap) {
            label.frame(maxWidth: fillsWidth ? .infinity : nil)
        }
    }

    private func tap() {
        guard !isLoading else { return }
        action()
    }

    @ViewBuilder
    private var label: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
        } else if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }

    private var controlSize: ControlSize {
        switch size {
        case .small:  return .small
        case .medium: return .regular
        case .large:  return .large
        }
    }
}

#if DEBUG
#Preview("RuulButton") {
    ScrollView {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            ForEach([RuulButton.Size.small, .medium, .large], id: \.self) { size in
                Text("\(String(describing: size))").font(.footnote)
                HStack(spacing: RuulSpacing.sm) {
                    RuulButton("Primary", style: .primary, size: size) {}
                    RuulButton("Secondary", style: .secondary, size: size) {}
                }
                HStack(spacing: RuulSpacing.sm) {
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
        .padding(RuulSpacing.lg)
    }
    .background(Color(.systemBackground))
}
#endif
